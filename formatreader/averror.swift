//
//  averror.swift
//  QLVideo
//
//  Created by Jonathan Harris on 03/12/2025.
//

import Foundation

final class AVERROR: CustomNSError {

    static var errorDomain: String { return "uk.org.marginal.qlvideo" }
    var errorCode = 0
    var errorUserInfo: [String: Any] = [:]

    init(errorCode: Int32, context: String? = nil, file: String? = nil) {
        // https://stackoverflow.com/questions/66727481/what-is-nslocalizedfailureerrorkey-for/78083999#78083999
        self.errorCode = Int(errorCode)
        var buf = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        self.errorUserInfo[NSLocalizedFailureReasonErrorKey] = String(
            cString: av_make_error_string(&buf, Int(AV_ERROR_MAX_STRING_SIZE), errorCode)
        )
        if context != nil { self.errorUserInfo[NSLocalizedFailureErrorKey] = context }
        if file != nil { self.errorUserInfo[NSFilePathErrorKey] = file }
    }

    // Unneccessary
    //func localizedDescription() -> String {
    //    if let context = errorUserInfo[NSLocalizedFailureErrorKey] {
    //        return "\(context): \(errorUserInfo[NSLocalizedFailureReasonErrorKey] ?? "unknown")"
    //    } else {
    //        return "\(errorUserInfo[NSLocalizedFailureReasonErrorKey] ?? "unknown")"
    //    }
    //}
}
