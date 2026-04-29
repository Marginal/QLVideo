//
//  videodecoder.swift
//  QLVideo
//
//  Created by Jonathan Harris on 21/01/2026.
//

import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

// Swift Error wrapper for CoreVideo CVReturn codes
struct CVReturnError: LocalizedError, CustomNSError {
    let errorCode: Int
    let context: String?

    static var errorDomain: String { "CoreVideoErrorDomain" }
    var errorDescription: String? { "\(context ?? "") failed with CVReturn \(errorCode)" }
}

class VideoDecoder: NSObject, MEVideoDecoder {

    static let supported: [CMVideoCodecType: AVCodecID] = [
        kCMVideoCodecType_Animation: AV_CODEC_ID_QTRLE,
        0x7270_7a61: AV_CODEC_ID_RPZA,  // 'rpza'
        0x6963_6f64: AV_CODEC_ID_AIC,  // 'icod'
        kCMVideoCodecType_Cinepak: AV_CODEC_ID_CINEPAK,
        0x4861_7031: AV_CODEC_ID_HAP,  // 'Hap1'
        0x4861_7035: AV_CODEC_ID_HAP,  // 'Hap5'
        0x4861_7059: AV_CODEC_ID_HAP,  // 'HapY'
        0x4861_704D: AV_CODEC_ID_HAP,  // 'HapM'
        0x4861_7041: AV_CODEC_ID_HAP,  // 'HapA'
        0x666C_6963: AV_CODEC_ID_FLIC,  // 'flic'
        0x4146_4C43: AV_CODEC_ID_FLIC,  // 'AFLC'
        0x5254_3231: AV_CODEC_ID_INDEO2,  // 'RT21'
        0x4956_3331: AV_CODEC_ID_INDEO3,  // 'IV31'
        0x4956_3332: AV_CODEC_ID_INDEO3,  // 'IV32'
        0x4956_3431: AV_CODEC_ID_INDEO4,  // 'IV41'
        0x4956_3530: AV_CODEC_ID_INDEO5,  // 'IV50'
        kCMVideoCodecType_SorensonVideo: AV_CODEC_ID_SVQ1,
        kCMVideoCodecType_SorensonVideo3: AV_CODEC_ID_SVQ3,
        0x4449_5658: AV_CODEC_ID_MPEG4,  // 'DIVX'
        0x5856_4944: AV_CODEC_ID_MPEG4,  // 'XVID'
        0x4458_3530: AV_CODEC_ID_MPEG4,  // 'DX50'
        0x4d50_4734: AV_CODEC_ID_MPEG4,  // 'MPG4'
        0x464d_5034: AV_CODEC_ID_MPEG4,  // 'FMP4'
        0x4d50_3431: AV_CODEC_ID_MSMPEG4V1,  // 'MP41'
        0x4d50_3432: AV_CODEC_ID_MSMPEG4V2,  // 'MP42'
        0x4d50_3433: AV_CODEC_ID_MSMPEG4V3,  // 'MP43'
    ]

    // Supported pixel formats for QuickTime animation. Non-paletised only.
    // TODO: extract the palette from VerbatimSampleDescription see ff_get_qtpalette ?
    static let animDepths: [Int: AVPixelFormat] = [
        16: AV_PIX_FMT_RGB555LE,
        24: AV_PIX_FMT_RGB24,
        32: AV_PIX_FMT_ARGB,
    ]

    let codecType: CMVideoCodecType
    let formatDescription: CMVideoFormatDescription
    let specifications: [String: Any]
    let manager: MEVideoDecoderPixelBufferManager

    var isReadyForMoreMediaData: Bool = true
    var params = avcodec_parameters_alloc()!
    var dec_ctx: UnsafeMutablePointer<AVCodecContext>?
    var lastDTS = CMTime.invalid

    // Cached pixel buffer config - rebuilt only when frame dimensions, color properties or HDR metadata change
    private var pixelBufferKey: PixelBufferCacheKey? = nil
    var pixelBufferConfig: PixelBufferConfig? = nil

    // For format conversion using macOS Accelerate API
    var conversionInfo: vImage_YpCbCrToARGB? = nil
    var scaleYBuffer: vImage_Buffer? = nil
    var scaleCbBuffer: vImage_Buffer? = nil
    var scaleCrBuffer: vImage_Buffer? = nil
    var scaleYTemp: UnsafeMutableRawPointer? = nil
    var scaleCbTemp: UnsafeMutableRawPointer? = nil
    var scaleCrTemp: UnsafeMutableRawPointer? = nil

