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
NSString *kMDItemVideoFrameRate = @"kMDItemVideoFrameRate";


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
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemDescription];
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
            else if (!strcasecmp(tag->key, "language"))
                [attrs setValue:[NSString stringWithUTF8String:tag->value] forKey:(__bridge NSString *)kMDItemLanguages];
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
            AVCodec *codec;

            if (dec_ctx->codec_type == AVMEDIA_TYPE_AUDIO)
            {
                // Assume that lower-numbered streams are primary (e.g. main track rather than commentary) so don't overwrite their values
                if (dec_ctx->bit_rate > 0    && ![attrs objectForKey:(__bridge NSString *)kMDItemAudioBitRate])
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->bit_rate] forKey:(__bridge NSString *)kMDItemAudioBitRate];
                if (dec_ctx->channels > 0    && ![attrs objectForKey:(__bridge NSString *)kMDItemAudioChannelCount])
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->channels] forKey:(__bridge NSString *)kMDItemAudioChannelCount];
                if (dec_ctx->sample_rate > 0 && ![attrs objectForKey:(__bridge NSString *)kMDItemAudioSampleRate])
                    [attrs setValue:[NSNumber numberWithInt:dec_ctx->sample_rate] forKey:(__bridge NSString *)kMDItemAudioSampleRate];
                AVDictionaryEntry *lang = av_dict_get(stream->metadata, "language", NULL, 0);
                if (lang && strcasecmp(lang->value, "und"))
                    [languages addObject:[NSString stringWithUTF8String:lang->value]];
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
                if (![attrs objectForKey:kMDItemVideoFrameRate])
                {
                    if (stream->avg_frame_rate.den && stream->avg_frame_rate.num)
                        [attrs setValue:[NSNumber numberWithDouble:round((stream->avg_frame_rate.num * 100) / (double) stream->avg_frame_rate.den) / 100.]
                                 forKey:kMDItemVideoFrameRate];
                    else if (stream->r_frame_rate.den && stream->r_frame_rate.num)
                        [attrs setValue:[NSNumber numberWithDouble:round((stream->r_frame_rate.num   * 100) / (double) stream->r_frame_rate.den)   / 100.]
                                 forKey:kMDItemVideoFrameRate];
                }
                [mediatypes addObject:@"Video"];
            }
            else if (dec_ctx->codec_type == AVMEDIA_TYPE_SUBTITLE)
            {
                [mediatypes addObject:@"Text"];
            }
            else
            {
                continue;   // Unhandled type of stream
            }

            // All recognised types
            if ((codec = avcodec_find_decoder(dec_ctx->codec_id)))
            {
                NSString *name = [NSString stringWithUTF8String:(codec->long_name ? codec->long_name : codec->name)];
                if (![codecs containsObject:name])
                      [codecs addObject:name];
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

        if ([languages count])
            [attrs setValue:languages forKey:(__bridge NSString *)kMDItemLanguages];

        avformat_close_input(&fmt_ctx);
    }

    return true;    // Return the status
}


