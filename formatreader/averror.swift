//
//  averror.swift
//  QLVideo
//
//  Created by Jonathan Harris on 03/12/2025.
//

import Foundation

// Swift bridging can't figure out FFmpeg error codes
let AVERROR_BSF_NOT_FOUND: Int32 = -1_179_861_752  // øBSF
let AVERROR_BUG: Int32 = -558_323_010  // BUG!
let AVERROR_BUFFER_TOO_SMALL: Int32 = -1_397_118_274  // BUFS
let AVERROR_DECODER_NOT_FOUND: Int32 = -1_128_613_112  // øDEC
let AVERROR_DEMUXER_NOT_FOUND: Int32 = -1_296_385_272  // øDEM
let AVERROR_ENCODER_NOT_FOUND: Int32 = -1_129_203_192  // øENC
let AVERROR_EOF: Int32 = -541_478_725  // EOF
let AVERROR_EXIT: Int32 = -1_414_092_869  // EXIT
let AVERROR_EXTERNAL: Int32 = -542_398_533  // EXT
let AVERROR_FILTER_NOT_FOUND: Int32 = -1_279_870_712  // øFIL
let AVERROR_INVALIDDATA: Int32 = -1_094_995_529  // INDA
let AVERROR_MUXER_NOT_FOUND: Int32 = -1_481_985_528  // øMUX
let AVERROR_OPTION_NOT_FOUND: Int32 = -1_414_549_496  // øOPT
let AVERROR_PATCHWELCOME: Int32 = -1_163_346_256  // PAWE
let AVERROR_PROTOCOL_NOT_FOUND: Int32 = -1_330_794_744  // øPRO
let AVERROR_STREAM_NOT_FOUND: Int32 = -1_381_258_232  // øSTR
let AVERROR_BUG2: Int32 = -541_545_794  // BUG
let AVERROR_UNKNOWN: Int32 = -1_313_558_101  // UNKN
let AVERROR_EXPERIMENTAL: Int32 = -733_130_664  // -0x2bb2afa8
let AVERROR_INPUT_CHANGED: Int32 = -1_668_179_713  // -0x636e6701
let AVERROR_OUTPUT_CHANGED: Int32 = -1_668_179_714  // -0x636e6702
let AVERROR_EAGAIN: Int32 = -EAGAIN

final class AVERROR: CustomNSError {

    static var errorDomain: String { return "uk.org.marginal.qlvideo" }
    let errorCode: Int
    let errorUserInfo: [String: String]

    init(errorCode: Int32, context: String? = nil, file: String? = nil) {
        // https://stackoverflow.com/questions/66727481/what-is-nslocalizedfailureerrorkey-for/78083999#78083999
        self.errorCode = Int(errorCode)
        let errno = self.errorCode >= -ELAST ? " (errno \(-self.errorCode))" : ""
        var buf = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        var userInfo: [String: String] = [
            NSLocalizedFailureReasonErrorKey: String(
                cString: av_make_error_string(&buf, Int(AV_ERROR_MAX_STRING_SIZE), errorCode)
            ) + errno
        ]
        if let context { userInfo[NSLocalizedFailureErrorKey] = context }
        if let file { userInfo[NSFilePathErrorKey] = file }
        self.errorUserInfo = userInfo
    }

    var errorDescription: String {
        if let context = errorUserInfo[NSLocalizedFailureErrorKey] {
            return "\(context): \(errorUserInfo[NSLocalizedFailureReasonErrorKey]!)"
        } else {
            return "\(errorUserInfo[NSLocalizedFailureReasonErrorKey]!)"
        }
    }

    var failureReason: String {
        return errorUserInfo[NSLocalizedFailureReasonErrorKey]!
    }
}
