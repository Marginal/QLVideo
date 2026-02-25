//
//  GetMetadataForFile.swift
//  Video
//
//  Created by Jonathan Harris on 03/07/2014.
//
//

import CoreMedia
import Foundation
import OSLog

let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "mdimporter")

private let kFrameRate = "uk_org_marginal_qlvideo_framerate" as CFString
private let kSubtitles = "uk_org_marginal_qlvideo_subtitles" as CFString

private var dateFormatters: [ISO8601DateFormatter]? = nil

@_cdecl("GetMetadataForFile")
public func GetMetadataForFile(
    _ thisInterface: UnsafeMutableRawPointer?,
    _ attributes: CFMutableDictionary?,
    _ contentTypeUTI: CFString?,
    _ pathToFile: CFString?
) -> DarwinBoolean {
    let filename = pathToFile as String? ?? "?"
    #if DEBUG
        logger.info("Import \(filename, privacy: .public) with UTI=\(contentTypeUTI as String? ?? "?", privacy: .public)")
    #else
        logger.info(
            "Import \(filename, privacy: .private(mask:.hash)) with UTI=\(contentTypeUTI as String? ?? "?", privacy: .public)"
        )
    #endif
    guard let attributes else {
        logger.error("mdimporter can't open access attributes dictionary")
        return false
    }
    let attrs = attributes as NSMutableDictionary

    var fmt_ctx: UnsafeMutablePointer<AVFormatContext>? = nil
    var ret = avformat_open_input(&fmt_ctx, filename, nil, nil)
    guard ret == 0 else {
        let err = AVERROR(errorCode: ret, context: "avformat_open_input", file: filename)
        #if DEBUG
            logger.error("mdimporter can't open \(filename, privacy:.public): \(err.localizedDescription, privacy:.public)")
        #else
            logger.error(
                "mdimporter can't open \(filename, privacy:.private(mask:.hash)): \(err.localizedDescription, privacy:.public)"
            )
        #endif
        return false
    }

    ret = avformat_find_stream_info(fmt_ctx, nil)
    guard ret == 0 else {
        let err = AVERROR(errorCode: ret, context: "avformat_find_stream_info", file: filename)
        #if DEBUG
            logger.error(
                "mdimporter can't read stream info from \(filename, privacy:.public): \(err.localizedDescription, privacy:.public)"
            )
        #else
            logger.error(
                "mdimporter can't read stream info from \(filename, privacy:.private(mask:.hash)): \(err.localizedDescription, privacy:.public)"
            )
        #endif
        return false
    }

    if let fmt_ctx {
        // From the container
        if fmt_ctx.pointee.bit_rate > 0 {
            attrs[kMDItemTotalBitRate!] = fmt_ctx.pointee.bit_rate as CFNumber
        }
        if fmt_ctx.pointee.duration > 0 {
            attrs[kMDItemDurationSeconds!] =
                CMTime(value: fmt_ctx.pointee.duration, timescale: AV_TIME_BASE).seconds.rounded(.toNearestOrEven) as CFNumber
        }

        // File-level tags see https://wiki.multimedia.cx/index.php/FFmpeg_Metadata
        // https://www.matroska.org/technical/tagging.html
        // https://learn.microsoft.com/en-gb/windows/win32/wmformat/attribute-list
        // See MDItem.h in Metadata.framework for expected CFString, CFNumber, CFArray types
        var entry = av_dict_iterate(fmt_ctx.pointee.metadata, nil)
        while entry != nil {
            guard let keyC = entry!.pointee.key,
                let valC = entry!.pointee.value,
                let key = String(validatingUTF8: keyC),
                let value = String(validatingUTF8: valC),
                !value.isEmpty
            else { continue }

            switch key.lowercased() {
            case "album",
                "sort_album",
                "wm/albumtitle":
                attrs[kMDItemAlbum!] = value as CFString
            case "artist",
                "author",
                "sort_artist":
                append(kMDItemPerformers, value as CFString, in: attrs)
            case "comment": attrs[kMDItemComment!] = value as CFString
            case "composer": attrs[kMDItemComposer!] = value as CFString
            case "copyright": attrs[kMDItemCopyright!] = value as CFString
            case "creation_time": setDate(kMDItemContentCreationDate, value, in: attrs)
            case "date",
                "wm/mediaoriginalbroadcastdatetime":
                if let year = Int(value) {
                    attrs[kMDItemRecordingYear!] = year as CFNumber
                } else {
                    setDate(kMDItemRecordingDate, value, in: attrs)
                }
            case "description": attrs[kMDItemDescription!] = value as CFString
            case "encoder",
                "encoding_tool":
                append(kMDItemEncodingApplications, value as CFString, in: attrs)
            case "genre": attrs[kMDItemGenre!] = value as CFString
            case "keywords": append(kMDItemKeywords, value as CFString, in: attrs)
            case "language": appendLanguage(kMDItemLanguages, value, in: attrs)
            case "lyricist": attrs[kMDItemLyricist!] = value as CFString
            case "performers": append(kMDItemPerformers, value as CFString, in: attrs)
            case "publisher",
                "service_name",
                "service_provider",
                "wm/publisher":
                append(kMDItemPublishers, value as CFString, in: attrs)
            case "synopsis": attrs[kMDItemHeadline!] = value as CFString
            case "title",
                "sort_name":
                attrs[kMDItemTitle!] = value as CFString
            case "track":
                if let sep = value.firstIndex(of: "/") {
                    if let track = Int(value[..<sep]) { attrs[kMDItemAudioTrackNumber!] = track as CFNumber }
                } else {
                    if let track = Int(value) { attrs[kMDItemAudioTrackNumber!] = track as CFNumber }
                }
            default:
                logger.info("Skipping unknown tag \(key, privacy: .public)=\(value, privacy: .public)")
            }
            entry = av_dict_iterate(fmt_ctx.pointee.metadata, entry)
        }

        // Video stream
        let videoIdx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if videoIdx >= 0 {
            let stream = fmt_ctx.pointee.streams[Int(videoIdx)]!
            let params = stream.pointee.codecpar!
            if params.pointee.bit_rate > 0 { attrs[kMDItemVideoBitRate!] = params.pointee.bit_rate as CFNumber }
            if params.pointee.height > 0 {
                attrs[kMDItemPixelHeight!] = params.pointee.height as CFNumber
                let sar = av_guess_sample_aspect_ratio(fmt_ctx, stream, nil)
                let width: Int32
                if sar.num != 0 && sar.den != 0 {
                    width = Int32(av_rescale(Int64(params.pointee.width), Int64(sar.num), Int64(sar.den)))
                } else {
                    width = params.pointee.width
                }
                attrs[kMDItemPixelWidth!] = width as CFNumber
            }
            if stream.pointee.avg_frame_rate.num != 0 && stream.pointee.avg_frame_rate.den != 0 {
                attrs[kFrameRate] = ((av_q2d(stream.pointee.avg_frame_rate) * 100).rounded(.toNearestOrEven) / 100) as CFNumber
            }
            append(kMDItemMediaTypes, "Video" as CFString, in: attrs)
        }

        // Audio stream
        let audioIdx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if audioIdx >= 0 {
            let stream = fmt_ctx.pointee.streams[Int(audioIdx)]!
            let params = stream.pointee.codecpar!
            if params.pointee.bit_rate > 0 { attrs[kMDItemAudioBitRate!] = params.pointee.bit_rate as CFNumber }
            if params.pointee.sample_rate > 0 { attrs[kMDItemAudioSampleRate!] = params.pointee.sample_rate as CFNumber }
            let channels = Int(params.pointee.ch_layout.nb_channels)
            if channels > 0 {
                switch channels {
                case 6: attrs[kMDItemAudioChannelCount!] = 5.1 as CFNumber
                case 7: attrs[kMDItemAudioChannelCount!] = 6.1 as CFNumber
                case 8: attrs[kMDItemAudioChannelCount!] = 7.1 as CFNumber
                default: attrs[kMDItemAudioChannelCount!] = channels as CFNumber
                }
            }
            let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0)
            if let entry, let valC = entry.pointee.value, let value = String(validatingUTF8: valC) {
                appendLanguage(kMDItemLanguages, value, in: attrs)
            }
            append(kMDItemMediaTypes, "Sound" as CFString, in: attrs)
        }

        // Per-stream metadata
        for idx in 0..<Int(fmt_ctx.pointee.nb_streams) {
            guard let stream = fmt_ctx.pointee.streams[idx] else { continue }
            let params = stream.pointee.codecpar!

            switch params.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                if idx != audioIdx,  // Skip best stream - handled above
                    let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
                    let valC = entry.pointee.value,
                    let value = String(validatingUTF8: valC)
                {
                    appendLanguage(kMDItemLanguages, value, in: attrs)
                }
                append(kMDItemMediaTypes, "Sound" as CFString, in: attrs)

            case AVMEDIA_TYPE_VIDEO:
                if stream.pointee.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS) != 0 {
                    continue
                }
                append(kMDItemMediaTypes, "Video" as CFString, in: attrs)

            case AVMEDIA_TYPE_SUBTITLE:
                if (stream.pointee.disposition & AV_DISPOSITION_FORCED) != 0 { continue }
                if let entry = av_dict_get(stream.pointee.metadata, "title", nil, 0),
                    let valC = entry.pointee.value,
                    let title = String(validatingUTF8: valC),
                    title.lowercased().contains("forced")
                {
                    continue
                }
                if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
                    let valC = entry.pointee.value,
                    let value = String(validatingUTF8: valC)
                {
                    appendLanguage(kSubtitles, value, in: attrs)
                }
                append(kMDItemMediaTypes, "Text" as CFString, in: attrs)

            default:
                let mediaType = av_get_media_type_string(params.pointee.codec_type)
                logger.info(
                    "Skipping unknown stream \(mediaType != nil ? String(cString:mediaType!) : "", privacy:.public)"
                )
            }

            // Codec names
            var codecName: String? = nil
            if let codec = avcodec_find_decoder(params.pointee.codec_id) {
                // Some of AVCodec.long_name can be too wordy (see libavcodec/codec_desc.c) but .name too cryptic,
                // so special-case some common codecs to give more compact & Applesque names
                switch codec.pointee.id {
                case AV_CODEC_ID_H263: codecName = "H.263"
                case AV_CODEC_ID_H263P: codecName = "H.263+"
                case AV_CODEC_ID_H264: codecName = "H.264"
                case AV_CODEC_ID_HEVC: codecName = "H.265"
                case AV_CODEC_ID_MJPEG: codecName = "Motion JPEG"
                case AV_CODEC_ID_FLV1: codecName = "Sorenson Spark"
                case AV_CODEC_ID_SVQ1: codecName = "Sorenson Video"
                case AV_CODEC_ID_SVQ3: codecName = "Sorenson Video 3"
                case AV_CODEC_ID_AAC: codecName = "AAC"
                case AV_CODEC_ID_AC3: codecName = "Dolby Digital"
                case AV_CODEC_ID_EAC3: codecName = "Dolby Digital Plus"
                case AV_CODEC_ID_DTS: codecName = "DTS"
                case AV_CODEC_ID_FLAC: codecName = "FLAC"
                case AV_CODEC_ID_MP2: codecName = "MPEG Layer 2"
                case AV_CODEC_ID_MP3: codecName = "MPEG Layer 3"
                case AV_CODEC_ID_PJS: codecName = "PJS subtitle"
                case AV_CODEC_ID_ASS: codecName = "Advanced SubStation Alpha"
                case AV_CODEC_ID_SSA: codecName = "SubStation Alpha"
                case AV_CODEC_ID_HDMV_PGS_SUBTITLE: codecName = "PGS subtitle"
                case AV_CODEC_ID_SRT: codecName = "SubRip subtitle"
                default:
                    if params.pointee.codec_tag == 0x5741_5243 {  // 'CRAW'
                        codecName = "C-RAW"
                    } else if let nameC = codec.pointee.long_name,
                        let name = String(validatingUTF8: nameC)
                    {
                        codecName = name
                    } else if let nameC = codec.pointee.name,
                        let name = String(validatingUTF8: nameC)
                    {
                        codecName = name
                    }
                }

                if let codecName {
                    if let profileC = av_get_profile_name(
                        avcodec_find_decoder(params.pointee.codec_id),
                        params.pointee.profile
                    ),
                        let profile = String(validatingUTF8: profileC)
                    {
                        append(kMDItemCodecs, "\(codecName) [\(profile)]" as CFString, in: attrs)
                    } else {
                        append(kMDItemCodecs, codecName as CFString, in: attrs)
                    }
                } else {
                    logger.info(
                        "Unsupported codec id \(params.pointee.codec_id.rawValue) for stream #\(idx)"
                    )
                }
            }
        }

    }
    avformat_close_input(&fmt_ctx)
    return true
}

