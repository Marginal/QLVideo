//
//  videodecoder.swift
//  QLVideo
//
//  Created by Jonathan Harris on 21/01/2026.
//

import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

// Swift Error wrapper for CoreVideo CVReturn codes
struct CVReturnError: LocalizedError, CustomNSError {
    let status: CVReturn
    let context: String?

    static var errorDomain: String { "CoreVideoErrorDomain" }
    var errorCode: Int { Int(status) }
    var errorDescription: String? { "\(context ?? "") failed with CVReturn \(status)" }
}

// Callback for FFmpeg's get_buffer2 that uses the MEVideoDecoderPixelBufferManager passed via AVCodecContext.opaque.
// On return, the allocated CVPixelBuffer is passed via AVFrame.opaque.
private func videoDecoder_get_buffer2(
    _ dec_ctx: UnsafeMutablePointer<AVCodecContext>?,
    _ frame: UnsafeMutablePointer<AVFrame>?,
    _ flags: Int32
) -> Int32 {
    guard let frame = frame, let dec_ctx = dec_ctx, let opaque = dec_ctx.pointee.opaque else { return -ENOTSUP }
    let manager = Unmanaged<MEVideoDecoderPixelBufferManager>.fromOpaque(opaque).takeUnretainedValue()

    // Set up desired attributes of the pixel buffer
    // Values may be different from the corresponding values in AVCodecContext https://ffmpeg.org/doxygen/8.0/structAVCodecContext.html#aef79333a4c6abf1628c55d75ec82bede
    var attributes: [String: Any] = [
        kCVPixelBufferWidthKey as String: frame.pointee.width,
        kCVPixelBufferHeightKey as String: frame.pointee.height,
        kCVPixelBufferPixelFormatTypeKey as String: av_map_videotoolbox_format_from_pixfmt2(
            AVPixelFormat(frame.pointee.format),
            frame.pointee.color_range == AVCOL_RANGE_JPEG
        ),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
    if let chroma_loc = av_map_videotoolbox_chroma_loc_from_av(frame.pointee.chroma_location) {
        attributes[kCVImageBufferChromaLocationTopFieldKey as String] = chroma_loc
        if frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 {
            attributes[kCVImageBufferChromaLocationBottomFieldKey as String] = chroma_loc  // Not sure if this is correct
        }
    }
    if let primaries = av_map_videotoolbox_color_primaries_from_av(frame.pointee.color_primaries) {
        attributes[kCVImageBufferColorPrimariesKey as String] = primaries
    }
    if let matrix = av_map_videotoolbox_color_matrix_from_av(frame.pointee.colorspace) {
        attributes[kCVImageBufferYCbCrMatrixKey as String] = matrix
    }
    if let trc = av_map_videotoolbox_color_trc_from_av(frame.pointee.color_trc) {
        attributes[kCVImageBufferTransferFunctionKey as String] = trc
    }
    // https://developer.apple.com/documentation/mediaextension/mevideodecoder says we can "make these calls multiple times
    // if output requirements change", but I don't know if that has performance implications.
    manager.pixelBufferAttributes = attributes

    // Obtain a pixel buffer to back the AVFrame
    var pixelBuffer: CVPixelBuffer
    do {
        pixelBuffer = try manager.makePixelBuffer()
    } catch {
        logger.error("VideoDecoder: Failed to obtain a pixel buffer: \(error.localizedDescription, privacy: .public)")
        return -ENOTSUP
    }
    let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard status == kCVReturnSuccess else {
        logger.error("VideoDecoder: Failed to lock pixel buffer: \(status)")
        return -ENOTSUP
    }

    // Retain and stash the CVPixelBuffer on the frame so decodeFrame can return it
    frame.pointee.opaque = Unmanaged.passRetained(pixelBuffer).toOpaque()

    // Point AVFrame's data pointers to the pixel buffer
    var dataSize = 0
    withUnsafeMutablePointer(to: &frame.pointee.data.0) { dataTuplePtr in
        let dataPtr = UnsafeMutableRawPointer(dataTuplePtr).assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
        withUnsafeMutablePointer(to: &frame.pointee.linesize.0) { linesizeTuplePtr in
            let linesizePtr = UnsafeMutableRawPointer(linesizeTuplePtr).assumingMemoryBound(to: Int32.self)
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)  // 0 for non-planar (e.g., BGRA)
            if planeCount == 0 {
                let base = CVPixelBufferGetBaseAddress(pixelBuffer)
                dataPtr[0] = base?.assumingMemoryBound(to: UInt8.self)
                frame.pointee.extended_data[0] = dataPtr[0]
                linesizePtr[0] = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))
                dataSize = Int(linesizePtr[0])
            } else {
                for plane in 0..<planeCount {
                    let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
                    dataPtr[plane] = base?.assumingMemoryBound(to: UInt8.self)
                    frame.pointee.extended_data[plane] = dataPtr[plane]
                    linesizePtr[plane] = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane))
                    dataSize += Int(linesizePtr[plane])  // Assumes planes are consecutive and contiguous
                }
            }
        }
    }

    // Set frame.buf[0] so FFmpeg unlocks and releases the CVPixelBuffer when the decode pipeline no longer needs it
    frame.pointee.buf.0 = av_buffer_create(frame.pointee.data.0, dataSize, videoDecoder_buffer_free, frame.pointee.opaque, 0)!
    //logger.debug("VideoDecoder alloc \(String(describing: frame.pointee.data.0)) \(String(describing: pixelBuffer))")

    return 0
}

