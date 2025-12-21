//
//  audiotrackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 18/11/2025.
//

import Foundation
import MediaExtension
import OSLog

class AudioTrackReader: TrackReader {

    // AVCodecParameters.codec_tag can be zero(!) so prefer .codec_id for common types known to AVFoundation
    // See https://ffmpeg.org/doxygen/8.0/matroska_8c_source.html#l00027 for the codec_ids that FFmpeg expects in a Matroska container
    static let fourcc: [AVCodecID: AudioFormatID] = [
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
        AV_CODEC_ID_AC3: kAudioFormatAC3,
        // kAudioFormat60958AC3
        AV_CODEC_ID_ADPCM_IMA_QT: kAudioFormatAppleIMA4,
        AV_CODEC_ID_AAC: kAudioFormatMPEG4AAC,
        // MPEG4CELP: kAudioFormatMPEG4CELP, // not supported by FFmpeg
        // MPEG4HVXC: kAudioFormatMPEG4HVXC, // not supported by FFmpeg
        // MPEG4TwinVQ: kAudioFormatMPEG4TwinVQ, // not supported by FFmpeg
        AV_CODEC_ID_MACE3: kAudioFormatMACE3,
        AV_CODEC_ID_MACE6: kAudioFormatMACE6,
        AV_CODEC_ID_PCM_MULAW: kAudioFormatULaw,
        AV_CODEC_ID_PCM_ALAW: kAudioFormatALaw,
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
        static let AV_CH_LAYOUT_5POINT1: ChannelMasks = [.AV_CH_LAYOUT_5POINT0, .AV_CH_LOW_FREQUENCY]
        static let AV_CH_LAYOUT_7POINT1: ChannelMasks = [.AV_CH_LAYOUT_5POINT1, .AV_CH_BACK_LEFT, .AV_CH_BACK_RIGHT]
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

    override func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        let params = stream.codecpar.pointee
        guard params.codec_type == AVMEDIA_TYPE_AUDIO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        #if DEBUG
            let hex = UnsafeBufferPointer(start: params.extradata, count: Int(params.extradata_size)).map {
                String(format: "%02x", $0)
            }.joined(separator: " ")
            logger.debug(
                "loadTrackInfo for stream #\(self.index) enabled:\(self.isEnabled) time_base:\(self.stream.time_base.num)/\(self.stream.time_base.den) start_time:\(self.stream.start_time) duration:\(self.stream.duration == AV_NOPTS_VALUE ? -1 : self.stream.duration) disposition:\(UInt(self.stream.disposition), format:.hex) codecpar: codec_id:\(String(cString:avcodec_get_name(params.codec_id)), privacy: .public) codec_tag:\"\(FormatReader.av_fourcc2str(params.codec_tag), privacy:.public)\" format:\(String(cString: av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy:.public) sample_rate:\(params.sample_rate) frame_size:\(params.frame_size) bits_per_coded_sample:\(params.bits_per_coded_sample) bits_per_raw_sample:\(params.bits_per_raw_sample) layout: order:\(params.ch_layout.order.rawValue) nb_channels:\(params.ch_layout.nb_channels) mask:\(params.ch_layout.u.mask, format: .hex) extradata \(params.extradata_size) bytes: \(hex)"
            )
        #endif

        var layoutTag = kAudioChannelLayoutTag_Unknown
        if params.ch_layout.order == AV_CHANNEL_ORDER_NATIVE {
            switch params.ch_layout.u.mask {
            // common cases where FFmpeg channel order matches that expected by an AudioChannelLayoutTag
            case ChannelMasks.AV_CH_LAYOUT_MONO.rawValue:  // FC
                layoutTag = kAudioChannelLayoutTag_Mono
            case ChannelMasks.AV_CH_LAYOUT_STEREO.rawValue:  // FL+FR
                layoutTag = kAudioChannelLayoutTag_Stereo
            case ChannelMasks.AV_CH_LAYOUT_5POINT1.rawValue:  // FL+FR+FC+LFE+SL+SR
                layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            case ChannelMasks.AV_CH_LAYOUT_7POINT1.rawValue:  // FL+FR+FC+LFE+BL+BR+SL+SR
                layoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
            default:
                // FFmpeg presents channels in order of AVChannel enum, which in general is not the same order
                // that various AudioChannelLayoutTags expect. So describe channels individually below.
                layoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            }
        } else if params.ch_layout.order == AV_CHANNEL_ORDER_CUSTOM {
            // TODO: layoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            logger.error("loadTrackInfo for stream #\(self.index): unhandled custom channel layout")
        } else if params.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            // AVFoundation won't play with unknown layout, so make some assumptions
            switch params.ch_layout.nb_channels {
            case 1:
                layoutTag = kAudioChannelLayoutTag_Mono
            case 2:
                layoutTag = kAudioChannelLayoutTag_Stereo
            default:
                logger.error("loadTrackInfo for stream #\(self.index): unspecified channel layout")
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
                if channel_mask & UInt64(1 << 63) != 0 { break }
                channel_mask = channel_mask << 1
            }
            layout.mNumberChannelDescriptions = UInt32(channel_number)
            assert(channel_number == Int(params.ch_layout.nb_channels))
        }

