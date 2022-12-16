//
//  GetMetadataForFile.m
//  Video
//
//  Created by Jonathan Harris on 03/07/2014.
//
//

#include "GetMetadataForFile.h"

// Custom attributes
NSString *kFrameRate = @"uk_org_marginal_qlvideo_framerate";
NSString *kSubtitles = @"uk_org_marginal_qlvideo_subtitles";


// Return localised language name from ISO639-2 tag in metadata, or nil.
// https://developer.apple.com/library/mac/documentation/MacOSX/Conceptual/BPInternational/LanguageandLocaleIDs/LanguageandLocaleIDs.html
NSString *getLanguage(AVDictionary *metadata)
{
    static NSDictionary *mappings = nil;

    // ISO639-2 doesn't differentiate between different dialects or scripts, so look for text in stream title values to differentiate
    if (!mappings)
        mappings = @{
            @[@"chi", @"simplified"] : @"zh-Hans",
            @[@"chi", @"简体"] : @"zh-Hans",
            @[@"chi", @"traditional"] : @"zh-Hant",
            @[@"chi", @"繁體"] : @"zh-Hant",
            @[@"por", @"eur"] : @"pt-PT",
            @[@"por", @"por"] : @"pt-PT",
            @[@"por", @"bra"] : @"pt-BR",
            @[@"por", @"lat"] : @"pt-BR",
            @[@"spa", @"eur"] : @"es-ES",
            @[@"spa", @"spa"] : @"es-ES",
            @[@"spa", @"lat"] : @"es-419",
        };

    AVDictionaryEntry *language = av_dict_get(metadata, "language", NULL, 0);
    if (!language || !strcmp(language->value, "unk") || !strcmp(language->value, "und"))
        return nil;

    NSLocale *locale;
    NSString *override;
    AVDictionaryEntry *title = av_dict_get(metadata, "title", NULL, 0);
    if (title && (override = mappings[@[@(language->value), [@(title->value) lowercaseString]]])) {
        locale = [NSLocale localeWithLocaleIdentifier:override];
    } else {
        locale = [NSLocale localeWithLocaleIdentifier:@(language->value)];
    }

    // We don't necessarily have access to the user's preferences, so return each language in its language if possible.
    NSString *display = [locale displayNameForKey:NSLocaleIdentifier value:[locale localeIdentifier]];    // can be nil
    if (display)
        return [display capitalizedString]; // for consistency
    else
        return @(language->value); // just return the ISO639-2 code
}

// Return a date formatted how Spotlight expects i.e. "YY-MM-DD HH:MM:SS ±HHMM"
NSString* dateString(NSString *value) {

    static NSDateFormatter *outputFormat = nil;
    static NSISO8601DateFormatter *rfc3339Format = nil;

    if (!outputFormat) {
        // https://developer.apple.com/library/archive/qa/qa1480/_index.html
        outputFormat = [[NSDateFormatter alloc] init];
        outputFormat.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        outputFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        outputFormat.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        outputFormat.dateFormat = @"yyyy'-'MM'-'dd' 'HH':'mm':'ss' 'ZZ'";

        rfc3339Format = [[NSISO8601DateFormatter alloc] init];
        rfc3339Format.formatOptions = NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithTimeZone;
    }

    // strip any fractional seconds
    value = [value stringByReplacingOccurrencesOfString:@"\\.\\d+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, [value length])];

    NSDate *date;
    NSArray *matches;
    if ((date = [rfc3339Format dateFromString:value])) {
        return [outputFormat stringFromDate:date];
    }

    NSError *error;
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:&error];
    if ((matches = [detector matchesInString:value options:0 range:NSMakeRange(0, value.length)])) {
        for (NSTextCheckingResult *match in matches) {
            return [outputFormat stringFromDate:match.date];
        }
    }

    os_log_info(logger, "Can't recognise date \"%{public}@\"", value);
    return value;   // Failed - just return the string unmodified
}

