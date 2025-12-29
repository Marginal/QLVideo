//
//  averror.swift
//  QLVideo
//
//  Created by Jonathan Harris on 03/12/2025.
//

import Foundation

// Swift bridging can't figure out FFmpeg error codes
let AVERROR_BSF_NOT_FOUND: Int32 = -0x4653_42f8
let AVERROR_BUG: Int32 = -0x2147_5542
let AVERROR_BUFFER_TOO_SMALL: Int32 = -0x5346_5542
let AVERROR_DECODER_NOT_FOUND: Int32 = -0x4345_44f8
let AVERROR_DEMUXER_NOT_FOUND: Int32 = -0x4d45_44f8
let AVERROR_ENCODER_NOT_FOUND: Int32 = -0x434e_45f8
let AVERROR_EOF: Int32 = -0x2046_4f45
let AVERROR_EXIT: Int32 = -0x5449_5845
let AVERROR_EXTERNAL: Int32 = -0x2054_5845
let AVERROR_FILTER_NOT_FOUND: Int32 = -0x4c49_46f8
let AVERROR_INVALIDDATA: Int32 = -0x4144_4e49
let AVERROR_MUXER_NOT_FOUND: Int32 = -0x5855_4df8
let AVERROR_OPTION_NOT_FOUND: Int32 = -0x5450_4ff8
let AVERROR_PATCHWELCOME: Int32 = -0x4557_4150
let AVERROR_PROTOCOL_NOT_FOUND: Int32 = -0x4f52_50f8
let AVERROR_STREAM_NOT_FOUND: Int32 = -0x5254_53f8
let AVERROR_BUG2: Int32 = -0x2047_5542
let AVERROR_UNKNOWN: Int32 = -0x4e4b_4e55
let AVERROR_EXPERIMENTAL: Int32 = -0x2bb2_afa8
let AVERROR_INPUT_CHANGED: Int32 = -0x636e_6701
let AVERROR_OUTPUT_CHANGED: Int32 = -0x636e_6702

final class AVERROR: CustomNSError, LocalizedError {

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

    var errorDescription: String? {
        if let context = errorUserInfo[NSLocalizedFailureErrorKey] {
            return "\(context): \(errorUserInfo[NSLocalizedFailureReasonErrorKey]!)"
        } else {
            return "\(errorUserInfo[NSLocalizedFailureReasonErrorKey]!)"
        }
    }

    var failureReason: String? {
        return errorUserInfo[NSLocalizedFailureReasonErrorKey]
    }
}
