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
    weak var format: FormatReader?
    var stream: UnsafeMutablePointer<AVStream>
    var formatDescription: CMFormatDescription? = nil
    var sampleCursors = NSHashTable<SampleCursor>.weakObjects()  // for dumpState()

    init(format: FormatReader, stream: UnsafeMutablePointer<AVStream>, index: Int, enabled: Bool) {
        self.index = index
        self.isEnabled = enabled
        self.format = format
        self.stream = stream
        super.init()
        if TRACE_SAMPLE_CURSOR {
            logger.debug("\(String(describing: type(of: self)), privacy: .public) init for stream #\(self.index)")
        }
    }

    deinit {
        logger.debug("\(String(describing: type(of: self)), privacy: .public) deinit for stream #\(self.index)")
    }

    @objc
    func loadUneditedDuration(completionHandler: @escaping (CMTime, (any Error)?) -> Void) {
        format?.loadUneditedDurationCalled = true
        if stream.pointee.duration != 0 {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(String(describing: type(of: self)), privacy: .public) stream \(self.index) loadUneditedDuration = \(CMTime(value: self.stream.pointee.duration, timeBase: self.stream.pointee.time_base), privacy: .public)"
                )
            }
            return completionHandler(CMTime(value: stream.pointee.duration, timeBase: stream.pointee.time_base), nil)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(String(describing: type(of: self)), privacy: .public) stream \(self.index) loadUneditedDuration = unknown")
            }
            return completionHandler(.indefinite, MEError(.unsupportedFeature))
        }
    }

}