private func videoDecoder_buffer_free(_ opaque: UnsafeMutableRawPointer?, _ data: UnsafeMutablePointer<UInt8>?) {
    let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(opaque!)
    //logger.debug("VideoDecoder free  \(String(describing: data)) \(String(describing: pixelBuffer))")
    CVPixelBufferUnlockBaseAddress(pixelBuffer.takeRetainedValue(), [])
}

class VideoDecoder: NSObject, MEVideoDecoder {

    let codecType: CMVideoCodecType
    let formatDescription: CMVideoFormatDescription
    let specifications: [String: Any]
    let manager: MEVideoDecoderPixelBufferManager

    var isReadyForMoreMediaData: Bool = true
    var params = avcodec_parameters_alloc()!.pointee
    var dec_ctx: UnsafeMutablePointer<AVCodecContext>?
    var sws_ctx: UnsafeMutablePointer<SwsContext>? = nil  // For format conversion

    init(
        codecType: CMVideoCodecType,
        videoFormatDescription: CMVideoFormatDescription,
        videoDecoderSpecifications: [String: Any],
        pixelBufferManager: MEVideoDecoderPixelBufferManager
    ) throws {
        self.codecType = codecType
        self.formatDescription = videoFormatDescription
        self.specifications = videoDecoderSpecifications
        self.manager = pixelBufferManager

        // Recreate stream's AVCodecParameters from CMVideoFormatDescription extension

        guard let imported = formatDescription.extensions["QLVideo" as CFString] as? [CFString: Any],
            let importedParams = imported["AVCodecParameters" as CFString] as? Data,
            importedParams.count == MemoryLayout<AVCodecParameters>.size
        else {
            logger.error("VideoDecoder: No AVCodecParameters in formatDescription for codecType:\(codecType)")
            throw MEError(.unsupportedFeature)
        }
        withUnsafeMutableBytes(of: &params) { $0.copyBytes(from: importedParams) }

        if let importedExtraData = imported["ExtraData" as CFString] as? Data {
            // must pad https://ffmpeg.org/doxygen/8.0/structAVCodecParameters.html#a9befe0b86412646017afb0051d144d13
            let extraData = av_mallocz(Int(params.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
            params.extradata = extraData.assumingMemoryBound(to: UInt8.self)
            let dst = params.extradata  // avoid capturing self in closure
            importedExtraData.withUnsafeBytes { src in
                let base = src.baseAddress!
                memcpy(dst, base, importedExtraData.count)
            }
        }

        var nb_sd: Int32 = 0
        while nb_sd < Int(params.nb_coded_side_data) {
            let importedSideData = imported["SideData\(nb_sd)" as CFString] as! Data
            let importedSideDataType = imported["SideData\(nb_sd)Type" as CFString] as! CFNumber
            let sideData = av_malloc(importedSideData.count)!
            importedSideData.withUnsafeBytes { src in
                let base = src.baseAddress!
                memcpy(sideData, base, importedSideData.count)
            }
            if nb_sd == 0 {
                params.coded_side_data = av_mallocz(Int(params.nb_coded_side_data) * MemoryLayout<AVPacketSideData>.stride)!
                    .assumingMemoryBound(to: AVPacketSideData.self)
            }
            av_packet_side_data_add(
                &params.coded_side_data,
                &nb_sd,  // will be incremented
                AVPacketSideDataType((importedSideDataType) as! UInt32),
                sideData,
                importedSideData.count,
                0
            )
        }

        // Set up decode context

        guard let codec = avcodec_find_decoder(params.codec_id) else {
            logger.error(
                "VideoDecoder: No decoder for codec \(String(cString:avcodec_get_name(self.params.codec_id)), privacy: .public)"
            )
            throw MEError(.unsupportedFeature)
        }

        dec_ctx = avcodec_alloc_context3(codec)
        if dec_ctx == nil {
            logger.error(
                "VideoDecoder: Can't create decoder context for codec \(String(cString:avcodec_get_name(self.params.codec_id)), privacy: .public)"
            )
            throw MEError(.unsupportedFeature)
        }
        var ret = avcodec_parameters_to_context(dec_ctx, &params)
        if ret < 0 {
            let error = AVERROR(errorCode: ret)
            logger.error(
                "VideDecoder: Can't set decoder parameters for codec \(String(cString:avcodec_get_name(self.params.codec_id)), privacy: .public): \(error.localizedDescription)"
            )
            throw MEError(.unsupportedFeature)
        }
        ret = avcodec_open2(dec_ctx, codec, nil)
        if ret < 0 {
            let error = AVERROR(errorCode: ret)
            logger.error(
                "VideoDecoder: Can't open codec \(String(cString:avcodec_get_name(self.params.codec_id)), privacy: .public): \(error.localizedDescription)"
            )
            throw MEError(.unsupportedFeature)
        }

        // Request a suitable output pixel buffer format

        let pixFmt = av_map_videotoolbox_format_from_pixfmt2(
            AVPixelFormat(params.format),
            params.color_range == AVCOL_RANGE_JPEG
        )
        if pixFmt != 0 {
            // Setup context so that av_receive_frame writes directly into the CVPixelBuffer, which on return is in frame.opaque
            dec_ctx!.pointee.opaque = Unmanaged.passUnretained(self.manager).toOpaque()
            dec_ctx!.pointee.get_buffer2 = videoDecoder_get_buffer2
            logger.log(
                "VideoDecoder: Decoding \(self.params.width)x\(self.params.height), \(String(cString:av_get_pix_fmt_name(AVPixelFormat(self.params.format)))) \(String(cString:av_color_space_name(self.params.color_space))) \(self.params.color_range == AVCOL_RANGE_JPEG ? "full" : "video")range frames"
            )
        } else {
            // We're going to have to convert
            logger.log(
                "VideoDecoder: Decoding \(self.params.width)x\(self.params.height), \(String(cString:av_get_pix_fmt_name(AVPixelFormat(self.params.format)))) \(String(cString:av_color_space_name(self.params.color_space))) \(self.params.color_range == AVCOL_RANGE_JPEG ? "full" : "video")range frames and converting to BGRA"
            )
            sws_ctx = sws_getContext(
                params.width,
                params.height,
                AVPixelFormat(params.format),  // src
                params.width,
                params.height,
                AV_PIX_FMT_BGRA,  // dst
                Int32(SWS_BICUBIC.rawValue),  // Chosen on the assumption we need to upsample the chroma
                nil,
                nil,
                nil
            )
            guard ret == 0 else {
                let error = AVERROR(errorCode: ret)
                logger.error(
                    "VideoDecoder: Can't create rescaling context for format \(String(cString:av_get_sample_fmt_name(AVSampleFormat(self.params.format))), privacy: .public): \(error.localizedDescription)"
                )
                throw MEError(.unsupportedFeature)
            }
        }
    }

    deinit {
        if dec_ctx != nil { avcodec_free_context(&dec_ctx) }
        if sws_ctx != nil { sws_free_context(&sws_ctx) }
    }

    func decodeFrame(
        from sampleBuffer: CMSampleBuffer,
        options: MEDecodeFrameOptions,
        completionHandler: @escaping @Sendable (CVImageBuffer?, MEDecodeFrameStatus, (any Error)?) -> Void
    ) {

        // Get access to the sample buffer's data and attachments

        guard let blockBuffer = sampleBuffer.dataBuffer, blockBuffer.isEmpty == false, blockBuffer.isContiguous else {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Supplied sample data is not contiguous"
            )
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }
        var totalLength: Int = 0
        var data: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &data
        )
        guard status == kCMBlockBufferNoErr else {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Failed to get sample data:  \(status)"
            )
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)! as NSArray
        let attachment = attachments.firstObject as! NSDictionary

