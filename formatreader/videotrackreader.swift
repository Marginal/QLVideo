//
//  videotrackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 18/11/2025.
//

import Foundation
import MediaExtension
import OSLog

class VideoTrackReader: TrackReader, METrackReader {

    // AVCodecParameters.codec_tag can be zero(!) so prefer .codec_id for common types known to AVFoundation
    // See https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/matroska.c for the codec_ids that FFmpeg expects in a Matroska container
    static let fourcc: [AVCodecID: CMVideoCodecType] = [
        AV_CODEC_ID_MJPEG: kCMVideoCodecType_JPEG,
        AV_CODEC_ID_JPEGXL: kCMVideoCodecType_JPEG_XL,
        AV_CODEC_ID_SVQ1: kCMVideoCodecType_SorensonVideo,  // not supported by AVFoundation
        AV_CODEC_ID_SVQ3: kCMVideoCodecType_SorensonVideo3,  // not supported by AVFoundation
        AV_CODEC_ID_H263: kCMVideoCodecType_H263,
        AV_CODEC_ID_H264: kCMVideoCodecType_H264,
        AV_CODEC_ID_HEVC: kCMVideoCodecType_HEVC,
        // kCMVideoCodecType_HEVCWithAlpha
        // kCMVideoCodecType_DolbyVisionHEVC
        AV_CODEC_ID_MPEG1VIDEO: kCMVideoCodecType_MPEG1Video,  // not supported by AVFoundation
        AV_CODEC_ID_MPEG2VIDEO: kCMVideoCodecType_MPEG2Video,
        AV_CODEC_ID_MPEG4: kCMVideoCodecType_MPEG4Video,
        AV_CODEC_ID_VP8: 0x7670_3038,  // 'vp08' somehow supported in Safari but not by AVFoundation
        AV_CODEC_ID_VP9: kCMVideoCodecType_VP9,
        // AV_CODEC_ID_DVVIDEO maps to multple kCMVideoCodecType_DVC*
        // AV_CODEC_ID_PRORES maps tp multiple kCMVideoCodecType_AppleProRes*
        // AV_CODEC_ID_PRORES_RAW maps tp multiple kCMVideoCodecType_AppleProResRAW*
        // kCMVideoCodecType_DisparityHEVC ?
        // kCMVideoCodecType_DepthHEVC ?
        AV_CODEC_ID_AV1: kCMVideoCodecType_AV1,  // only supported by AVFoundation on M3 CPUs and later
    ]

