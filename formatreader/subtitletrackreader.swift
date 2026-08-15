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

        // The vttC payload is just the config string (text after "WEBVTT" header), which is typically empty.
        //let bytes: [UInt8] = [0x57, 0x45, 0x42, 0x56, 0x54, 0x54]  // "WEBVTT"
        //extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["vttC" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary

        extensions[kCMTextFormatDescriptionExtension_BackgroundColor] =
            [
                kCMTextFormatDescriptionColor_Red: 0 as CFNumber,
                kCMTextFormatDescriptionColor_Green: 0 as CFNumber,
                kCMTextFormatDescriptionColor_Blue: 0 as CFNumber,
                kCMTextFormatDescriptionColor_Alpha: -1 as CFNumber,
            ] as CFDictionary
       extensions[kCMTextFormatDescriptionExtension_DefaultStyle] =
            [
                kCMTextFormatDescriptionStyle_StartChar: 0 as CFNumber,
                kCMTextFormatDescriptionStyle_Font: 1 as CFNumber,
                kCMTextFormatDescriptionStyle_FontFace: 0 as CFNumber,
                kCMTextFormatDescriptionStyle_ForegroundColor: [
                    kCMTextFormatDescriptionColor_Red: -1 as CFNumber,
                    kCMTextFormatDescriptionColor_Green: -1 as CFNumber,
                    kCMTextFormatDescriptionColor_Blue: -1 as CFNumber,
                    kCMTextFormatDescriptionColor_Alpha: -1 as CFNumber,
                ] as CFDictionary,
                kCMTextFormatDescriptionStyle_FontSize: 16 as CFNumber,
                kCMTextFormatDescriptionStyle_EndChar: 0 as CFNumber,
            ] as CFDictionary
        extensions[kCMTextFormatDescriptionExtension_DisplayFlags] = (isForced ? kCMTextDisplayFlag_allSubtitlesForced : 0) as CFNumber
        extensions[kCMTextFormatDescriptionExtension_FontTable] = ["1" as CFString: "Arial" as CFString] as CFDictionary // note FontID is CFString not CFNumber
        extensions[kCMTextFormatDescriptionExtension_HorizontalJustification] = kCMTextJustification_centered as CFNumber
        extensions[kCMTextFormatDescriptionExtension_VerticalJustification] = kCMTextJustification_bottom_right as CFNumber

        logger.debug(
            "SubtitleTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) codec:\"\(String(cString:avcodec_get_name(params.pointee.codec_id)), privacy:.public)\" extensions:\(extensions, privacy:.public)"
        )
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMSubtitleFormatType_3GText,
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
        trackInfo.isEnabled = isForced  // Start out with subtitles disabled, other than forced
        if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
            let lvalue = String(validatingUTF8: entry.pointee.value)?.lowercased(),
            lvalue != "" && lvalue != "und" && lvalue != "unk"
        {
            trackInfo.extendedLanguageTag = Locale.canonicalLanguageIdentifier(from: lvalue)
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
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor = try SubtitleSampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: presentationTimeStamp
            )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "SubtitleSampleCursor stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public): \(error, privacy: .public)"
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
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor = try SubtitleSampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: stream.pointee.start_time != AV_NOPTS_VALUE
                    ? CMTime(value: stream.pointee.start_time, timeBase: stream.pointee.time_base) : .zero
            )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "SubtitleSampleCursor stream \(self.index) generateSampleCursor generateSampleCursorAtFirstSampleInDecodeOrder: \(error, privacy: .public)"
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
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor = try SubtitleSampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: .positiveInfinity
            )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "SubtitleSampleCursor stream \(self.index) generateSampleCursor generateSampleCursorAtLastSampleInDecodeOrder: \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }
}
