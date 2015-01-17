//
//  GetMetadataForFile.m
//  Video
//
//  Created by Jonathan Harris on 03/07/2014.
//
//

#import <Cocoa/Cocoa.h>

#include <libavformat/avformat.h>
#include <libavutil/dict.h>


// Custom attributes
NSString *kFrameRate = @"uk_org_marginal_qlvideo_framerate";
NSString *kSubtitles = @"uk_org_marginal_qlvideo_subtitles";


Boolean die(CFStringRef pathToFile, int err)
{
#ifdef DEBUG
    char errbuf[AV_ERROR_MAX_STRING_SIZE];
    const char *errbuf_ptr = errbuf;

    if (av_strerror(err, errbuf, sizeof(errbuf)) < 0)
        errbuf_ptr = strerror(AVUNERROR(err));
    NSLog(@"Video.mdimporter %@: %s", pathToFile, errbuf_ptr);
#endif
    return false;
}


// Return localised language name from ISO639-2 tag in metadata, or nil.
// https://developer.apple.com/library/mac/documentation/MacOSX/Conceptual/BPInternational/LanguageandLocaleIDs/LanguageandLocaleIDs.html
NSString *GetLanguage(AVDictionary *metadata)
{
    @autoreleasepool
    {
        AVDictionaryEntry *tag = av_dict_get(metadata, "language", NULL, 0);
        if (!tag || !strcmp(tag->value, "unk") || !strcmp(tag->value, "und"))
            return nil;

        NSString *display = NULL;
        NSString *lang = [NSString stringWithUTF8String:tag->value];
        if (!strcmp(tag->value, "chi"))
        {
            // ISO639-2 can't differentiate between traditional and simplified chinese script, so look at track title
            // http://www.loc.gov/standards/iso639-2/faq.html#23
            // http://www.w3.org/International/articles/bcp47/#macro
            AVDictionaryEntry *title_entry = av_dict_get(metadata, "title", NULL, 0);
            if (title_entry)
            {
                NSString *title = [NSString stringWithUTF8String:title_entry->value];
                if ([title rangeOfString:@"simplified" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [title rangeOfString:@"简体"].location != NSNotFound)
                    display = @"简体中文";
                else if ([title rangeOfString:@"traditional" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                         [title rangeOfString:@"繁體"].location != NSNotFound)
                    display = @"繁體中文";
            }
        }
        else if (!strcmp(tag->value, "spa"))
        {
            // ISO639-2 can't differentiate between Spanish as spoken in Spain and in Latin America
            AVDictionaryEntry *title_entry = av_dict_get(metadata, "title", NULL, 0);
            if (title_entry)
            {
                NSString *title = [NSString stringWithUTF8String:title_entry->value];
                if (!strcmp(title_entry->value, "eur") || !strcmp(title_entry->value, "spa") ||
                    [title rangeOfString:@"españa" options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound)
                    lang = @"es-ES";
                else if (!strcmp(title_entry->value, "lat") ||
                        [title rangeOfString:@"latino" options:NSCaseInsensitiveSearch].location != NSNotFound)
                    lang = @"es-419";
            }
        }
        else if (!strcmp(tag->value, "por"))
        {
            // ISO639-2 can't differentiate between Portuguese as spoken in Portugal and in Brazil
            AVDictionaryEntry *title_entry = av_dict_get(metadata, "title", NULL, 0);
            if (title_entry)
            {
                NSString *title = [NSString stringWithUTF8String:title_entry->value];
                if (!strcmp(title_entry->value, "eur") || !strcmp(title_entry->value, "por") ||
                    [title rangeOfString:@"portugal" options:NSCaseInsensitiveSearch].location != NSNotFound)
                    lang = @"pt-PT";
                else if (!strcmp(title_entry->value, "lat") || !strcmp(title_entry->value, "bra") ||
                         [title rangeOfString:@"brasil" options:NSCaseInsensitiveSearch].location != NSNotFound)
                    lang = @"pt-BR";
            }
        }

        if (!display)
        {
            // We don't get access to the user's preferred language (and we don't have an opportunity to update the
            // Spotlight metadata if it changes) so return each language in its language if possible.
            NSLocale *locale = [NSLocale localeWithLocaleIdentifier:lang];
            display = [locale displayNameForKey:NSLocaleIdentifier value:[locale localeIdentifier]];    // can be nil

            if (display)
                display = [display capitalizedString];  // for consistency
            else
                display = lang; // just return the ISO639-2 code
        }

        return display;
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
        NSMutableData *filename = [NSMutableData dataWithLength:CFStringGetMaximumSizeOfFileSystemRepresentation(pathToFile)];
        if (!filename || !CFStringGetFileSystemRepresentation(pathToFile, [filename mutableBytes], [filename length]))
            return false;

        AVFormatContext *fmt_ctx = NULL;
        int err;
        if ((err = avformat_open_input(&fmt_ctx, [filename mutableBytes], NULL, NULL)))
            return die(pathToFile, err);

        if ((err = avformat_find_stream_info(fmt_ctx, NULL)))
        {
            avformat_close_input(&fmt_ctx);
            return die(pathToFile, err);
        }

        NSMutableDictionary *attrs = (__bridge NSMutableDictionary *) attributes;   // Prefer to use Objective-C
        
        // Stuff we collect along the way
        NSMutableArray *codecs =     [[NSMutableArray alloc] init];
        NSMutableArray *mediatypes = [[NSMutableArray alloc] init];
        NSMutableArray *languages =  [[NSMutableArray alloc] init];
        NSMutableArray *subtitles =  [[NSMutableArray alloc] init];

        // From the container
        if (fmt_ctx->bit_rate > 0)
            [attrs setValue:[NSNumber numberWithInt:fmt_ctx->bit_rate] forKey:(__bridge NSString *)kMDItemTotalBitRate];
        if (fmt_ctx->duration > 0)
            [attrs setValue:[NSNumber numberWithFloat:(float)((double)fmt_ctx->duration/AV_TIME_BASE)]    // downcast to float to avoid spurious accuracy
                     forKey:(__bridge NSString *)kMDItemDurationSeconds];
        
        // metadata tags - see avformat.h and https://developer.apple.com/library/mac/documentation/Carbon/reference/MDItemRef/
        // we let Spotlight convert from string to date or time as necessary
        AVDictionaryEntry *tag = NULL;
        while ((tag = av_dict_get(fmt_ctx->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
        {
            if (!strlen(tag->value)) continue;	// shouldn't happen

            if (!strcasecmp(tag->key, "album"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemAlbum];
            else if (!strcasecmp(tag->key, "artist"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemAuthors];
            else if (!strcasecmp(tag->key, "comment"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemComment];
            else if (!strcasecmp(tag->key, "composer"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemComposer];
            else if (!strcasecmp(tag->key, "copyright"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemCopyright];
            else if (!strcasecmp(tag->key, "creation_time"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemContentCreationDate];
            else if (!strcasecmp(tag->key, "date"))
            {
                NSString *date = [NSString stringWithUTF8String:tag->value];
                char *sep = strchr(tag->value, '-');
                [attrs setValue:date forKey:(__bridge NSString *) (sep ? kMDItemRecordingDate : kMDItemRecordingYear)];
                if (sep)
                    [attrs setValue:[date substringToIndex: sep - tag->value] forKey:(__bridge NSString *) kMDItemRecordingYear];
            }
            else if (!strcasecmp(tag->key, "encoder"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemEncodingApplications];
            else if (!strcasecmp(tag->key, "filename"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:@"kMDItemAlternateNames"];
            else if (!strcasecmp(tag->key, "genre"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemGenre];
            else if (!strcasecmp(tag->key, "performers"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemPerformers];
            else if (!strcasecmp(tag->key, "publisher"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemPublishers];
            else if (!strcasecmp(tag->key, "service_name") || !strcasecmp(tag->key, "service_provider"))
            {
                if (![attrs objectForKey:(__bridge NSString *)kMDItemPublishers])
                    [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemPublishers];
            }
            else if (!strcasecmp(tag->key, "title"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemTitle];
            else if (!strcasecmp(tag->key, "track"))
            {
                char *sep = strchr(tag->value, '/');
                if (!sep)
                    [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemAudioTrackNumber];
                else
                    [attrs setValue:[[NSString stringWithUTF8String:tag->value] substringToIndex: sep - tag->value]
                             forKey:(__bridge NSString *)kMDItemAudioTrackNumber];
            }
#if LOG_UNUSED_META
            else if (strcasecmp(tag->key, "album_artist") &&        // no suitable MDItem
                     strcasecmp(tag->key, "disc") &&                // no suitable MDItem
                     strcasecmp(tag->key, "encoded_by") &&          // no suitable MDItem
                     strcasecmp(tag->key, "variant_bitrate") &&     // no suitable MDItem
                     !strchr(tag->key, '/'))    // ignore format-specific keys like WM/MediaOriginalChannel
                NSLog(@"Video.mdimporter %@: skipped tag %s=%s", pathToFile, tag->key, tag->value);
#endif
        }

        // From each stream
        for (int stream_idx=0; stream_idx < fmt_ctx->nb_streams; stream_idx++)
        {
            AVStream *stream = fmt_ctx->streams[stream_idx];
            AVCodecContext *dec_ctx = stream->codec;

            if (dec_ctx->codec_type == AVMEDIA_TYPE_AUDIO)
            {
                // Assume that lower-numbered streams are primary (e.g. main track rather than commentary) so don't overwrite their values
                if (dec_ctx->bit_rate > 0    && ![attrs objectForKey:(__bridge NSString *)kMDItemAudioBitRate])
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->bit_rate] forKey:(__bridge NSString *)kMDItemAudioBitRate];
                if (dec_ctx->channels > 0    && ![attrs objectForKey:(__bridge NSString *)kMDItemAudioChannelCount])
                {
                    NSNumber *channels;
                    switch (dec_ctx->channels)
                    {
                        // See e.g. http://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/index.html#chapter=39
                        // Can't tell Quadraphonic from LCRS
                        case 6:
                            channels = [NSNumber numberWithFloat:5.1f]; break;
                        case 7:
                            channels = [NSNumber numberWithFloat:6.1f]; break;
                        case 8:
                            channels = [NSNumber numberWithFloat:7.1f]; break;
                        default:
                            channels = [NSNumber numberWithInt:dec_ctx->channels];
                    }
                    [attrs setValue:channels forKey:(__bridge NSString *)kMDItemAudioChannelCount];
                }
                if (dec_ctx->sample_rate > 0 && ![attrs objectForKey:(__bridge NSString *)kMDItemAudioSampleRate])
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->sample_rate] forKey:(__bridge NSString *)kMDItemAudioSampleRate];
                NSString *lang = GetLanguage(stream->metadata);
                if (lang)
                    [languages addObject:lang];
                [mediatypes addObject:@"Sound"];
            }
            else if (dec_ctx->codec_type == AVMEDIA_TYPE_VIDEO)
            {
                if (dec_ctx->bit_rate > 0 && ![attrs objectForKey:(__bridge NSString *)kMDItemVideoBitRate])
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->bit_rate] forKey:(__bridge NSString *)kMDItemVideoBitRate];
                if (dec_ctx->height > 0 && ![attrs objectForKey:(__bridge NSString *)kMDItemPixelHeight])
                {
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->height] forKey:(__bridge NSString *)kMDItemPixelHeight];
                    AVRational sar = av_guess_sample_aspect_ratio(fmt_ctx, stream, NULL);
                    if (sar.num && sar.den)
                        [attrs setValue:[NSNumber numberWithInt:(int)av_rescale(dec_ctx->width, sar.num, sar.den)]
                                 forKey:(__bridge NSString *)kMDItemPixelWidth];
                    else
                        [attrs setValue:[NSNumber numberWithInt:dec_ctx->width] forKey:(__bridge NSString *)kMDItemPixelWidth];
                }
                if (![attrs objectForKey:kFrameRate])
                {
                    if (stream->avg_frame_rate.den && stream->avg_frame_rate.num)
                        [attrs setValue:[NSNumber numberWithDouble:round((stream->avg_frame_rate.num * 100) / (double) stream->avg_frame_rate.den) / 100.]
                                 forKey:kFrameRate];
                    else if (stream->r_frame_rate.den && stream->r_frame_rate.num)
                        [attrs setValue:[NSNumber numberWithDouble:round((stream->r_frame_rate.num   * 100) / (double) stream->r_frame_rate.den)   / 100.]
                                 forKey:kFrameRate];
                }
                [mediatypes addObject:@"Video"];
            }
            else if (dec_ctx->codec_type == AVMEDIA_TYPE_SUBTITLE)
            {
                if (stream->disposition & AV_DISPOSITION_FORCED)
                    continue;   // Don't count forced subtitiles since they're effectively part of the video

                NSString *lang = GetLanguage(stream->metadata);
                if (lang)
                    [subtitles addObject:lang];
                [mediatypes addObject:@"Text"];
            }
            else
            {
                continue;   // Unhandled type of stream
            }

            // All recognised types
            AVCodec *codec = avcodec_find_decoder(dec_ctx->codec_id);
            if (codec)
            {
                // Some of AVCodec.long_name can be too wordy (but .name too cryptic), so special-case some common
                // codecs to give more compact & Applesque names
                const char *name;
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
                        name = "AC-3"; break;
                    case AV_CODEC_ID_DTS:
                        name = "DTS"; break;
                    case AV_CODEC_ID_FLAC:
                        name = "FLAC"; break;
                    case AV_CODEC_ID_MP2:
                        name = "MPEG Layer 2"; break;
                    case AV_CODEC_ID_MP3:
                        name = "MPEG Layer 3"; break;
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

                if (name)
                {
                    const char *profile = av_get_profile_name(codec, dec_ctx->profile);
                    NSString *nsname = profile ? [NSString stringWithFormat:@"%s [%s]", name, profile] : [NSString stringWithUTF8String:name];
                    if (![codecs containsObject:nsname])
                        [codecs addObject:nsname];
                }
            }
#ifdef DEBUG
            else
                NSLog(@"Video.mdimporter %@: unsupported codec with id %d for stream %d", pathToFile, dec_ctx->codec_id, stream_idx);
#endif
        }
        
        if ([codecs count])
            [attrs setValue:codecs forKey:(__bridge NSString *)kMDItemCodecs];

        if ([mediatypes count])
            [attrs setValue:mediatypes forKey:(__bridge NSString *)kMDItemMediaTypes];

        // If the streams don't contain any language info, look in the container
        if (![languages count])
        {
            NSString *lang = GetLanguage(fmt_ctx->metadata);
            if (lang)
                [languages addObject:lang];
        }
        if ([languages count])
            [attrs setValue:languages forKey:(__bridge NSString *)kMDItemLanguages];

        if ([subtitles count])
            [attrs setValue:subtitles forKey:kSubtitles];

        avformat_close_input(&fmt_ctx);
    }

    return true;    // Return the status
}


