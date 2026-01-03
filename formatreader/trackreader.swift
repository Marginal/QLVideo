//
//  trackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 03/12/2025.
//

import Foundation
import MediaExtension
import OSLog

class TrackReader: NSObject, METrackReader {

    var index = -1
    var isEnabled: Bool = false
    var format: FormatReader
    var stream: AVStream
    @objc var formatDescription: CMFormatDescription? = nil

    init(format: FormatReader, stream: AVStream, index: Int, enabled: Bool) {
        self.index = index
        self.isEnabled = enabled
        self.format = format
        self.stream = stream
        super.init()
        if TRACE_SAMPLE_CURSOR {
            logger.debug("TrackReader init for stream #\(index)")
        }
    }

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {
        logger.error("TrackReader loadTrackInfo called")
        return completionHandler(nil, MEError(.internalFailure))
    }

    func loadUneditedDuration(completionHandler: @escaping (CMTime, (any Error)?) -> Void) {
        if stream.duration != 0 {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "TrackReader stream \(self.index) loadUneditedDuration = \(CMTime(value: self.stream.duration, timeBase: self.stream.time_base))"
                )
            }
            return completionHandler(CMTime(value: stream.duration, timeBase: stream.time_base), nil)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("TrackReader stream \(self.index) loadUneditedDuration = unknown")
            }
            return completionHandler(.indefinite, MEError(.invalidParameter))
        }
    }

    // The new sample cursor points to the last sample with a presentation time stamp (PTS) less than or equal to
    // presentationTimeStamp, or if there are no such samples, the first sample in PTS order.
    func generateSampleCursor(
        atPresentationTimeStamp presentationTimeStamp: CMTime,
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("TrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp)")
        }
        return completionHandler(
            SampleCursor(format: format, track: self, index: index, atPresentationTimeStamp: presentationTimeStamp),
            nil
        )
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("TrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        return completionHandler(
            SampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: stream.start_time != AV_NOPTS_VALUE
                    ? CMTime(value: stream.start_time, timeBase: stream.time_base) : .zero
            ),
            nil
        )
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("TrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        return completionHandler(
            SampleCursor(format: format, track: self, index: index, atPresentationTimeStamp: .positiveInfinity),
            nil
        )
    }

}