        // Populate an AVPacket with the sample buffer's data

        var pkt = av_packet_alloc()
        pkt!.pointee.data = UnsafeMutableRawPointer(data!).assumingMemoryBound(to: UInt8.self)
        pkt!.pointee.size = Int32(totalLength)
        pkt!.pointee.time_base = AVRational(
            num: 1,
            den: sampleBuffer.presentationTimeStamp.isNumeric
                ? Int32(sampleBuffer.presentationTimeStamp.timescale) : Int32(sampleBuffer.decodeTimeStamp.timescale)
        )
        pkt!.pointee.dts = sampleBuffer.decodeTimeStamp.isNumeric ? sampleBuffer.decodeTimeStamp.value : AV_NOPTS_VALUE
        pkt!.pointee.pts =
            sampleBuffer.presentationTimeStamp.isNumeric ? sampleBuffer.presentationTimeStamp.value : AV_NOPTS_VALUE
        let dependsOnOthers = (attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool) ?? true
        let doNotDisplay = (attachment[kCMSampleAttachmentKey_DoNotDisplay] as? Bool) ?? false
        pkt!.pointee.flags = (!dependsOnOthers ? AV_PKT_FLAG_KEY : 0) | (doNotDisplay ? AV_PKT_FLAG_DISCARD : 0)
        // TODO: Populate side_data

