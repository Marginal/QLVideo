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

    // Codecs CoreVideo can handle
    static let native: [AVCodecID: CMVideoCodecType] = [
        AV_CODEC_ID_MJPEG: kCMVideoCodecType_JPEG,
        AV_CODEC_ID_JPEGXL: kCMVideoCodecType_JPEG_XL,
        AV_CODEC_ID_H263: kCMVideoCodecType_H263,
        AV_CODEC_ID_H264: kCMVideoCodecType_H264,
        AV_CODEC_ID_HEVC: kCMVideoCodecType_HEVC,
            // kCMVideoCodecType_HEVCWithAlpha
            // kCMVideoCodecType_DolbyVisionHEVC: special handling below
            // AV_CODEC_ID_MPEG1VIDEO: kCMVideoCodecType_MPEG1Video,
            // AV_CODEC_ID_MPEG2VIDEO: kCMVideoCodecType_MPEG2Video,
            // AV_CODEC_ID_MPEG4: kCMVideoCodecType_MPEG4Video,
            // AV_CODEC_ID_VP8: special handling below
            // AV_CODEC_ID_VP9: kCMVideoCodecType_VP9, special handling below
            // Hopefully codec_tag is set appropriately to disambiguate the below:
            // AV_CODEC_ID_DVVIDEO: maps to multple kCMVideoCodecType_DVC*
            // AV_CODEC_ID_PRORES: maps to multiple kCMVideoCodecType_AppleProRes*
            // AV_CODEC_ID_PRORES_RAW: maps to multiple kCMVideoCodecType_AppleProResRAW*
            // kCMVideoCodecType_DisparityHEVC: ?
            // kCMVideoCodecType_DepthHEVC: ?
            // AV_CODEC_ID_AV1: kCMVideoCodecType_AV1, special handling below
    ]

    static let supported: [AVCodecID: CMVideoCodecType] = [
        // Made up FourCCs that match those registered by our videodecoder in order to bypass CoreVideo
        AV_CODEC_ID_MPEG1VIDEO: 0x4d50_4731,  // 'MPG1' FFmpeg is more tolerant of poor encoding than CoreVideo
        AV_CODEC_ID_MPEG2VIDEO: 0x4d50_4732,  // 'MPG2' FFmpeg is more tolerant of poor encoding than CoreVideo
        AV_CODEC_ID_MPEG4: 0x4d50_4734,  // 'MPG4' FFmpeg is more tolerant of poor encoding than CoreVideo
        AV_CODEC_ID_SVQ1: 0x5356_3120,  // 'SV1 ' not supported by AVFoundation
        AV_CODEC_ID_SVQ3: 0x5356_3320,  // 'SV3 ' not supported by AVFoundation
        AV_CODEC_ID_VP8: 0x5650_3820,  // 'VP8 ' somehow supported in Safari but not by AVFoundation
        AV_CODEC_ID_VP9: 0x5650_3920,  // 'VP9 ' not supported by AVFoundation unless client calls VTRegisterSupplementalVideoDecoderIfAvailable
        AV_CODEC_ID_AV1: 0x4156_3120,  // 'AV1 ' only supported by AVFoundation on M3 CPUs and later
        // Selected real FourCCs that videodecoder registers
        AV_CODEC_ID_THEORA: 0x7468_656f,  // 'theo'
        AV_CODEC_ID_VVC: 0x7676_6331,  // 'vvc1'
        AV_CODEC_ID_CINEPAK: 0x6376_6964,  // 'cvid'
        AV_CODEC_ID_VC1: 0x7663_2D31,  // 'vc-1',
        AV_CODEC_ID_CAVS: 0x6176_7332,  // 'avs2'
        AV_CODEC_ID_FLIC: 0x666C_6963,  // 'flic'
        AV_CODEC_ID_APV: 0x6170_7631,  // 'apv1'
        AV_CODEC_ID_FLV1: 0x464C_5631,  // 'FLV1'
        AV_CODEC_ID_FLASHSV: 0x4653_5631,  // 'FSV1'
        AV_CODEC_ID_VP6: 0x5650_3620,  // 'VP6 ' (actually 'VP60' or 'VP61')
        AV_CODEC_ID_VP6A: 0x5650_3620,  // 'VP6 ' (actually VP6A')
        AV_CODEC_ID_VP6F: 0x5650_3620,  // 'VP6 ' (actually 'VP6F' or 'FLV4')
        AV_CODEC_ID_WMV1: 0x574D_5631,  // 'WMV1'
        AV_CODEC_ID_WMV2: 0x574D_5632,  // 'WMV2'
        AV_CODEC_ID_WMV3: 0x574D_5633,  // 'WMV3'
        AV_CODEC_ID_RV10: 0x5256_3130,  // 'RV10'
        AV_CODEC_ID_RV20: 0x5256_3230,  // 'RV20'
        AV_CODEC_ID_RV30: 0x5256_3330,  //  RV30'
        AV_CODEC_ID_RV40: 0x5256_3430,  // 'RV40'
        AV_CODEC_ID_RV60: 0x5256_3630,  // 'RV60'
        AV_CODEC_ID_CLEARVIDEO: 0x434C_5631,  // 'CLV1'
        AV_CODEC_ID_INDEO2: 0x4956_3231,  // 'IV21' (more commonly 'RT21')
        AV_CODEC_ID_INDEO3: 0x4956_3331,  // 'IV31'
        AV_CODEC_ID_INDEO4: 0x4956_3431,  // 'IV41'
        AV_CODEC_ID_INDEO5: 0x4956_3530,  // 'IV50'
        AV_CODEC_ID_QTRLE: 0x726C_6520,  // 'rle '
        AV_CODEC_ID_HEVC: 0x444F_5649,  // 'DOVI' non-Dolby Vision HEVC is handled in the 'native' map above
    ]
    static let kVideoCodecType_VP8 = CMVideoCodecType(0x7670_3038)  // 'vp08'
    static let kVideoCodecType_catchall = CMVideoCodecType(0x514c_5620)  // 'QLV '

    static let colorPrimaries: [AVColorPrimaries: CFString] = [
        AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        AVCOL_PRI_BT470M: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_SMPTE170M: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_SMPTE240M: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_SMPTE428: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
    ]

    static let colorTransfer: [AVColorTransferCharacteristic: CFString] = [
        AVCOL_TRC_BT709: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        AVCOL_TRC_SMPTE170M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
        AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
        AVCOL_TRC_SMPTE428: kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1,
        AVCOL_TRC_BT2020_10: kCMFormatDescriptionTransferFunction_ITU_R_2020,
        AVCOL_TRC_BT2020_12: kCMFormatDescriptionTransferFunction_ITU_R_2020,
        AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
        AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
    ]

    static let colorMatrix: [AVColorSpace: CFString] = [
        AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        AVCOL_SPC_BT470BG: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995,
        AVCOL_SPC_BT2020_NCL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
    ]

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        let params = stream.pointee.codecpar.pointee
        guard params.codec_type == AVMEDIA_TYPE_VIDEO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        // Determine whether we want VideoToolbox (codecType!=nil) or FFmpeg (codecType==nil) to do the decoding,
        // and construct a codec configuration for those codecs where CoreVideo/VideoToolbox requires one.
        var codecType: CMVideoCodecType? = VideoTrackReader.native[params.codec_id]
        var extensions: [CFString: Any] = [:]
        switch params.codec_id {
        case AV_CODEC_ID_MJPEG:
            // Need an esds atom, but FFmpeg doesn't provide one. Make a minimal one.
            let bytes: [UInt8] = [
                0, 0, 0, 0, 0x03, 0x80, 0x80, 0x80, 0x1b, 0, 0x01, 0, 0x04, 0x80, 0x80, 0x80, 0x0d, 0x6c, 0x11, 0, 0, 0, 0,
                0x8b, 0xa5, 0xda, 0, 0x8b, 0xa5, 0xda, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
            ]
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
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
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
        case AV_CODEC_ID_H264:
            // avc1 / MPEG-4 part 10
            // https://developer.apple.com/documentation/quicktime-file-format/avc_decoder_configuration_atom
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                [
                    "avcC" as CFString: CFDataCreateWithBytesNoCopy(
                        kCFAllocatorDefault,
                        params.extradata,
                        CFIndex(params.extradata_size),
                        kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                    )
                ]
        case AV_CODEC_ID_VP9, AV_CODEC_ID_VP8:
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
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                ["vpcC" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
            if params.codec_id == AV_CODEC_ID_VP8 {
                if VTIsHardwareDecodeSupported(VideoTrackReader.kVideoCodecType_VP8) {
                    codecType = VideoTrackReader.kVideoCodecType_VP8
                }
                logger.log(
                    "VP8 decode available: \(VTIsHardwareDecodeSupported(VideoTrackReader.kVideoCodecType_VP8))"
                )
            } else if params.codec_id == AV_CODEC_ID_VP9 {
                if VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) { codecType = kCMVideoCodecType_VP9 }
                logger.log("VP9 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
            }
        case AV_CODEC_ID_HEVC:
            // MPEG-4 Part 15
            var atoms: [CFString: CFData] = [
                "hvcC" as CFString: CFDataCreateWithBytesNoCopy(
                    kCFAllocatorDefault,
                    params.extradata,
                    CFIndex(params.extradata_size),
                    kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                )
            ]
            if let dvAtom = DolbyVisionAtom() {
                atoms[dvAtom.0] = dvAtom.1
                codecType =
                    VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC) ? kCMVideoCodecType_DolbyVisionHEVC : nil
                logger.log("Dolby Vision decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC))")
            }
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
        case AV_CODEC_ID_AV1:
            // https://aomediacodec.github.io/av1-isobmff/#av1codecconfigurationbox-section
            var atoms: [CFString: CFData] = [
                "av1C" as CFString: CFDataCreateWithBytesNoCopy(
                    kCFAllocatorDefault,
                    params.extradata,
                    CFIndex(params.extradata_size),
                    kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                )
            ]
            if let dvAtom = DolbyVisionAtom() { atoms[dvAtom.0] = dvAtom.1 }
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
            /* TODO: Disable AV1 hardware decode until I can test it on M3 or later
            if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { codecType = kCMVideoCodecType_AV1 }  // M3 and later
            logger.log("AV1 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")
             */
        default:
            if params.extradata_size != 0 {
                let hex = UnsafeBufferPointer(start: params.extradata, count: Int(params.extradata_size)).reduce(
                    "data=",
                    { result, byte in String(format: "%@ %02x", result, byte) }
                )
                logger.debug(
                    "VideoTrackReader stream \(self.index) loadTrackInfo unhandled extradata \(params.extradata_size) bytes with codec \"\(FormatReader.avcodec_name(params.codec_id), privacy:.public)\": \(hex, privacy:.public)"
                )
            }
        }

        if codecType == nil {
            // macOS can't decode - check whether FFmpeg has a decoder
            guard avcodec_find_decoder(params.codec_id) != nil else {
                logger.error(
                    "VideoTrackReader stream \(self.index) loadTrackInfo: No decoder for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public)"
                )
                return completionHandler(nil, MEError(.unsupportedFeature))
            }

            // Pass the stream's AVCodecParameters in CMFormatDescription so it can be reconstructed in the MEVideoDecoder
            var parameters: [CFString: Any?] = [
                "AVCodecParameters" as CFString: CFDataCreate(
                    kCFAllocatorDefault,
                    stream.pointee.codecpar,
                    CFIndex(MemoryLayout<AVCodecParameters>.size)
                )
            ]
            if params.extradata_size > 0 {
                parameters["ExtraData" as CFString] = CFDataCreate(
                    kCFAllocatorDefault,
                    params.extradata,
                    CFIndex(params.extradata_size)
                )
            }
            for i in 0..<Int(params.nb_coded_side_data) {
                parameters["SideData\(i)" as CFString] = CFDataCreate(
                    kCFAllocatorDefault,
                    params.coded_side_data[i].data,
                    CFIndex(params.coded_side_data[i].size)
                )
                parameters["SideData\(i)Type" as CFString] = CFNumberCreate(nil, .intType, &params.coded_side_data[i].type)
            }
            extensions["QLVideo" as CFString] = parameters as CFDictionary

            // Give the track a fourcc that ensures our MEVideoDecoder gets to see it
            codecType = VideoTrackReader.supported[params.codec_id] ?? VideoTrackReader.kVideoCodecType_catchall
        }

        // Other extensions
        let sar = av_guess_sample_aspect_ratio(format.fmt_ctx, &stream.pointee, nil)
        if sar.num != 0 && (sar.num != 1 || sar.den != 1) {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio as CFString] =
                [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey as CFString: sar.num as CFNumber,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey as CFString: sar.den as CFNumber,
                ] as CFDictionary
        }
        if let colorPrimaries = VideoTrackReader.colorPrimaries[params.color_primaries] {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as CFString] = colorPrimaries
        }
        if let colorTransfer = VideoTrackReader.colorTransfer[params.color_trc] {
            extensions[kCMFormatDescriptionExtension_TransferFunction as CFString] = colorTransfer
        }
        if let colorMatrix = VideoTrackReader.colorMatrix[params.color_space] {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as CFString] = colorMatrix
        }
        extensions[kCMFormatDescriptionExtension_FullRangeVideo] =
            params.color_range == AVCOL_RANGE_JPEG ? kCFBooleanTrue : kCFBooleanFalse

        logger.debug(
            "VideoTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) codecType:\"\(FormatReader.av_fourcc2str(codecType!), privacy: .public)\" extensions:\(extensions, privacy:.public) timescale:\(self.stream.pointee.time_base.den) \(params.width)x\(params.height) \(av_q2d(self.stream.pointee.avg_frame_rate), format:.fixed(precision:2))fps"
        )

        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType!,
            width: params.width,
            height: params.height,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
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
        trackInfo.naturalTimescale = stream.pointee.time_base.den
        trackInfo.nominalFrameRate = Float32(av_q2d(stream.pointee.avg_frame_rate))
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
        do {
            return completionHandler(
                try SampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: presentationTimeStamp
                ),
                nil
            )
        } catch {
            logger.error(
                "VideoTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("VideoTrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        do {
            return completionHandler(
                try SampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: stream.pointee.start_time != AV_NOPTS_VALUE
                        ? CMTime(value: stream.pointee.start_time, timeBase: stream.pointee.time_base) : .zero
                ),
                nil
            )
        } catch {
            logger.error(
                "VideoTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtFirstSampleInDecodeOrder: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("VideoTrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        do {
            return completionHandler(
                try SampleCursor(format: format, track: self, index: index, atPresentationTimeStamp: .positiveInfinity),
                nil
            )
        } catch {
            logger.error(
                "VideoTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtLastSampleInDecodeOrder: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

}