// Helper for adding a value to an array attribute
void addArrayAttribute(NSMutableDictionary *attrs, NSString *key, NSString *value)
{
    if (!value || ![value length])
        return; // don't try to add an empty value

    NSMutableArray *array = attrs[key];
    if (!array)
        attrs[key] = array = [[NSMutableArray alloc] init];
    [array insertObject:value atIndex:0];   // Finder displays lists reversed
}

// Helper for adding a value to an array attribute, discarding duplicates
void addArrayAttributeNoDupes(NSMutableDictionary *attrs, NSString *key, NSString *value)
{
    if (!value || ![value length])
        return; // don't try to add an empty value

    NSMutableArray *array = attrs[key];
    if (!array)
        attrs[key] = array = [[NSMutableArray alloc] init];
    if (![array containsObject:value])
        [array insertObject:value atIndex:0];   // Finder displays lists reversed
}

// Helper for adding a number of values to an array attribute
void addArrayAttributes(NSMutableDictionary *attrs, NSString *key, NSArray *values)
{
    if (!values || ![values count])
        return; // don't try to add empty values

    NSMutableArray *array = attrs[key];
    if (!array)
        attrs[key] = array = [[NSMutableArray alloc] init];
    for (int i = 0; i < values.count; i++) {
        [array insertObject:values[i] atIndex:0];   // Finder displays lists reversed
    }
}


//==============================================================================
//
//	Get metadata attributes from document files
//
//	The purpose of this function is to extract useful information from the
//	file formats for your document, and set the values into the attribute
//  dictionary for Spotlight to include.
//
//==============================================================================