// Add a value to an array at key
private func append(_ key: CFString, _ value: CFString, in attrs: NSMutableDictionary, allowDuplicates: Bool = false) {
    var existing = attrs[key] as? [CFString] ?? []
    if existing.isEmpty {
        attrs[key] = [value] as CFArray
    } else if allowDuplicates || !existing.contains(value) {
        existing.insert(value, at: 0)  // Prepend to preserve order when displayed in Finder
        attrs[key] = existing as CFArray
    }
}

// Convert date string to CFDate, or failing that to CFNumber represeting year
private func setDate(_ key: CFString, _ value: String, in attrs: NSMutableDictionary) {

    if dateFormatters == nil {
        dateFormatters = [
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withFullDate, .withFullTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
                ]  // "2000-01-02T03:04:05+06:00", "2000-01-02T03:04:05+0600", "2000-01-02T03:04:05Z"
                return formatter
            }(),
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withFullDate, .withFullTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
                    .withSpaceBetweenDateAndTime,
                ]  // "2000-01-02 03:04:05+06:00", "2000-01-02 03:04:05+0600", "2000-01-02 03:04:05Z"
                return formatter
            }(),
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withFullDate, .withFullTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withFractionalSeconds,
                ]
                return formatter
            }(),
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withFullDate, .withFullTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withFractionalSeconds,
                    .withSpaceBetweenDateAndTime,
                ]
                return formatter
            }(),
        ]
    }
    for formatter in dateFormatters! {
        if let date = formatter.date(from: value) {
            attrs[key] = date as CFDate
            return
        }
    }
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
        let match = detector.firstMatch(in: value, options: [], range: NSRange(location: 0, length: value.count)),
        let date = match.date
    {
        attrs[key] = date as CFDate
        return
    }
    logger.warning("Can't parse date \(value, privacy: .public)")
}

// Spotlight wants a CFArray of CFStrings representing languages according to RFC3066
// i.e. ISO639 2 or 3 letter code, optionally followed by a dash and ISO3166 2 or 3 letter country code or a dialect
// In practice 3 letter codes are more common e.g. "eng", "jpn", "chi", "hin"
private func appendLanguage(_ key: CFString, _ value: String, in attrs: NSMutableDictionary) {
    let lvalue = value.lowercased()
    if lvalue == "und" || lvalue == "unk" { return }
    // Can't think of an easy way of sanitising input, so just pass though whatever we find and hope for the best
    append(key, lvalue as CFString, in: attrs, allowDuplicates: true)
}