        #if DEBUG
            logger.debug(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) size:0x\(UInt(totalLength), format:.hex) flags:\(pkt!.pointee.flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(pkt!.pointee.flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)_ decodeFrame"
            )
        #endif

        // Decode

        var ret = avcodec_send_packet(dec_ctx, pkt)
        av_packet_free(&pkt)  // Free regardless of result since we don't need this any more - actual data lives in CMBlockBuffer
        guard ret >= 0 else {
            let error = AVERROR(errorCode: ret, context: "avcodec_send_packet")
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }

        var frame = av_frame_alloc()
        ret = avcodec_receive_frame(dec_ctx, frame)
        guard ret >= 0 else {
            let error = AVERROR(errorCode: ret, context: "avcodec_receive_frame")
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: \(error.localizedDescription, privacy: .public)"
            )
            if frame != nil { av_frame_free(&frame) }
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }

        // Convert if necessary

        var pixelBuffer: CVPixelBuffer
        if sws_ctx == nil {
            // No conversion - use the pixel buffer allocated in get_buffer2
            pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(frame!.pointee.opaque).takeUnretainedValue()
        } else {
            // Convert frame data into a new pixel buffer
            do {
                pixelBuffer = try manager.makePixelBuffer()
            } catch {
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Failed to obtain a pixel buffer: \(error.localizedDescription, privacy: .public)"
                )
                return completionHandler(nil, .frameDropped, error)
            }
            let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
            guard status == kCVReturnSuccess else {
                let error = CVReturnError(status: status, context: "CVPixelBufferLockBaseAddress")
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: \(error.localizedDescription, privacy: .public)"
                )
                return completionHandler(nil, .frameDropped, error)
            }

            var dst: UnsafeMutablePointer<UInt8>? = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            var dstStride = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))
            withUnsafePointer(to: &frame!.pointee.data.0) { srcPtr in
                withUnsafePointer(to: &frame!.pointee.linesize.0) { srcStridePtr in
                    withUnsafeMutablePointer(to: &dst) { dstPtr in
                        withUnsafePointer(to: &dstStride) { dstStridePtr in
                            ret = sws_scale(
                                sws_ctx!,
                                UnsafeRawPointer(srcPtr).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                                srcStridePtr,
                                0,
                                frame!.pointee.height,
                                dstPtr,
                                dstStridePtr
                            )
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard ret > 0 else {
                let error = AVERROR(errorCode: ret)
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Can't resample frame: \(error.localizedDescription, privacy: .public)"
                )
                av_frame_free(&frame)
                return completionHandler(nil, .frameDropped, error)
            }
        }

        av_frame_free(&frame)
        return completionHandler(pixelBuffer, [], nil)
    }

}