    // For format conversion using FFmpeg's zscale filter
    var filterGraph: UnsafeMutablePointer<AVFilterGraph>? = nil
    var src_ctx: UnsafeMutablePointer<AVFilterContext>? = nil
    var sink_ctx: UnsafeMutablePointer<AVFilterContext>? = nil

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

        super.init()

        // Recreate stream's AVCodecParameters from CMVideoFormatDescription extension

        if let imported = formatDescription.extensions["QLVideo" as CFString] as? [CFString: Any],
            let importedParams = imported["AVCodecParameters" as CFString] as? Data,
            importedParams.count == MemoryLayout<AVCodecParameters>.size
        {
            withUnsafeMutableBytes(of: &params.pointee) { $0.copyBytes(from: importedParams) }

            if let importedExtraData = imported["ExtraData" as CFString] as? Data {
                // must pad https://ffmpeg.org/doxygen/8.0/structAVCodecParameters.html#a9befe0b86412646017afb0051d144d13
                let extraData = av_mallocz(Int(params.pointee.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
                params.pointee.extradata = extraData.assumingMemoryBound(to: UInt8.self)
                let dst = params.pointee.extradata  // avoid capturing self in closure
                importedExtraData.withUnsafeBytes { src in
                    let base = src.baseAddress!
                    memcpy(dst, base, importedExtraData.count)
                }
            }

            var nb_sd: Int32 = 0
            while nb_sd < Int(params.pointee.nb_coded_side_data) {
                let importedSideData = imported["SideData\(nb_sd)" as CFString] as! Data
                let importedSideDataType = imported["SideData\(nb_sd)Type" as CFString] as! CFNumber
                let sideData = av_malloc(importedSideData.count)!
                importedSideData.withUnsafeBytes { src in
                    let base = src.baseAddress!
                    memcpy(sideData, base, importedSideData.count)
                }
                if nb_sd == 0 {
                    params.pointee.coded_side_data = av_mallocz(
                        Int(params.pointee.nb_coded_side_data) * MemoryLayout<AVPacketSideData>.stride
                    )!
                    .assumingMemoryBound(to: AVPacketSideData.self)
                }
                av_packet_side_data_add(
                    &params.pointee.coded_side_data,
                    &nb_sd,  // will be incremented
                    AVPacketSideDataType((importedSideDataType) as! UInt32),
                    sideData,
                    importedSideData.count,
                    0
                )
            }
        } else if let codecID = VideoDecoder.supported[codecType] {
            // Didn't come from our formatreader, e.g. from .avi or .mov. Try to decode anyway.
            let depth = videoFormatDescription.extensions[kCMFormatDescriptionExtension_Depth as CFString] as? NSNumber
            switch codecID {
            case AV_CODEC_ID_QTRLE:
                if let depth, let pixFmt = VideoDecoder.animDepths[depth.intValue] {
                    params.pointee.format = pixFmt.rawValue
                    params.pointee.color_range = AVCOL_RANGE_JPEG
                } else {
                    logger.error(
                        "VideoDecoder: Unsupported depth: \(depth) in \(String(describing: self.formatDescription), privacy: .public))"
                    )
                    throw MEError(.unsupportedFeature)
                }
            case AV_CODEC_ID_RPZA:
                params.pointee.format = AV_PIX_FMT_RGB555LE.rawValue
                params.pointee.color_range = AVCOL_RANGE_JPEG
            case AV_CODEC_ID_AIC:
                params.pointee.format = AV_PIX_FMT_YUV420P.rawValue
                params.pointee.color_range = AVCOL_RANGE_MPEG
            case AV_CODEC_ID_CINEPAK:
                params.pointee.format = AV_PIX_FMT_RGB24.rawValue
                params.pointee.color_range = AVCOL_RANGE_JPEG
            case AV_CODEC_ID_HAP:
                // FFmpeg hapdec.c sets pix_fmt to one of RGB0 (Hap1/HapY), RGBA (Hap5/HapM), or GRAY8 (HapA) based on fourCC in codec_tag
                params.pointee.color_range = AVCOL_RANGE_JPEG
            case AV_CODEC_ID_FLIC:
                // FFmpeg flicvideo.c sets pix_fmt based on depth
                params.pointee.color_range = AVCOL_RANGE_JPEG
            case AV_CODEC_ID_INDEO2, AV_CODEC_ID_INDEO3, AV_CODEC_ID_INDEO4, AV_CODEC_ID_INDEO5:
                params.pointee.format = AV_PIX_FMT_YUV410P.rawValue
                params.pointee.color_range = AVCOL_RANGE_MPEG
            case AV_CODEC_ID_SVQ1, AV_CODEC_ID_SVQ3:
                params.pointee.format = AV_PIX_FMT_YUV420P.rawValue
                params.pointee.color_range = AVCOL_RANGE_MPEG
                // see FFmpeg svq3_decode_extradata()
                if let sampleDesc = formatDescription.extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
                    as? [CFString: Data],
                    let SMI = sampleDesc["SMI " as CFString]
                {
                    // must pad https://ffmpeg.org/doxygen/8.0/structAVCodecParameters.html#a9befe0b86412646017afb0051d144d13
                    params.pointee.extradata_size = Int32(SMI.count + 8)
                    let extraData = av_mallocz(Int(params.pointee.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
                    params.pointee.extradata = extraData.assumingMemoryBound(to: UInt8.self)
                    let bytes: [UInt8] =
                        [
                            0, 0, UInt8(params.pointee.extradata_size >> 8), UInt8(params.pointee.extradata_size & 0xff),  // size
                            0x53, 0x4d, 0x49, 0x20,  // 'SMI '
                        ] + [UInt8](SMI)
                    memcpy(params.pointee.extradata, bytes, bytes.count)
                }
            case AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V1, AV_CODEC_ID_MSMPEG4V2, AV_CODEC_ID_MSMPEG4V3:
                // DivX or other MPEG4 variant other than 'mp4v'. May or may not have an esds atom.
                params.pointee.format = AV_PIX_FMT_YUV420P.rawValue
                params.pointee.color_range = AVCOL_RANGE_MPEG
                if let sampleDesc = formatDescription.extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
                    as? [CFString: Data],
                    let esds = sampleDesc["esds" as CFString]
                {
                    func decodeLength(_ bytes: Data, _ offset: inout Int) -> Int? {
                        var len = 0
                        var count = 4
                        while count > 0 && offset < bytes.count {
                            count -= 1
                            let c = Int(bytes[offset])
                            offset += 1
                            len = (len << 7) | (c & 0x7f)
                            if c & 0x80 == 0 { break }
                        }
                        return len
                    }

                    // extradata should contain just the contents of the DecSpecificInfoTag (0x5) - see FFmpeg ff_mp4_read_dec_config_descr()
                    var offset = esds.count >= 4 ? 4 : 0  // Skip version (1 byte) + flags (3 bytes) if present
                    var decoderSpecific: Data? = nil
                    while offset < esds.count {
                        let tag = esds[offset]
                        offset += 1
                        guard let length = decodeLength(esds, &offset) else { break }
                        if tag == 0x05 {  // DecoderSpecificInfoTag
                            decoderSpecific = esds.subdata(in: offset..<min(offset + length, esds.count))
                            break
                        }
                        offset += length
                    }
                    if let dsi = decoderSpecific, dsi.isEmpty == false {
                        params.pointee.extradata_size = Int32(dsi.count)
                        let extraData = av_mallocz(Int(params.pointee.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
                        params.pointee.extradata = extraData.assumingMemoryBound(to: UInt8.self)
                        dsi.withUnsafeBytes { src in
                            _ = memcpy(params.pointee.extradata, src.baseAddress!, dsi.count)
                        }
                    }
                }
            default:
                // Shouldn't get here
                logger.error(
                    "VideoDecoder: No AVCodecParameters in \(String(describing: self.formatDescription), privacy: .public))"
                )
                throw MEError(.unsupportedFeature)
            }
            params.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            params.pointee.codec_id = codecID
            params.pointee.codec_tag = codecType.byteSwapped  // Supplied codecType is big endian
            params.pointee.width = videoFormatDescription.dimensions.width
            params.pointee.height = videoFormatDescription.dimensions.height
            params.pointee.bits_per_coded_sample = depth?.int32Value ?? 0
            logger.warning(
                "VideoDecoder: No AVCodecParameters in \(String(describing: self.formatDescription), privacy: .public))"
            )
        } else {
            logger.error("VideoDecoder: No AVCodecParameters in \(String(describing: self.formatDescription), privacy: .public))")
            throw MEError(.unsupportedFeature)
        }

        // Set up decode context

        guard let codec = avcodec_find_decoder(params.pointee.codec_id) else {
            logger.error(
                "VideoDecoder: No decoder for codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public)"
            )
            throw MEError(.unsupportedFeature)
        }

        dec_ctx = avcodec_alloc_context3(codec)
        if dec_ctx == nil {
            logger.error(
                "VideoDecoder: Can't create decoder context for codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public)"
            )
            throw MEError(.unsupportedFeature)
        }
        var ret = avcodec_parameters_to_context(dec_ctx, params)
        if ret < 0 {
            let error = AVERROR(errorCode: ret)
            logger.error(
                "VideDecoder: Can't set decoder parameters for codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public): \(error.localizedDescription)"
            )
            throw MEError(.unsupportedFeature)
        }
        ret = avcodec_open2(dec_ctx, codec, nil)
        if ret < 0 {
            let error = AVERROR(errorCode: ret)
            logger.error(
                "VideoDecoder: Can't open codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public): \(error.localizedDescription)"
            )
            throw MEError(.unsupportedFeature)
        }

        logger.log(
            "VideoDecoder: Decoding \(self.dec_ctx!.pointee.width)x\(self.dec_ctx!.pointee.height), \(String(cString:av_get_pix_fmt_name(self.dec_ctx!.pointee.pix_fmt)), privacy: .public) \(String(cString:av_color_space_name(self.dec_ctx!.pointee.colorspace)), privacy: .public)"
        )

    }

    deinit {
        if dec_ctx != nil { avcodec_free_context(&dec_ctx) }
        if sink_ctx != nil { avfilter_free(sink_ctx) }
        if src_ctx != nil { avfilter_free(src_ctx) }
        if filterGraph != nil { avfilter_graph_free(&filterGraph) }
        vImageFreeScaleBuffers()
    }

    // Primary business of this codec

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
        let notSync = (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let doNotDisplay = (attachment[kCMSampleAttachmentKey_DoNotDisplay] as? Bool) ?? false
        let discontinuity = (attachment[kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding] as? Bool) ?? false
        pkt!.pointee.flags = (!notSync ? AV_PKT_FLAG_KEY : 0) | (doNotDisplay ? AV_PKT_FLAG_DISCARD : 0)
        var nb_sd: Int32 = 0
        while nb_sd < Int(pkt!.pointee.side_data_elems) {
            let importedSideData = attachment["SideData\(nb_sd)" as CFString] as! Data
            let importedSideDataType = attachment["SideData\(nb_sd)Type" as CFString] as! CFNumber
            let sideData = av_malloc(importedSideData.count)!
            importedSideData.withUnsafeBytes { src in
                let base = src.baseAddress!
                memcpy(sideData, base, importedSideData.count)
            }
            if nb_sd == 0 {
                pkt!.pointee.side_data = av_mallocz(Int(pkt!.pointee.side_data_elems) * MemoryLayout<AVPacketSideData>.stride)!
                    .assumingMemoryBound(to: AVPacketSideData.self)
            }
            av_packet_side_data_add(
                &pkt!.pointee.side_data,
                &nb_sd,  // will be incremented
                AVPacketSideDataType((importedSideDataType) as! UInt32),
                sideData,
                importedSideData.count,
                0
            )
        }

        // Try to detect a discontinuous seek and flush the decoder if we see one
        if discontinuity {
            logger.debug(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public): Seek"
            )
            avcodec_send_packet(dec_ctx, nil)
            avcodec_flush_buffers(dec_ctx)
        }

        // Decode
        var ret = avcodec_send_packet(dec_ctx, pkt)
        av_packet_free(&pkt)  // Free regardless of result since we don't need this any more - actual data lives in CMBlockBuffer
        if ret == AVERROR_EAGAIN {
            // Can't do anything with this packet
            logger.warning(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public): Packet produced no output"
            )
            // Fall through with the hope that the decoder can still produce useful output
        } else if ret < 0 {
            let error = AVERROR(errorCode: ret, context: "avcodec_send_packet")
            logger.error(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }

        var frame = av_frame_alloc()
        ret = avcodec_receive_frame(dec_ctx, frame)
        guard ret >= 0 else {
            let error = AVERROR(errorCode: ret, context: "avcodec_receive_frame")
            logger.error(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if frame != nil { av_frame_free(&frame) }
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }

        #if DEBUG
            logger.debug(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) size:0x\(UInt(totalLength), format:.hex) flags:\(frame!.pointee.flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(frame!.pointee.flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)_ "
            )
        #endif

        if frame!.pointee.opaque != nil {
            // No conversion required - return the pixel buffer allocated in get_buffer2
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(frame!.pointee.opaque).takeUnretainedValue()
            av_frame_free(&frame)
            return completionHandler(pixelBuffer, [], nil)  // early return
        }

        // Fix up color info on the decoded frame
        VideoDecoder.fixupColors(frame: frame!)

        var pixelBuffer: CVPixelBuffer
        do {
            // Only update manager.pixelBufferAttributes if frame properties have changed since the last frame
            let newKey = PixelBufferCacheKey(frame: frame!)
            if newKey != pixelBufferKey {
                pixelBufferKey = newKey
                pixelBufferConfig = makePixelBufferConfig(frame: frame!)
                manager.pixelBufferAttributes = pixelBufferConfig!.pixelBufferAttributes
            }
            pixelBuffer = try manager.makePixelBuffer()
        } catch {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Failed to obtain a pixel buffer: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, .frameDropped, error)
        }

        // HDR passthrough: shift and interleave into biplanar pixel buffer
        if pixelBufferConfig!.isHDR {
            if let error = hdrConvertToBiPlanar(frame: frame!, pixelBuffer: pixelBuffer) {
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: HDR conversion failed: \(error.localizedDescription, privacy: .public)"
                )
                av_frame_free(&frame)
                return completionHandler(nil, .frameDropped, error)
            }
            av_frame_free(&frame)
            return completionHandler(pixelBuffer, [], nil)
        }

        // can we use macOS's accelerated conversions?
        if let error = vImageConvertToBGRA(frame: &frame!.pointee, pixelBuffer: &pixelBuffer) {
            if error.errorCode != kvImageUnsupportedConversion {
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: vImage conversion failed: \(error.localizedDescription, privacy: .public)"
                )
                av_frame_free(&frame)
                return completionHandler(nil, .frameDropped, error)
            }
        } else {
            av_frame_free(&frame)
            return completionHandler(pixelBuffer, [], nil)
        }

        // Fall back to zscale conversion. Should work for pretty-much any source format.
        var error = zscaleConvertToGBRP(frame: &frame, pixelBuffer: &pixelBuffer)
        if error == nil {
            error = vImageCopyToBGRA(frame: &frame!.pointee, pixelBuffer: &pixelBuffer)
        }
        guard error == nil else {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: zScale conversion failed: \(error!.localizedDescription, privacy: .public)"
            )
            av_frame_free(&frame)
            return completionHandler(nil, .frameDropped, error)
        }
        av_frame_free(&frame)
        return completionHandler(pixelBuffer, [], nil)
    }

    // Infer color info from the decoded frame. Make educated guesses for unspecified values.
    // Mutates the frame's color_primaries, color_trc and colorspace fields in place.
    class func fixupColors(frame: UnsafeMutablePointer<AVFrame>) {

        // Let presence of SMPTE 2086:2014 side data override anything else in the AVFrame
        if av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) != nil
            || av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) != nil
            || av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) != nil
        {
            frame.pointee.color_primaries = AVCOL_PRI_BT2020
            frame.pointee.color_trc = AVCOL_TRC_SMPTE2084
            frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL
            return
        }

        // If all fields are specified then assume they're correct
        if frame.pointee.color_primaries != AVCOL_PRI_UNSPECIFIED
            && frame.pointee.color_trc != AVCOL_TRC_UNSPECIFIED
            && frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED
        {
            return
        }

        // Explicit PQ or HLG
        if frame.pointee.color_trc == AVCOL_TRC_SMPTE2084 || frame.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 {
            if frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED { frame.pointee.color_primaries = AVCOL_PRI_BT2020 }
            if frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED { frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL }
            return
        }

        // >8‑bit *with BT.2020 primaries* is probably HDR10.
        let pixDesc = av_pix_fmt_desc_get(AVPixelFormat(frame.pointee.format)).pointee
        let bitDepth = pixDesc.comp.0.depth  // not always accurate but works for supported formats
        if bitDepth > 8 && frame.pointee.color_primaries == AVCOL_PRI_BT2020 {
            frame.pointee.color_primaries = AVCOL_PRI_BT2020
            frame.pointee.color_trc = AVCOL_TRC_SMPTE2084
            frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL
            return
        }

        // SDR. Assume values based on input format and whether HD or SD
        // Follow mpv heursitics https://wiki.x266.mov/docs/colorimetry/primaries
        if frame.pointee.width >= 1280 || frame.pointee.height > 576 || frame.pointee.format != AV_PIX_FMT_YUV420P.rawValue {
            frame.pointee.color_primaries = AVCOL_PRI_BT709
            frame.pointee.color_trc = AVCOL_TRC_BT709
            frame.pointee.colorspace = AVCOL_SPC_BT709
        } else {
            frame.pointee.color_primaries = AVCOL_PRI_SMPTE170M
            frame.pointee.color_trc = AVCOL_TRC_BT709  // This got retconned when HDR came out
            frame.pointee.colorspace = AVCOL_SPC_SMPTE170M
        }
    }

    // Cached pixel buffer configuration. Covers both HDR biplanar and SDR BGRA paths.
    // Includes the fully-built pixelBufferAttributes dictionary for MEVideoDecoderPixelBufferManager.
    struct PixelBufferConfig {
        let pixelBufferAttributes: [String: Any]
        // HDR conversion parameters. nil for SDR frames.
        let bitDepth: UInt32
        let uvShiftX: UInt32  // 0=n/a,444, 1=422,420
        let uvShiftY: UInt32  // 0=n/a,444,422, 1=420
        var isHDR: Bool { bitDepth > 8 }
    }

    // Lightweight key capturing the frame and display properties that affect PixelBufferConfig / CVPixelBuffer attributes.
    // Compared each frame to decide whether to rebuild the config or reuse the cached one.
    // In practice this almost always matches because resolution and color properties are
    // uniform within a stream, and FFmpeg propagates the same static MDM/CLL metadata onto every frame.
    private struct PixelBufferCacheKey: Equatable {
        let width: Int32
        let height: Int32
        let format: Int32
        let colorTrc: AVColorTransferCharacteristic
        let colorPrimaries: AVColorPrimaries
        let colorspace: AVColorSpace
        let colorRange: AVColorRange
        let chromaLocation: AVChromaLocation
        let mdmBytes: Data?  // 88 bytes raw AVMasteringDisplayMetadata, or nil
        let cllBytes: Data?  // 8 bytes raw AVContentLightMetadata, or nil
        let aveBytes: Data?  // 24 bytes raw AVAmbientViewingEnvironment, or nil

        init(frame: UnsafePointer<AVFrame>) {
            self.width = frame.pointee.width
            self.height = frame.pointee.height
            self.format = frame.pointee.format
            self.colorTrc = frame.pointee.color_trc
            self.colorPrimaries = frame.pointee.color_primaries
            self.colorspace = frame.pointee.colorspace
            self.colorRange = frame.pointee.color_range
            self.chromaLocation = frame.pointee.chroma_location
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) {
                self.mdmBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.mdmBytes = nil
            }
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) {
                self.cllBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.cllBytes = nil
            }
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT) {
                self.aveBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.aveBytes = nil
            }
        }
    }

    // Build PixelBufferConfig for the current frame.
    // Handles both HDR biplanar and SDR BGRA paths. The frame's color fields must already
    // be fixed up by fixupColors() before calling this.
    // The returned config includes the fully-built pixelBufferAttributes dictionary
    // suitable for assigning directly to MEVideoDecoderPixelBufferManager.
    func makePixelBufferConfig(frame: UnsafePointer<AVFrame>) -> PixelBufferConfig {
        var width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)

        let config =
            hdrPixelBufferConfig(frame: frame)
            ?? {
                // SDR path: adjust destination width for anamorphic so vImage/zscale will scale into the CVPixelBuffer.
                if let sar = formatDescription.extensions[kCMFormatDescriptionExtension_PixelAspectRatio]
                    as? [CFString: NSNumber],
                    let num = sar[kCVImageBufferPixelAspectRatioHorizontalSpacingKey],
                    let den = sar[kCVImageBufferPixelAspectRatioVerticalSpacingKey]
                {
                    width = Int(av_rescale_rnd(Int64(width), num.int64Value, den.int64Value, AV_ROUND_NEAR_INF))
                }
                return PixelBufferConfig(
                    pixelBufferAttributes: [
                        kCVPixelBufferWidthKey as String: width as CFNumber,
                        kCVPixelBufferHeightKey as String: height as CFNumber,
                        kCVPixelBufferBytesPerRowAlignmentKey as String: 64 as CFNumber,
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as CFBoolean,
                        kCVBufferPropagatedAttachmentsKey as String: [
                            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_sRGB,
                            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        ],
                    ],
                    bitDepth: 8,
                    uvShiftX: 0,
                    uvShiftY: 0
                )
            }()
        return config
    }

}
