//
//  trackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 03/12/2025.
//

import Foundation
import MediaExtension
import OSLog

class TrackReader: NSObject {

    var index = -1
    var isEnabled: Bool = false
    var format: FormatReader
    var stream: AVStream
    var formatDescription: CMFormatDescription? = nil
    var dec_ctx: UnsafeMutablePointer<AVCodecContext>? = nil  // for decoding audio
    var swr_ctx: UnsafeMutablePointer<SwrContext>? = nil  //  "

    init(format: FormatReader, stream: AVStream, index: Int, enabled: Bool) {
        self.index = index
        self.isEnabled = enabled
        self.format = format
        self.stream = stream
        super.init()
        if TRACE_SAMPLE_CURSOR {
            logger.debug("TrackReader init for stream #\(self.index)")
        }
    }

    @objc
    func loadUneditedDuration(completionHandler: @escaping (CMTime, (any Error)?) -> Void) {
        if stream.duration != 0 {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "TrackReader stream \(self.index) loadUneditedDuration = \(CMTime(value: self.stream.duration, timeBase: self.stream.time_base), privacy: .public)"
                )
            }
            return completionHandler(CMTime(value: stream.duration, timeBase: stream.time_base), nil)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("TrackReader stream \(self.index) loadUneditedDuration = unknown")
            }
            return completionHandler(.indefinite, MEError(.unsupportedFeature))
        }
    }

}
