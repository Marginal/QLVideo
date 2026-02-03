//
//  audiotrackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 18/11/2025.
//

import Foundation
import MediaExtension
import OSLog

class AudioTrackReader: TrackReader, METrackReader {

    // AVCodecParameters.codec_tag can be zero(!) so prefer .codec_id for common types known to AVFoundation
    // See https://ffmpeg.org/doxygen/8.0/matroska_8c_source.html#l00027 for the codec_ids that FFmpeg expects in a Matroska container
    static let formatIDs: [AVCodecID: AudioFormatID] = [
        AV_CODEC_ID_PCM_S8: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_U8: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S16BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S16LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S24BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S24LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S32BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S32LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F32BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F32LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F64BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F64LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_MULAW: kAudioFormatULaw,
        AV_CODEC_ID_PCM_ALAW: kAudioFormatALaw,
            /* Easier to let FFmpeg decode all compressed formats - maybe more efficient too since it has to demux the data anyway
        AV_CODEC_ID_AC3: kAudioFormatAC3,
        // kAudioFormat60958AC3
        AV_CODEC_ID_ADPCM_IMA_QT: kAudioFormatAppleIMA4,
        AV_CODEC_ID_AAC: kAudioFormatMPEG4AAC,
        // MPEG4CELP: kAudioFormatMPEG4CELP, // not supported by FFmpeg
        // MPEG4HVXC: kAudioFormatMPEG4HVXC, // not supported by FFmpeg
        // MPEG4TwinVQ: kAudioFormatMPEG4TwinVQ, // not supported by FFmpeg
        AV_CODEC_ID_MACE3: kAudioFormatMACE3,
        AV_CODEC_ID_MACE6: kAudioFormatMACE6,
        AV_CODEC_ID_QDMC: kAudioFormatQDesign,
        AV_CODEC_ID_QDM2: kAudioFormatQDesign2,
        AV_CODEC_ID_QCELP: kAudioFormatQUALCOMM,
        AV_CODEC_ID_MP1: kAudioFormatMPEGLayer1,
        AV_CODEC_ID_MP2: kAudioFormatMPEGLayer2,
        AV_CODEC_ID_MP3: kAudioFormatMPEGLayer3,
        // kAudioFormatTimeCode,
        // kAudioFormatMIDIStream,
        // kAudioFormatParameterValueStream,
        AV_CODEC_ID_ALAC: kAudioFormatAppleLossless,
        // kAudioFormatMPEG4AAC_* not supported by FFmpeg
        AV_CODEC_ID_AMR_NB: kAudioFormatAMR,
        AV_CODEC_ID_AMR_WB: kAudioFormatAMR_WB,
        // kAudioFormatAudible, not supported by FFmpeg
        AV_CODEC_ID_ILBC: kAudioFormatiLBC,
        AV_CODEC_ID_ADPCM_IMA_WAV: kAudioFormatDVIIntelIMA,
        AV_CODEC_ID_GSM_MS: kAudioFormatMicrosoftGSM,
        // AV_CODEC_ID_AES3: kAudioFormatAES3, not supported by FFmpeg
        AV_CODEC_ID_EAC3: kAudioFormatEnhancedAC3,
        AV_CODEC_ID_FLAC: kAudioFormatFLAC,
        AV_CODEC_ID_OPUS: kAudioFormatOpus,
        // kAudioFormatAPAC, not supported by FFmpeg
             */
    ]