    static let boxtype: [AVCodecID: String] = [
        AV_CODEC_ID_H264: "avcC",  // avc1 / MPEG-4 part 10 https://developer.apple.com/documentation/quicktime-file-format/avc_decoder_configuration_atom
        AV_CODEC_ID_HEVC: "hvcC",  // MPEG-4 Part 15
        AV_CODEC_ID_AV1: "av1C",  // https://aomediacodec.github.io/av1-isobmff/#av1codecconfigurationbox-section
    ]

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        let params = stream.codecpar.pointee
        guard params.codec_type == AVMEDIA_TYPE_VIDEO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        var description: CFDictionary? = nil
        if params.codec_id == AV_CODEC_ID_MJPEG {
            // Need an esds atom, but FFmpeg doesn't provide one. Make a minimal one.
            let bytes: [UInt8] = [
                0, 0, 0, 0, 0x03, 0x80, 0x80, 0x80, 0x1b, 0, 0x01, 0, 0x04, 0x80, 0x80, 0x80, 0x0d, 0x6c, 0x11, 0, 0, 0, 0,
                0x8b, 0xa5, 0xda, 0, 0x8b, 0xa5, 0xda, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
            ]
            description = ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
        } else if params.codec_id == AV_CODEC_ID_MPEG4 {
            // MPEG4 part 2 https://developer.apple.com/documentation/quicktime-file-format/mpeg-4_elementary_stream_descriptor_atom
            // FFmpeg only retains the decoder-specific info from "esds" in extradata - so rebuild it.
            // See videotoolbox_esds_extradata_create in https://ffmpeg.org/doxygen/8.0/videotoolbox_8c_source.html
            let decoder_size = params.extradata_size  // assumed to be < 16K
            let config_size = 13 + 5 + decoder_size
            let full_size = 3 + 5 + config_size + 6
            let bytes: [UInt8] =
                [
                    0, 0, 0, 0,  // Version/flags = ESDS
                    0x03,  // ES_DescrTag
                    0x80, 0x80, UInt8(0x80 | (full_size >> 7)), UInt8(full_size & 0x7f),
                    0x00, 0x01, 0,  // ES_ID, priority
                    0x04,  // DecoderConfigDescrTag
                    0x80, 0x80, UInt8(0x80 | (config_size >> 7)), UInt8(config_size & 0x7f),
                    0x20, 0x11,  // MPEG 4, video
                    0, 0, 0,  // buffer size
                    0, 0, 0, 0,  // max bitrate
                    0, 0, 0, 0,  // avg bitrate
                    0x05,  // DecSpecificInfoTag
                    0x80, 0x80, UInt8(0x80 | (decoder_size >> 7)), UInt8(decoder_size & 0x7f),
                ] + [UInt8](UnsafeBufferPointer<UInt8>(start: params.extradata, count: Int(params.extradata_size))) + [
                    0x06,  // SLConfigDescrTag
                    0x80, 0x80, 0x80, 0x01,
                    0x02,
                ]
            description = ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
        } else if params.codec_id == AV_CODEC_ID_VP9 || params.codec_id == AV_CODEC_ID_VP8 {
            // https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box
            // See ff_videotoolbox_vpcc_extradata_create in https://ffmpeg.org/doxygen/8.0/videotoolbox__vp9_8c_source.html#l00065
            let pix_fmt = av_pix_fmt_desc_get(AVPixelFormat(params.format)).pointee
            let bitDepth = UInt8(pix_fmt.comp.0.depth)  // not always accurate but works for supported formats
            let chromaSubsampling = UInt8(
                pix_fmt.log2_chroma_w == 0
                    ? 3  // 4:4:4
                    : (pix_fmt.log2_chroma_h == 0
                        ? 2  // 4:2:2
                        : (params.chroma_location == AVCHROMA_LOC_TOPLEFT
                            ? 1  // 4:2:0 colocated with luma
                            : 0))  // 4:2:0 vertical
            )
            let bytes: [UInt8] =
                [
                    0x01, 0x00, 0x00, 0x00,  // version = 1, flags = 0
                    UInt8(params.profile),
                    params.level != AV_LEVEL_UNKNOWN ? UInt8(params.level) : 0,
                    (bitDepth << 4) | (chromaSubsampling << 1) | (params.color_range == AVCOL_RANGE_JPEG ? 1 : 0),  // 0x80
                    UInt8(params.color_primaries.rawValue),  // FFmpeg color enums match MPEG part 8
                    UInt8(params.color_trc.rawValue),
                    UInt8(params.color_space.rawValue),
                    0x00, 0x00,  // codecInitializationDataSize
                ]
            description = ["vpcC" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
        } else if params.extradata_size != 0, let atom = VideoTrackReader.boxtype[params.codec_id] {
            description =
                [
                    atom as CFString: CFDataCreateWithBytesNoCopy(
                        kCFAllocatorDefault,
                        params.extradata,
                        CFIndex(params.extradata_size),
                        kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                    )
                ] as CFDictionary
        } else if params.extradata_size != 0 {
            let hex = UnsafeBufferPointer(start: params.extradata, count: Int(params.extradata_size)).reduce(
                "data=",
                { result, byte in String(format: "%@ %02x", result, byte) }
            )
            logger.debug(
                "VideoTrackReader stream \(self.index) loadTrackInfo unhandled extradata \(params.extradata_size) bytes with codec \"\(FormatReader.avcodec_name(params.codec_id), privacy:.public)\": \(hex, privacy:.public)"
            )
        }

        logger.debug(
            "VideoTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) codecType:\"\(FormatReader.av_fourcc2str(VideoTrackReader.fourcc[params.codec_id] ?? params.codec_tag), privacy: .public)\" extensions:\(description, privacy:.public) timescale:\(self.stream.time_base.den) \(params.width)x\(params.height) \(av_q2d(self.stream.avg_frame_rate), format:.fixed(precision:2))fps"
        )
        if params.codec_id == AV_CODEC_ID_VP9 || params.codec_id == AV_CODEC_ID_VP8 {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            logger.log("VP9 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
        } else if params.codec_id == AV_CODEC_ID_AV1 {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
            logger.log("AV1 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")
        }
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: VideoTrackReader.fourcc[params.codec_id] ?? params.codec_tag,
            width: params.width,
            height: params.height,
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: description] as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "VideoTrackReader stream \(self.index) loadTrackInfo CMVideoFormatDescriptionCreate returned \(err, privacy:.public)"
            )
            return completionHandler(nil, err)
        }
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Video,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isEnabled
        // TODO: set extendedLanguageTag as RFC4646 from stream metadata "language" tag
        trackInfo.naturalSize = CGSize(width: Int(params.width), height: Int(params.height))
        trackInfo.naturalTimescale = stream.time_base.den
        let sar = av_guess_sample_aspect_ratio(format.fmt_ctx, &stream, nil)
        if sar.num != 0 && (sar.num != 1 || sar.den != 1) {
            logger.debug("sample_aspect_ratio \(sar.num):\(sar.den)")
            trackInfo.preferredTransform = CGAffineTransform(scaleX: av_q2d(sar), y: 1)
        }
        trackInfo.nominalFrameRate = Float32(av_q2d(stream.avg_frame_rate))
        trackInfo.requiresFrameReordering = true  // TODO: do we need this?

        completionHandler(trackInfo, nil)
    }

    // MARK: Navigation

    // The new sample cursor points to the last sample with a presentation time stamp (PTS) less than or equal to
    // presentationTimeStamp, or if there are no such samples, the first sample in PTS order.
    func generateSampleCursor(
        atPresentationTimeStamp presentationTimeStamp: CMTime,
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "VideoTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public)"
            )
        }
        return completionHandler(
            SampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: presentationTimeStamp
            ),
            nil
        )
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("VideoTrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        return completionHandler(
            SampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: stream.start_time != AV_NOPTS_VALUE
                    ? CMTime(value: stream.start_time, timeBase: stream.time_base) : .zero
            ),
            nil
        )
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("VideoTrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        return completionHandler(
            SampleCursor(format: format, track: self, index: index, atPresentationTimeStamp: .positiveInfinity),
            nil
        )
    }

}
