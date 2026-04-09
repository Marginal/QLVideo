//
//  subtitletrackreader.swift
//  QLVideo
//

import Foundation
import MediaExtension
import OSLog

class SubtitleTrackReader: TrackReader, METrackReader {

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        let params = stream.pointee.codecpar!
        guard params.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        var isForced = stream.pointee.disposition & AV_DISPOSITION_FORCED != 0
        if let entry = av_dict_get(stream.pointee.metadata, "title", nil, 0),
            let value = String(validatingUTF8: entry.pointee.value),
            value.lowercased().contains("forced")  // FFmpeg doesn't always set AV_DISPOSITION_FORCED
        {
            isForced = true
        }

        var extensions: [CFString: Any] = [:]
        if isForced {
            extensions[kCMTextFormatDescriptionExtension_DisplayFlags] = kCMTextDisplayFlag_allSubtitlesForced as CFNumber
        }

        // The vttC payload is just the config string (text after "WEBVTT" header), which is typically empty.
        let bytes: [UInt8] = [0x57, 0x45, 0x42, 0x56, 0x54, 0x54]  // "WEBVTT"
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
            ["vttC" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary

        logger.debug(
            "SubtitleTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) codec:\"\(String(cString:avcodec_get_name(params.pointee.codec_id)), privacy:.public)\" extensions:\(extensions, privacy:.public)"
        )
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: isForced ? kCMMediaType_Text : kCMMediaType_Subtitle,
            mediaSubType: kCMSubtitleFormatType_WebVTT,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "SubtitleTrackReader stream \(self.index) loadTrackInfo CMFormatDescriptionCreate returned \(err, privacy:.public)"
            )
            return completionHandler(nil, err)
        }
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Subtitle,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isForced  // Start out with subtitles disabled
        if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
            // TODO: check language is RFC4646 compliant and try to map if not
            trackInfo.extendedLanguageTag = String(validatingUTF8: entry.pointee.value)
        }

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
                "SubtitleTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public)"
            )
        }
        do {
            return completionHandler(
                try SubtitleSampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: presentationTimeStamp
                ),
                nil
            )
        } catch {
            logger.error(
                "SubtitleTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("SubtitleTrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        do {
            return completionHandler(
                try SubtitleSampleCursor(
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
                "SubtitleTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtFirstSampleInDecodeOrder: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("SubtitleTrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        do {
            return completionHandler(
                try SampleCursor(format: format, track: self, index: index, atPresentationTimeStamp: .positiveInfinity),
                nil
            )
        } catch {
            logger.error(
                "SubtitleTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtLastSampleInDecodeOrder: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }
}