    // https://ffmpeg.org/doxygen/8.0/channel__layout_8h_source.html#l00175
    struct ChannelMasks: OptionSet {
        let rawValue: UInt64
        static let AV_CH_FRONT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_LEFT.rawValue)
        static let AV_CH_FRONT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_RIGHT.rawValue)
        static let AV_CH_FRONT_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_CENTER.rawValue)
        static let AV_CH_LOW_FREQUENCY = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_LOW_FREQUENCY.rawValue)
        static let AV_CH_BACK_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BACK_LEFT.rawValue)
        static let AV_CH_BACK_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BACK_RIGHT.rawValue)
        static let AV_CH_FRONT_LEFT_OF_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_LEFT_OF_CENTER.rawValue)
        static let AV_CH_FRONT_RIGHT_OF_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_RIGHT_OF_CENTER.rawValue)
        static let AV_CH_BACK_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BACK_CENTER.rawValue)
        static let AV_CH_SIDE_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_LEFT.rawValue)
        static let AV_CH_SIDE_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_RIGHT.rawValue)
        static let AV_CH_TOP_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_CENTER.rawValue)
        static let AV_CH_TOP_FRONT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_FRONT_LEFT.rawValue)
        static let AV_CH_TOP_FRONT_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_FRONT_CENTER.rawValue)
        static let AV_CH_TOP_FRONT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_FRONT_RIGHT.rawValue)
        static let AV_CH_TOP_BACK_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_BACK_LEFT.rawValue)
        static let AV_CH_TOP_BACK_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_BACK_CENTER.rawValue)
        static let AV_CH_TOP_BACK_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_BACK_RIGHT.rawValue)
        static let AV_CH_STEREO_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_STEREO_LEFT.rawValue)
        static let AV_CH_STEREO_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_STEREO_RIGHT.rawValue)
        static let AV_CH_WIDE_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_WIDE_LEFT.rawValue)
        static let AV_CH_WIDE_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_WIDE_RIGHT.rawValue)
        static let AV_CH_SURROUND_DIRECT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SURROUND_DIRECT_LEFT.rawValue)
        static let AV_CH_SURROUND_DIRECT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SURROUND_DIRECT_RIGHT.rawValue)
        static let AV_CH_LOW_FREQUENCY_2 = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_LOW_FREQUENCY_2.rawValue)
        static let AV_CH_TOP_SIDE_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SIDE_LEFT.rawValue)
        static let AV_CH_TOP_SIDE_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SIDE_RIGHT.rawValue)
        static let AV_CH_BOTTOM_FRONT_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BOTTOM_FRONT_CENTER.rawValue)
        static let AV_CH_BOTTOM_FRONT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BOTTOM_FRONT_LEFT.rawValue)
        static let AV_CH_BOTTOM_FRONT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BOTTOM_FRONT_RIGHT.rawValue)
        static let AV_CH_SIDE_SURROUND_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_SURROUND_LEFT.rawValue)
        static let AV_CH_SIDE_SURROUND_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_SURROUND_RIGHT.rawValue)
        static let AV_CH_TOP_SURROUND_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SURROUND_LEFT.rawValue)
        static let AV_CH_TOP_SURROUND_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SURROUND_RIGHT.rawValue)
        static let AV_CH_BINAURAL_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BINAURAL_LEFT.rawValue)
        static let AV_CH_BINAURAL_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BINAURAL_RIGHT.rawValue)

        // selected common layouts https://ffmpeg.org/doxygen/8.0/channel__layout_8h_source.html#l00217
        static let AV_CH_LAYOUT_MONO = ChannelMasks.AV_CH_FRONT_CENTER
        static let AV_CH_LAYOUT_STEREO: ChannelMasks = [.AV_CH_FRONT_LEFT, .AV_CH_FRONT_RIGHT]
        static let AV_CH_LAYOUT_SURROUND: ChannelMasks = [.AV_CH_LAYOUT_STEREO, .AV_CH_FRONT_CENTER]
        static let AV_CH_LAYOUT_5POINT0: ChannelMasks = [.AV_CH_LAYOUT_SURROUND, .AV_CH_SIDE_LEFT, .AV_CH_SIDE_RIGHT]
        static let AV_CH_LAYOUT_5POINT0_BACK: ChannelMasks = [.AV_CH_LAYOUT_SURROUND, .AV_CH_BACK_LEFT, .AV_CH_BACK_RIGHT]
        static let AV_CH_LAYOUT_5POINT1: ChannelMasks = [.AV_CH_LAYOUT_5POINT0, .AV_CH_LOW_FREQUENCY]
        static let AV_CH_LAYOUT_5POINT1_BACK: ChannelMasks = [.AV_CH_LAYOUT_5POINT0_BACK, .AV_CH_LOW_FREQUENCY]
        static let AV_CH_LAYOUT_7POINT1: ChannelMasks = [.AV_CH_LAYOUT_5POINT1, .AV_CH_BACK_LEFT, .AV_CH_BACK_RIGHT]
        static let AV_CH_LAYOUT_7POINT1_WIDE: ChannelMasks = [
            .AV_CH_LAYOUT_5POINT1, .AV_CH_FRONT_LEFT_OF_CENTER, .AV_CH_FRONT_RIGHT_OF_CENTER,
        ]
        static let AV_CH_LAYOUT_7POINT1_WIDE_BACK: ChannelMasks = [
            .AV_CH_LAYOUT_5POINT1_BACK, .AV_CH_FRONT_LEFT_OF_CENTER, .AV_CH_FRONT_RIGHT_OF_CENTER,
        ]
    }

    static let channelLabels: [UInt64: AudioChannelLabel] = [
        ChannelMasks.AV_CH_FRONT_LEFT.rawValue: kAudioChannelLabel_Left,
        ChannelMasks.AV_CH_FRONT_RIGHT.rawValue: kAudioChannelLabel_Right,
        ChannelMasks.AV_CH_FRONT_CENTER.rawValue: kAudioChannelLabel_Center,
        ChannelMasks.AV_CH_LOW_FREQUENCY.rawValue: kAudioChannelLabel_LFEScreen,
        ChannelMasks.AV_CH_BACK_LEFT.rawValue: kAudioChannelLabel_LeftBackSurround,
        ChannelMasks.AV_CH_BACK_RIGHT.rawValue: kAudioChannelLabel_RightBackSurround,
        ChannelMasks.AV_CH_FRONT_LEFT_OF_CENTER.rawValue: kAudioChannelLabel_LeftCenter,
        ChannelMasks.AV_CH_FRONT_RIGHT_OF_CENTER.rawValue: kAudioChannelLabel_RightCenter,
        ChannelMasks.AV_CH_BACK_CENTER.rawValue: kAudioChannelLabel_CenterSurround,
        ChannelMasks.AV_CH_SIDE_LEFT.rawValue: kAudioChannelLabel_LeftSurround,
        ChannelMasks.AV_CH_SIDE_RIGHT.rawValue: kAudioChannelLabel_RightSurround,
        ChannelMasks.AV_CH_TOP_CENTER.rawValue: kAudioChannelLabel_TopCenterSurround,
        ChannelMasks.AV_CH_TOP_FRONT_LEFT.rawValue: kAudioChannelLabel_VerticalHeightLeft,
        ChannelMasks.AV_CH_TOP_FRONT_CENTER.rawValue: kAudioChannelLabel_VerticalHeightCenter,
        ChannelMasks.AV_CH_TOP_FRONT_RIGHT.rawValue: kAudioChannelLabel_VerticalHeightRight,
        ChannelMasks.AV_CH_TOP_BACK_LEFT.rawValue: kAudioChannelLabel_TopBackLeft,
        ChannelMasks.AV_CH_TOP_BACK_CENTER.rawValue: kAudioChannelLabel_TopBackCenter,
        ChannelMasks.AV_CH_TOP_BACK_RIGHT.rawValue: kAudioChannelLabel_TopBackRight,
        ChannelMasks.AV_CH_STEREO_LEFT.rawValue: kAudioChannelLabel_Left,  // downmix
        ChannelMasks.AV_CH_STEREO_RIGHT.rawValue: kAudioChannelLabel_Right,  //  "
        ChannelMasks.AV_CH_WIDE_LEFT.rawValue: kAudioChannelLabel_LeftWide,
        ChannelMasks.AV_CH_WIDE_RIGHT.rawValue: kAudioChannelLabel_RightWide,
        ChannelMasks.AV_CH_SURROUND_DIRECT_LEFT.rawValue: kAudioChannelLabel_LeftSurroundDirect,
        ChannelMasks.AV_CH_SURROUND_DIRECT_RIGHT.rawValue: kAudioChannelLabel_RightSurroundDirect,
        ChannelMasks.AV_CH_LOW_FREQUENCY_2.rawValue: kAudioChannelLabel_LFE2,
        ChannelMasks.AV_CH_TOP_SIDE_LEFT.rawValue: kAudioChannelLabel_LeftTopMiddle,
        ChannelMasks.AV_CH_TOP_SIDE_RIGHT.rawValue: kAudioChannelLabel_RightTopMiddle,
        ChannelMasks.AV_CH_BOTTOM_FRONT_CENTER.rawValue: kAudioChannelLabel_CenterBottom,
        ChannelMasks.AV_CH_BOTTOM_FRONT_LEFT.rawValue: kAudioChannelLabel_LeftBottom,
        ChannelMasks.AV_CH_BOTTOM_FRONT_RIGHT.rawValue: kAudioChannelLabel_RightBottom,
        ChannelMasks.AV_CH_SIDE_SURROUND_LEFT.rawValue: kAudioChannelLabel_LeftSideSurround,
        ChannelMasks.AV_CH_SIDE_SURROUND_RIGHT.rawValue: kAudioChannelLabel_RightSideSurround,
        ChannelMasks.AV_CH_TOP_SURROUND_LEFT.rawValue: kAudioChannelLabel_LeftTopSurround,
        ChannelMasks.AV_CH_TOP_SURROUND_RIGHT.rawValue: kAudioChannelLabel_RightTopSurround,
        ChannelMasks.AV_CH_BINAURAL_LEFT.rawValue: kAudioChannelLabel_BinauralLeft,
        ChannelMasks.AV_CH_BINAURAL_RIGHT.rawValue: kAudioChannelLabel_BinauralRight,
    ]

    static let formatFlags: [AVSampleFormat: AudioFormatFlags] = [
        AV_SAMPLE_FMT_U8: 0,
        AV_SAMPLE_FMT_S16: kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_S32: kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_FLT: kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_DBL: kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_S64: kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_U8P: kAudioFormatFlagIsNonInterleaved,
        AV_SAMPLE_FMT_S16P: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_S32P: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_FLTP: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_DBLP: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_S64P: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsSignedInteger,
    ]

    deinit {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("AudioTrackReader deinit for stream #\(self.index)")
        }
        if dec_ctx != nil { avcodec_free_context(&dec_ctx) }
        if swr_ctx != nil { swr_free(&swr_ctx) }
    }

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        var params = stream.codecpar.pointee
        guard params.codec_type == AVMEDIA_TYPE_AUDIO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        #if DEBUG
            let hex = UnsafeBufferPointer(start: params.extradata, count: Int(params.extradata_size)).map {
                String(format: "%02x", $0)
            }.joined(separator: " ")
            logger.debug(
                "AudioTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) time_base:\(self.stream.time_base.num)/\(self.stream.time_base.den) start_time:\(self.stream.start_time) duration:\(self.stream.duration == AV_NOPTS_VALUE ? -1 : self.stream.duration) disposition:\(UInt(self.stream.disposition), format:.hex) codecpar: codec_id:\(String(cString:avcodec_get_name(params.codec_id)), privacy: .public) codec_tag:\"\(FormatReader.av_fourcc2str(params.codec_tag), privacy:.public)\" format:\(String(cString: av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy:.public) sample_rate:\(params.sample_rate) frame_size:\(params.frame_size) bits_per_coded_sample:\(params.bits_per_coded_sample) bits_per_raw_sample:\(params.bits_per_raw_sample) layout: order:\(params.ch_layout.order.rawValue) nb_channels:\(params.ch_layout.nb_channels) mask:\(params.ch_layout.u.mask, format: .hex) extradata \(params.extradata_size) bytes: \(hex)"
            )
        #endif

        // Check that we can decode
        let formatID = AudioTrackReader.formatIDs[params.codec_id]  // Can macOS decode?
        if formatID == nil {
            // macOS can't decode - prepare an AVCodecContext for FFmpeg decoding and SwrContext for resampling
            guard let codec = avcodec_find_decoder(params.codec_id) else {
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: No decoder for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public)"
                )
                return completionHandler(nil, MEError(.unsupportedFeature))
            }

            dec_ctx = avcodec_alloc_context3(codec)
            if dec_ctx == nil {
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: Can't create decoder context for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public)"
                )
                return completionHandler(nil, MEError(.unsupportedFeature))
            }
            var ret = avcodec_parameters_to_context(dec_ctx, &params)
            if ret < 0 {
                let err = AVERROR(errorCode: ret, context: "avcodec_parameters_to_context")
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: Can't set decoder parameters for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public): \(err.localizedDescription, privacy: .public)"
                )
                return completionHandler(nil, err)
            }
            ret = avcodec_open2(dec_ctx, codec, nil)
            if ret < 0 {
                let err = AVERROR(errorCode: ret, context: "avcodec_open2")
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: Can't open codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public): \(err.localizedDescription, privacy: .public)"
                )
                return completionHandler(nil, err)
            }

            // CoreMedia doesn't like planar PCM (error "SSP::Render: CopySlice returned 1") so convert to packed/interleaved
            // http://www.openradar.me/45068930
            if av_sample_fmt_is_planar(AVSampleFormat(params.format)) != 0 {
                ret = swr_alloc_set_opts2(
                    &swr_ctx,
                    &params.ch_layout,
                    av_get_packed_sample_fmt(AVSampleFormat(params.format)),  // out
                    params.sample_rate,
                    &params.ch_layout,
                    AVSampleFormat(params.format),  // in
                    params.sample_rate,
                    0,
                    nil
                )
                if ret < 0 {
                    let err = AVERROR(errorCode: ret, context: "swr_alloc_set_opts2")
                    logger.error(
                        "AudioTrackReader stream \(self.index) loadTrackInfo: Can't create resample context for format \(String(cString:av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy: .public): \(err.localizedDescription, privacy: .public)"
                    )
                    return completionHandler(nil, err)
                }
                ret = swr_init(swr_ctx)
                if ret < 0 {
                    let err = AVERROR(errorCode: ret, context: "swr_init")
                    logger.error(
                        "AudioTrackReader stream \(self.index) loadTrackInfo: Can't initialise resample context for format \(String(cString:av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy: .public): \(err.localizedDescription, privacy: .public)"
                    )
                    return completionHandler(nil, err)
                }
            }
        }

        // Determine channel layout

        var layoutTag = kAudioChannelLayoutTag_Unknown
        if params.ch_layout.order == AV_CHANNEL_ORDER_NATIVE {
            switch params.ch_layout.u.mask {
            // common cases where FFmpeg channel order matches that expected by an AudioChannelLayoutTag
            case ChannelMasks.AV_CH_LAYOUT_MONO.rawValue:  // FC
                layoutTag = kAudioChannelLayoutTag_Mono
            case ChannelMasks.AV_CH_LAYOUT_STEREO.rawValue:  // FL+FR
                layoutTag = kAudioChannelLayoutTag_Stereo
            case ChannelMasks.AV_CH_LAYOUT_5POINT1.rawValue,  // FL+FR+FC+LFE+SL+SR
                ChannelMasks.AV_CH_LAYOUT_5POINT1_BACK.rawValue:
                layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            case ChannelMasks.AV_CH_LAYOUT_7POINT1.rawValue,  // FL+FR+FC+LFE+BL+BR+SL+SR
                ChannelMasks.AV_CH_LAYOUT_7POINT1_WIDE.rawValue,
                ChannelMasks.AV_CH_LAYOUT_7POINT1_WIDE_BACK.rawValue:
                layoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
            default:
                // FFmpeg presents channels in order of AVChannel enum, which in general is not the same order
                // that various AudioChannelLayoutTags expect. So describe channels individually below.
                layoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            }
        } else if params.ch_layout.order == AV_CHANNEL_ORDER_CUSTOM {
            // TODO: layoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            logger.error("AudioTrackReader stream \(self.index) loadTrackInfo: unhandled custom channel layout")
        } else if params.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            // AVFoundation won't play with unknown layout, so make some assumptions
            switch params.ch_layout.nb_channels {
            case 1:
                layoutTag = kAudioChannelLayoutTag_Mono
            case 2:
                layoutTag = kAudioChannelLayoutTag_Stereo
            default:
                logger.error("AudioTrackReader stream \(self.index) loadTrackInfo: unspecified channel layout")
            }
        }

        // This is messy because descriptions must be contained in a contiguous array after the other AudioChannelLayout fields.
        let layoutSize =
            layoutTag != kAudioChannelLayoutTag_UseChannelDescriptions
            ? MemoryLayout<AudioChannelLayout>.size
            : MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! + Int(params.ch_layout.nb_channels)
                * MemoryLayout<AudioChannelDescription>.stride
        let layoutPtr = UnsafeMutableRawPointer.allocate(
            byteCount: layoutSize,
            alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        defer { layoutPtr.deallocate() }
        layoutPtr.initializeMemory(as: UInt8.self, to: 0)  // zero unused fields
        var layout = layoutPtr.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        layout.mChannelLayoutTag = layoutTag

        // populate descriptions
        if layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let descriptionPtr = layoutPtr.advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                .bindMemory(to: AudioChannelDescription.self, capacity: Int(params.ch_layout.nb_channels))
            var channel_number = 0
            var channel_mask: UInt64 = 1
            while true {
                if (params.ch_layout.u.mask & channel_mask) != 0 {
                    descriptionPtr.advanced(by: channel_number).pointee.mChannelLabel =
                        AudioTrackReader.channelLabels[params.ch_layout.u.mask & channel_mask]
                        ?? kAudioChannelLabel_Unknown
                    channel_number = channel_number + 1
                }
                if channel_mask & ChannelMasks.AV_CH_BINAURAL_RIGHT.rawValue != 0 { break }
                channel_mask = channel_mask << 1
            }
            layout.mNumberChannelDescriptions = UInt32(channel_number)
            assert(channel_number == Int(params.ch_layout.nb_channels))
        }

        // See definitions at https://developer.apple.com/documentation/CoreAudioTypes/AudioStreamBasicDescription#overview
        //   sample = a single value for a single channel
        //   frame = set of time-coincident samples for all channels in the stream e.g. 2 samples for a stereo channel
        // From CoreAudioBaseTypes.h:
        //   "In uncompressed audio, a Packet is one frame", "In compressed audio, a Packet is an indivisible chunk of compressed data"
        //   "In non-interleaved [=planar] audio, the per frame fields identify one channel".
        //
        // 3 cases:
        //   - Audio that CoreMedia doesn't understand - uncompressed=true, decoding=true
        //     * Get FFmpeg to decode, and supply the uncompressed data via DecodedSampleCuresor.loadSampleBufferContainingSamples
        //   - Compressed audio that macOS understands
        //     * Can't supply the compressed data in loadSampleBufferContainingSamples since CoreMedia expects CMSampleBuffer
        //       to contain sample count and sizes which we don't know (see CMSampleBufferCreate in CMSampleBuffer.h).
        //       Could decode as above, but then it would show up as PCM rather than e.g. AAC in media players.
        //       So supply data via PassthruSampleBuffer.sampleLocation (which unfortunately means it gets copied twice).
        //   - Uncompressed - uncompressed=true
        //     * We could use loadSampleBufferContainingSamples, but just supply the data via PassthruSampleBuffer.sampleLocation
        //
        let uncompressed = [kAudioFormatLinearPCM, kAudioFormatALaw, kAudioFormatULaw, nil].contains(formatID)
        let decoding = formatID == nil
        let bytes = UInt32(
            decoding
                ? av_get_bytes_per_sample(AVSampleFormat(params.format))  // size of the decoded samples
                : av_get_bits_per_sample(params.codec_id) >> 3  // returns zero for compressed formats
        )
        let outFmt: AVSampleFormat = swr_ctx?.pointee.out_sample_fmt ?? AVSampleFormat(params.format)
        let flags =
            AudioTrackReader.formatFlags[outFmt]!
            | (params.bits_per_raw_sample == params.bits_per_coded_sample
                ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh)
        let planar = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(params.sample_rate),
            mFormatID: formatID ?? kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytes * UInt32(planar ? 1 : params.ch_layout.nb_channels),  // "To indicate variable packet size, set this field to 0"
            mFramesPerPacket: UInt32(uncompressed ? 1 : params.frame_size),  // "In uncompressed audio, a Packet is one frame"
            mBytesPerFrame: bytes * UInt32(planar ? 1 : params.ch_layout.nb_channels),  // "Set this field to 0 for compressed formats"
            mChannelsPerFrame: UInt32(params.ch_layout.nb_channels),
            mBitsPerChannel: bytes << 3,  // "Set the number of bits to 0 for compressed formats"
            mReserved: 0
        )
        logger.debug(
            "AudioTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) timescale:\(self.stream.time_base.den) layout:0x\(layoutTag, format:.hex) absd: sampleRate:\(Int(asbd.mSampleRate)) formatID:\"\(FormatReader.av_fourcc2str(asbd.mFormatID), privacy: .public)\" formatFlags:0x\(asbd.mFormatFlags, format: .hex) bytesPerPacket:\(asbd.mBytesPerPacket) framesPerPacket:\(asbd.mFramesPerPacket) bytesPerFrame:\(asbd.mBytesPerFrame) channelsPerFrame:\(asbd.mChannelsPerFrame) bitsPerChannel:\(asbd.mBitsPerChannel)"
        )
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: layoutSize,
            layout: &layout,
            magicCookieSize: 0,  // Int(params.extradata_size),
            magicCookie: nil,  // params.extradata, // for AAC this is AudioSpecificConfig (ASC) from the esds atom
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "AudioTrackReader stream \(self.index) loadTrackInfo CMAudioFormatDescriptionCreate returned \(err, privacy:.public)"
            )
            return completionHandler(nil, err)
        }
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Audio,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isEnabled
        // TODO: set extendedLanguageTag as RFC4646 from stream metadata "language" tag
        trackInfo.naturalTimescale = stream.time_base.den

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
                "AudioTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public)"
            )
        }
        do {
            if dec_ctx != nil {
                return completionHandler(
                    try DecodedSampleCursor(
                        format: format,
                        track: self,
                        index: index,
                        atPresentationTimeStamp: presentationTimeStamp
                    ),
                    nil
                )
            } else {
                return completionHandler(
                    try PassthruSampleCursor(
                        format: format,
                        track: self,
                        index: index,
                        atPresentationTimeStamp: presentationTimeStamp
                    ),
                    nil
                )
            }
        } catch {
            logger.error(
                "AudioTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("AudioTrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        do {
            if dec_ctx != nil {
                return completionHandler(
                    try DecodedSampleCursor(
                        format: format,
                        track: self,
                        index: index,
                        atPresentationTimeStamp: stream.start_time != AV_NOPTS_VALUE
                            ? CMTime(value: stream.start_time, timeBase: stream.time_base) : .zero
                    ),
                    nil
                )
            } else {
                return completionHandler(
                    try PassthruSampleCursor(
                        format: format,
                        track: self,
                        index: index,
                        atPresentationTimeStamp: stream.start_time != AV_NOPTS_VALUE
                            ? CMTime(value: stream.start_time, timeBase: stream.time_base) : .zero
                    ),
                    nil
                )
            }
        } catch {
            logger.error(
                "AudioTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtFirstSampleInDecodeOrder: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("AudioTrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        do {
            if dec_ctx != nil {
                return completionHandler(
                    try DecodedSampleCursor(
                        format: format,
                        track: self,
                        index: index,
                        atPresentationTimeStamp: .positiveInfinity
                    ),
                    nil
                )
            } else {
                return completionHandler(
                    try PassthruSampleCursor(
                        format: format,
                        track: self,
                        index: index,
                        atPresentationTimeStamp: .positiveInfinity
                    ),
                    nil
                )
            }
        } catch {
            logger.error(
                "AudioTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtLastSampleInDecodeOrder: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

}
