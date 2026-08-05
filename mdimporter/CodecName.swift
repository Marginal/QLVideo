//
//  CodecName.swift
//  QLVideo
//
// Some of AVCodec.long_name can be too wordy (see libavcodec/codec_desc.c) but .name too cryptic,
// so special-case some common codecs to give more compact & Applesque names
//

class CodecName {

    private static let codecNames: [AVCodecID: String] = [
        // audio
        AV_CODEC_ID_AAC: "MPEG-4 AAC",  // CoreMedia.mdimporter uses "MPEG-4 AAC"
        AV_CODEC_ID_AC3: "Dolby Digital",
        AV_CODEC_ID_ALAC: "Apple Lossless",
        AV_CODEC_ID_ATRAC1: "ATRAC1",
        AV_CODEC_ID_ATRAC3P: "ATRAC3+",
        AV_CODEC_ID_COOK: "RealAudio G2",
        AV_CODEC_ID_DTS: "DTS",
        AV_CODEC_ID_EAC3: "Dolby Digital Plus",
        AV_CODEC_ID_FLAC: "FLAC",
        AV_CODEC_ID_MP2: "MPEG Layer 2",
        AV_CODEC_ID_MP3: "MPEG Layer 3",
        AV_CODEC_ID_RA_144: "RealAudio 1.0",
        AV_CODEC_ID_RA_288: "RealAudio 2.0",
        AV_CODEC_ID_SIPR: "RealAudio SIPR",
        AV_CODEC_ID_WMALOSSLESS: "WM Audio Lossless",
        AV_CODEC_ID_WMAPRO: "WM Audio 9 Pro",
        AV_CODEC_ID_WMAV1: "WM Audio 1",
        AV_CODEC_ID_WMAV2: "WM Audio 2",
        AV_CODEC_ID_WMAVOICE: "WM Audio Voice",
        // video
        AV_CODEC_ID_AV1: "AV1",
        AV_CODEC_ID_CAVS: "CAVS",
        AV_CODEC_ID_CLEARVIDEO: "ClearVideo",
        AV_CODEC_ID_FLIC: "FLIC",
        AV_CODEC_ID_FLV1: "Sorenson Spark",
        AV_CODEC_ID_H263: "H.263",
        AV_CODEC_ID_H263P: "H.263+",
        AV_CODEC_ID_H264: "H.264",
        AV_CODEC_ID_HEVC: "HEVC",  // CoreMedia.mdimporter uses "HEVC"
        AV_CODEC_ID_INDEO4: "Intel Indeo 4",
        AV_CODEC_ID_INDEO5: "Intel Indeo 5",
        AV_CODEC_ID_MPEG1VIDEO: "MPEG-1",
        AV_CODEC_ID_MPEG2VIDEO: "MPEG-2",
        AV_CODEC_ID_MPEG4: "MPEG-4 Video",  // CoreMedia.mdimporter uses "MPEG-4 Video"
        AV_CODEC_ID_MSMPEG4V1: "MPEG-4 Video [MSv1]",
        AV_CODEC_ID_MSMPEG4V2: "MPEG-4 Video [MSv2]",
        AV_CODEC_ID_MSMPEG4V3: "MPEG-4 Video [MSv3]",
        AV_CODEC_ID_MSS2: "WM Video 9 Screen",
        AV_CODEC_ID_QTRLE: "QuickTime Animation",
        AV_CODEC_ID_RPZA: "QuickTime Video",
        AV_CODEC_ID_SVQ1: "Sorenson Video",
        AV_CODEC_ID_SVQ3: "Sorenson Video 3",  // CoreMedia.mdimporter uses "Sorenson Video 3"
        AV_CODEC_ID_VC1: "VC-1",
        AV_CODEC_ID_VC1IMAGE: "WM Video 9 Image v2",
        AV_CODEC_ID_VP6: "VP6",
        AV_CODEC_ID_VP6A: "VP6",
        AV_CODEC_ID_VP6F: "VP6",
        AV_CODEC_ID_VP8: "VP8",
        AV_CODEC_ID_VP9: "VP9",
        AV_CODEC_ID_VVC: "H.266",
        AV_CODEC_ID_WMV1: "WM Video 7",
        AV_CODEC_ID_WMV2: "WM Video 8",
        AV_CODEC_ID_WMV3: "WM Video 9",
        AV_CODEC_ID_WMV3IMAGE: "WM Video 9 Image",
        // subtitles
        AV_CODEC_ID_ASS: "Advanced SSA subtitle",
        AV_CODEC_ID_HDMV_PGS_SUBTITLE: "PGS subtitle",
        AV_CODEC_ID_MOV_TEXT: "QuickTime Text",  // CoreMedia.mdimporter uses "QuickTime Text"
        AV_CODEC_ID_PJS: "PJS subtitle",
        AV_CODEC_ID_SRT: "SubRip subtitle",
        AV_CODEC_ID_SSA: "SSA subtitle",
    ]

    static func name(params: UnsafeMutablePointer<AVCodecParameters>) -> String? {
        // Codec names
        if let codec = avcodec_find_decoder(params.pointee.codec_id) {
            var codecName = self.codecNames[params.pointee.codec_id]
            if codecName == nil {
                if params.pointee.codec_tag == 0x5741_5243 {  // 'CRAW'
                    codecName = "C-RAW"
                } else if let nameC = codec.pointee.long_name {
                    codecName = String(cString: nameC)
                } else if let nameC = codec.pointee.name {
                    codecName = String(cString: nameC)
                }
            }

            if let codecName {
                if params.pointee.codec_id == AV_CODEC_ID_MPEG4
                    && [0x4449_5658, 0x5856_4944, 0x4458_3530].contains(params.pointee.codec_tag)  // 'DIVX', 'XVID', 'DX50'
                {
                    return "\(codecName) [DivX]"
                } else if let profileC = av_get_profile_name(codec, params.pointee.profile) {
                    return "\(codecName) [\(String(cString: profileC))]"
                } else {
                    return codecName
                }
            }
        }
        return nil
    }

}