        // See definitions at https://developer.apple.com/documentation/CoreAudioTypes/AudioStreamBasicDescription#overview
        //   sample = a single value for a single channel
        //   frame = set of time-coincident samples for all channels in the stream e.g. 2 samples for a stereo channel

        // From CoreAudioBaseTypes.h: "In non-interleaved [=planar] audio, the per frame fields identify one channel".
        let uncompressed = [kAudioFormatLinearPCM, kAudioFormatALaw, kAudioFormatULaw].contains(
            AudioTrackReader.fourcc[params.codec_id]
        )
        let flags =
            AudioTrackReader.formatFlags[
                uncompressed ? AVSampleFormat(params.format) : av_get_packed_sample_fmt(AVSampleFormat(params.format))
            ]
            ?? 0  // FFmpeg reports compressed data e.g. AAC as planar but CoreAudio disagrees
        let planar = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(params.sample_rate),
            mFormatID: AudioTrackReader.fourcc[params.codec_id] ?? params.codec_tag,
            mFormatFlags: flags
                | (params.bits_per_raw_sample == params.bits_per_coded_sample
                    ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh),
            mBytesPerPacket: uncompressed
                ? UInt32(params.bits_per_coded_sample >> 3) * UInt32(planar ? 1 : params.ch_layout.nb_channels)
                : 0,
            mFramesPerPacket: UInt32(uncompressed ? 1 : params.frame_size),  // "In uncompressed audio, a Packet is one frame"
            mBytesPerFrame: uncompressed
                ? UInt32(params.bits_per_coded_sample >> 3) * UInt32(planar ? 1 : params.ch_layout.nb_channels)
                : 0,
            mChannelsPerFrame: UInt32(params.ch_layout.nb_channels),
            mBitsPerChannel: UInt32(params.bits_per_raw_sample),  // e.g. 24
            mReserved: 0
        )
        logger.debug(
            "loadTrackInfo for stream #\(self.index) enabled:\(self.isEnabled) timescale:\(self.stream.time_base.den) layout:0x\(layoutTag, format:.hex) absd: sampleRate:\(Int(asbd.mSampleRate)) formatID:\"\(FormatReader.av_fourcc2str(asbd.mFormatID), privacy: .public)\" formatFlags:0x\(asbd.mFormatFlags, format: .hex) bytesPerPacket:\(asbd.mBytesPerPacket) framesPerPacket:\(asbd.mFramesPerPacket) bytesPerFrame:\(asbd.mBytesPerFrame) channelsPerFrame:\(asbd.mChannelsPerFrame) bitsPerChannel:\(asbd.mBitsPerChannel)"
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
            logger.error("CMAudioFormatDescriptionCreate returned \(err, privacy:.public)")
            return completionHandler(nil, err)
        }
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Audio,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isEnabled
        // TODO: set extendedLanguageTag from stream metadata "language" tag
        trackInfo.naturalTimescale = stream.time_base.den

        format.tracks[index] = self
        completionHandler(trackInfo, nil)
    }
}