Boolean GetMetadataForFile(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFStringRef pathToFile)
{
    // Pull any available metadata from the file at the specified path
    // Return the attribute keys and attribute values in the dict
    // Return TRUE if successful, FALSE if there was no data provided
	// The path could point to either a Core Data store file in which
	// case we import the store's metadata, or it could point to a Core
	// Data external record file for a specific record instances

    // https://developer.apple.com/library/mac/documentation/Carbon/Conceptual/MDImporters/Concepts/WritingAnImp.html

    @autoreleasepool
    {
        if (!logger)
            logger = os_log_create("uk.org.marginal.qlvideo", "mdimporter");
        os_log_info(logger, "Import with UTI=%{public}@ for %{public}@", contentTypeUTI, pathToFile);

        CFURLRef url = CFURLCreateWithFileSystemPath(NULL, pathToFile, kCFURLPOSIXPathStyle, false);
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter) {
            os_log_error(logger, "Can't import %@", pathToFile);
            return false;
        }

        NSMutableDictionary *attrs = (__bridge NSMutableDictionary *) attributes;   // Prefer to use Objective-C

        // From the container
        if (snapshotter.fmt_ctx->bit_rate > 0) {
            attrs[(__bridge NSString *) kMDItemTotalBitRate] = @(snapshotter.fmt_ctx->bit_rate);
        }
        if (snapshotter.fmt_ctx->duration > 0) {
            attrs[(__bridge NSString *) kMDItemDurationSeconds] = @((float)((double)snapshotter.fmt_ctx->duration/AV_TIME_BASE)); // downcast to float to avoid spurious accuracy
        }

        // From metadata tags - see avformat.h, https://wiki.multimedia.cx/index.php/FFmpeg_Metadata and MDItem.h
        AVDictionaryEntry *tag = NULL;
        while ((tag = av_dict_get(snapshotter.fmt_ctx->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
        {
            if (!tag->value[0]) {
                // shouldn't happen
            } else if (!strcasecmp(tag->value, "album")) {
                attrs[(__bridge NSString *)kMDItemAlbum] = @(tag->value);
            } else if (!strcasecmp(tag->key, "artist")) {
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemPerformers, [@(tag->value) componentsSeparatedByString:@", "]);
            } else if (!strcasecmp(tag->key, "comment")) {
                attrs[(__bridge NSString *)kMDItemComment] = @(tag->value);
            } else if (!strcasecmp(tag->key, "composer")) {
                attrs[(__bridge NSString *)kMDItemComposer] = @(tag->value);
            } else if (!strcasecmp(tag->key, "copyright")) {
                attrs[(__bridge NSString *)kMDItemCopyright] = @(tag->value);
            } else if (!strcasecmp(tag->key, "creation_time")) {
                attrs[(__bridge NSString *)kMDItemContentCreationDate] = dateString(@(tag->value));
            } else if (!strcasecmp(tag->key, "date")) {
                attrs[(__bridge NSString *)kMDItemRecordingDate] = dateString(@(tag->value));
            } else if (!strcasecmp(tag->key, "description")) {
                addArrayAttribute(attrs, (__bridge NSString *)kMDItemHeadline, @(tag->value));
            } else if (!strcasecmp(tag->key, "encoded_by")) {
                addArrayAttribute(attrs, (__bridge NSString *)kMDItemEditors, @(tag->value));
            } else if (!strcasecmp(tag->key, "encoder")) {
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemEncodingApplications, [@(tag->value) componentsSeparatedByString:@" + "]); // " + " is common in Matroska
            } else if (!strcasecmp(tag->key, "genre")) {
                attrs[(__bridge NSString *)kMDItemGenre] = @(tag->value);
            } else if (!strcasecmp(tag->key, "grouping")) {
                addArrayAttribute(attrs, (__bridge NSString *)kMDItemComment, @(tag->value));
            } else if (!strcasecmp(tag->key, "keywords")) {
                addArrayAttribute(attrs, (__bridge NSString *)kMDItemKeywords, @(tag->value));
            } else if (!strcasecmp(tag->key, "language")) {
                addArrayAttribute(attrs, (__bridge NSString *)kMDItemLanguages, getLanguage(snapshotter.fmt_ctx->metadata));
            } else if (!strcasecmp(tag->key, "performers")) {
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemPerformers, [@(tag->value) componentsSeparatedByString:@", "]);
            } else if (!strcasecmp(tag->key, "publisher")) {
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemPublishers, [@(tag->value) componentsSeparatedByString:@", "]);
            } else if (!strcasecmp(tag->key, "service_name")) { // e.g. TV channel
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemPublishers, [@(tag->value) componentsSeparatedByString:@", "]);
            } else if (!strcasecmp(tag->key, "service_provider")) { // e.g. TV station
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemPublishers, [@(tag->value) componentsSeparatedByString:@", "]);
            } else if (!strcasecmp(tag->key, "sort_album")) { // seen in Apple Music
                attrs[(__bridge NSString *)kMDItemAlbum] = @(tag->value);
            } else if (!strcasecmp(tag->key, "sort_artist")) { // seen in Apple Music
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemPerformers, [@(tag->value) componentsSeparatedByString:@", "]);
            } else if (!strcasecmp(tag->key, "sort_name")) { // seen in Apple Music
                attrs[(__bridge NSString *)kMDItemTitle] = @(tag->value);
            } else if (!strcasecmp(tag->key, "synopsis")) {
                attrs[(__bridge NSString *)kMDItemDescription] = @(tag->value);
            } else if (!strcasecmp(tag->key, "title")) {
                attrs[(__bridge NSString *)kMDItemTitle] = @(tag->value);
            } else if (!strcasecmp(tag->key, "track")) {
                char *sep = strchr(tag->value, '/');
                if (!sep)
                    attrs[(__bridge NSString *)kMDItemAudioTrackNumber] = @(tag->value);
                else
                    attrs[(__bridge NSString *)kMDItemAudioTrackNumber] = [@(tag->value) substringToIndex: sep - tag->value];
            } else if (!strcasecmp(tag->key, "wm/encodingsettings")) {
                addArrayAttributes(attrs, (__bridge NSString *)kMDItemEncodingApplications, [@(tag->value) componentsSeparatedByString:@" + "]); // " + " is common in Matroska
            } else if (!strcasecmp(tag->key, "wm/mediaoriginalbroadcastdatetime")) {
                attrs[(__bridge NSString *)kMDItemRecordingDate] = dateString(@(tag->value));
            } else {
                os_log_info(logger, "Skipping unknown tag %{public}s=%{public}s in %{public}@", tag->key, tag->value, pathToFile);
            }
        }

        // Audio
        if (snapshotter.audio_stream_idx >= 0) {
            AVStream *stream = snapshotter.fmt_ctx->streams[snapshotter.audio_stream_idx];
            AVCodecParameters *params = stream->codecpar;

            if (params->bit_rate > 0) {
                attrs[(__bridge NSString *)kMDItemAudioBitRate] = [NSNumber numberWithLong:params->bit_rate];
            }
            if (params->sample_rate > 0) {
                attrs[(__bridge NSString *)kMDItemAudioSampleRate] = [NSNumber numberWithLong:params->sample_rate];
            }
            switch (params->ch_layout.nb_channels) {
                case 6:
                    attrs[(__bridge NSString *)kMDItemAudioChannelCount] = @5.1f; break;
                case 7:
                    attrs[(__bridge NSString *)kMDItemAudioChannelCount] = @6.1f; break;
                case 8:
                    attrs[(__bridge NSString *)kMDItemAudioChannelCount] = @7.1f; break;
                default:
                    if (params->ch_layout.nb_channels > 0)
                        // Can't tell Quadraphonic from LCRS
                        attrs[(__bridge NSString *)kMDItemAudioChannelCount] = @(params->ch_layout.nb_channels);
            }
            addArrayAttribute(attrs, (__bridge NSString *)kMDItemLanguages, getLanguage(stream->metadata));
        }

        // Video
        if (snapshotter.video_stream_idx >= 0) {
            AVStream *stream = snapshotter.fmt_ctx->streams[snapshotter.video_stream_idx];
            AVCodecParameters *params = stream->codecpar;

            if (params->bit_rate > 0) {
                attrs[(__bridge NSString *)kMDItemVideoBitRate] = [NSNumber numberWithLong:params->bit_rate];
            }
            if (params->height > 0 ) {
                attrs[(__bridge NSString *)kMDItemPixelHeight] = [NSNumber numberWithLong:params->height];
                AVRational sar = av_guess_sample_aspect_ratio(snapshotter.fmt_ctx, stream, NULL);
                if (sar.num && sar.den)
                    attrs[(__bridge NSString *)kMDItemPixelWidth] = [NSNumber numberWithLong:av_rescale(params->width, sar.num, sar.den)];
                else
                    attrs[(__bridge NSString *)kMDItemPixelWidth] = [NSNumber numberWithLong:params->width];
            }
            if (stream->avg_frame_rate.den && stream->avg_frame_rate.num) {
                attrs[kFrameRate] = [NSNumber numberWithFloat:round((stream->avg_frame_rate.num * 100) / (double) stream->avg_frame_rate.den) / 100.f];
            } else if (stream->r_frame_rate.den && stream->r_frame_rate.num) {
                attrs[kFrameRate] = [NSNumber numberWithFloat:round((stream->r_frame_rate.num * 100) / (double) stream->r_frame_rate.den) / 100.f];
            }
        }

        // From each stream
        for (int stream_idx=0; stream_idx < snapshotter.fmt_ctx->nb_streams; stream_idx++)
        {
            AVStream *stream = snapshotter.fmt_ctx->streams[stream_idx];
            AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
            AVCodecParameters *params = stream->codecpar;

            switch (params->codec_type) {
                case AVMEDIA_TYPE_AUDIO:
                    if (stream_idx != snapshotter.audio_stream_idx) {
                        addArrayAttribute(attrs, (__bridge NSString *)kMDItemLanguages, getLanguage(stream->metadata));
                    }
                    addArrayAttributeNoDupes(attrs, (__bridge NSString *)kMDItemMediaTypes, @"Sound");
                    break;

                case AVMEDIA_TYPE_VIDEO:
                    if (stream->disposition & (AV_DISPOSITION_ATTACHED_PIC|AV_DISPOSITION_TIMED_THUMBNAILS)) {
                        continue; // Don't count cover art and don't list the codec
                    }
                    addArrayAttributeNoDupes(attrs, (__bridge NSString *)kMDItemMediaTypes, @"Video");
                    break;

                case AVMEDIA_TYPE_SUBTITLE:
                    if ((stream->disposition & AV_DISPOSITION_FORCED) || (title && [[@(title->value) lowercaseString] rangeOfString:@"forced"].location != NSNotFound)) {
                        continue; // Don't count forced subtitiles since they're effectively part of the video
                    }
                    addArrayAttribute(attrs, kSubtitles, getLanguage(stream->metadata));
                    addArrayAttributeNoDupes(attrs, (__bridge NSString *)kMDItemMediaTypes, @"Text");
                    break;

                default:
                    os_log_info(logger, "Skipping unknown stream #%d:%{public}s in %{public}@", stream_idx, title ? title->value : "", pathToFile);
            }

            // All recognised types
            const char *name = NULL;
            const AVCodec *codec = avcodec_find_decoder(params->codec_id);
            if (codec)
            {
                // Some of AVCodec.long_name can be too wordy (see libavcodec/codec_desc.c) but .name too cryptic,
                // so special-case some common codecs to give more compact & Applesque names
                switch (codec->id)
                {
                    case AV_CODEC_ID_H263:
                        name = "H.263"; break;
                    case AV_CODEC_ID_H263P:
                        name = "H.263+"; break;
                    case AV_CODEC_ID_H264:
                        name = "H.264"; break;
                    case AV_CODEC_ID_HEVC:
                        name = "H.265"; break;
                    case AV_CODEC_ID_MJPEG:
                        name = "Motion JPEG"; break;
                    case AV_CODEC_ID_FLV1:
                        name = "Sorenson Spark"; break;
                    case AV_CODEC_ID_SVQ1:
                        name = "Sorenson Video"; break;
                    case AV_CODEC_ID_SVQ3:
                        name = "Sorenson Video 3"; break;
                    case AV_CODEC_ID_AAC:
                        name = "AAC"; break;
                    case AV_CODEC_ID_AC3:
                        name = "Dolby Digital"; break;
                    case AV_CODEC_ID_EAC3:
                        name = "Dolby Digital Plus"; break;
                    case AV_CODEC_ID_DTS:
                        name = "DTS"; break;
                    case AV_CODEC_ID_FLAC:
                        name = "FLAC"; break;
                    case AV_CODEC_ID_MP2:
                        name = "MPEG Layer 2"; break;
                    case AV_CODEC_ID_MP3:
                        name = "MPEG Layer 3"; break;
                    case AV_CODEC_ID_PJS:
                        name = "PJS subtitle"; break;
                    case AV_CODEC_ID_ASS:
                        name = "Advanced SubStation Alpha"; break;
                    case AV_CODEC_ID_SSA:
                        name = "SubStation Alpha"; break;
                    case AV_CODEC_ID_HDMV_PGS_SUBTITLE:
                        name = "PGS subtitle"; break;
                    case AV_CODEC_ID_SRT:
                        name = "SubRip subtitle"; break;
                    default:
                        name = codec->long_name ? codec->long_name : codec->name;
                }
            }
            else if (params->codec_tag == MKTAG('C','R','A','W'))
                name = "C-RAW";

            if (name) {
                const char *profile = av_get_profile_name(codec, params->profile);
                addArrayAttributeNoDupes(attrs, (__bridge NSString *)kMDItemCodecs, profile ? [NSString stringWithFormat:@"%s [%s]", name, profile] : @(name));
            } else {
                os_log_info(logger, "Unsupported codec with id %d for stream #%d:%{public}s in %{public}@", params->codec_id, stream_idx, title ? title->value : "", pathToFile);
            }
        } // From each stream
    }

    return true;    // Return the status
}


