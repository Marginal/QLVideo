//
//  videotrackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 18/11/2025.
//

import Foundation
import MediaExtension
import OSLog

class VideoTrackReader: TrackReader {

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
        AV_CODEC_ID_VP9: kCMVideoCodecType_VP9,
        // AV_CODEC_ID_DVVIDEO maps to multple kCMVideoCodecType_DVC*
        // AV_CODEC_ID_PRORES maps tp multiple kCMVideoCodecType_AppleProRes*
        // AV_CODEC_ID_PRORES_RAW maps tp multiple kCMVideoCodecType_AppleProResRAW*
        // kCMVideoCodecType_DisparityHEVC ?
        // kCMVideoCodecType_DepthHEVC ?
        AV_CODEC_ID_AV1: kCMVideoCodecType_AV1,  // only supported by AVFoundation on M3 CPUs and later
    ]

    override func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        let params = stream.codecpar.pointee
        guard params.codec_type == AVMEDIA_TYPE_VIDEO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        var atoms: CFDictionary? = nil
        switch params.codec_id {
        case AV_CODEC_ID_MJPEG:
            // Need an esds atom, but FFmpeg doesn't provide one. Make a minimal one.
            let bytes: [UInt8] = [
                0, 0, 0, 0, 0x03, 0x80, 0x80, 0x80, 0x1b, 0, 0x01, 0, 0x04, 0x80, 0x80, 0x80, 0x0d, 0x6c, 0x11, 0, 0, 0, 0,
                0x8b, 0xa5, 0xda, 0, 0x8b, 0xa5, 0xda, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
            ]
            atoms = ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
        case AV_CODEC_ID_MPEG4:
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
            atoms = ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
        case AV_CODEC_ID_H264:
            // avc1 / MPEG4 part 10 https://developer.apple.com/documentation/quicktime-file-format/avc_decoder_configuration_atom
            atoms =
                [
                    "avcC" as CFString: CFDataCreateWithBytesNoCopy(
                        kCFAllocatorDefault,
                        params.extradata,
                        CFIndex(params.extradata_size),
                        kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                    )
                ] as CFDictionary
        case AV_CODEC_ID_HEVC:
            // assume this works like above?
            atoms =
                [
                    "hvcC" as CFString: CFDataCreateWithBytesNoCopy(
                        kCFAllocatorDefault,
                        params.extradata,
                        CFIndex(params.extradata_size),
                        kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                    )
                ] as CFDictionary
        default:
            // TODO: "av1C" https://aomediacodec.github.io/av1-isobmff/#av1codecconfigurationbox-section
            // TODO: "vpcC" https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box
            if params.extradata_size != 0 {
                let hex = UnsafeBufferPointer(start: params.extradata, count: Int(params.extradata_size)).reduce("data=", { result, byte in String(format: "%@ %02x", result, byte) })
                logger.debug(
                    "loadTrackInfo unhandled extradata \(params.extradata_size) bytes with codec \"\(FormatReader.avcodec_name(params.codec_id), privacy:.public)\": \(hex, privacy:.public)"
                )
            }
        }

        logger.debug(
            "loadTrackInfo for stream #\(self.index) enabled:\(self.isEnabled) codecType:\"\(FormatReader.av_fourcc2str(VideoTrackReader.fourcc[params.codec_id] ?? params.codec_tag), privacy: .public)\" extensions:\(atoms, privacy:.public) timescale:\(self.stream.time_base.den) \(params.width)x\(params.height) \(av_q2d(self.stream.avg_frame_rate), format:.fixed(precision:2))fps"
        )
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: VideoTrackReader.fourcc[params.codec_id] ?? params.codec_tag,
            width: params.width,
            height: params.height,
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error("CMVideoFormatDescriptionCreate returned \(err, privacy:.public)")
            return completionHandler(nil, err)
        }
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Video,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isEnabled
        // TODO: set extendedLanguageTag from stream metadata "language" tag
        trackInfo.naturalSize = CGSize(width: Int(params.width), height: Int(params.height))
        trackInfo.naturalTimescale = stream.time_base.den
        let sar = av_guess_sample_aspect_ratio(format.fmt_ctx, &stream, nil)
        if sar.num != 0 && (sar.num != 1 || sar.den != 1) {
            logger.debug("sample_aspect_ratio \(sar.num):\(sar.den)")
            trackInfo.preferredTransform = CGAffineTransform(scaleX: av_q2d(sar), y: 1)
        }
        trackInfo.nominalFrameRate = Float32(av_q2d(stream.avg_frame_rate))
        trackInfo.requiresFrameReordering = true  // TODO: do we need this?

        format.tracks[index] = self
        completionHandler(trackInfo, nil)
    }
}
