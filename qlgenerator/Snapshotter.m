//
//  Snapshotter.m
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#include "Snapshotter.h"

#include <libswscale/swscale.h>


static const int kMaxKeyframeTime = 4;  // How far to look for a keyframe [s]

@implementation Snapshotter

- (instancetype) initWithURL:(CFURLRef)url;
{
    if (!(self = [super init]))
        return nil;

    CFIndex filenamesize = CFStringGetMaximumSizeOfFileSystemRepresentation(CFURLGetString(url));
    char *filename = malloc(filenamesize);
    if (!filename)
        return nil;

    if (!CFURLGetFileSystemRepresentation(url, true, (UInt8*)filename, filenamesize) ||
        avformat_open_input(&fmt_ctx, filename, NULL, NULL))
    {
        free(filename);
        return nil;
    }
    free(filename);

    if (avformat_find_stream_info(fmt_ctx, NULL))
        return nil;

    // Find best audio stream and record channel count
    int audio_stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (audio_stream_idx >= 0)
        _channels = fmt_ctx->streams[audio_stream_idx]->codec->channels;

    AVDictionaryEntry *tag = av_dict_get(fmt_ctx->metadata, "title", NULL, 0);
    if (tag && tag->value)
        _title = @(tag->value);

    // Find best video stream and open appropriate codec
    AVCodec *codec = NULL;
    stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (stream_idx >= 0)
    {
        stream = fmt_ctx->streams[stream_idx];
        dec_ctx = stream->codec;
        avcodec_open2(dec_ctx, codec, NULL);
    }

    // If we can't decode the video stream, might still be able to read metadata and cover art.
    return self;
}

- (void) dealloc
{
    avcodec_close(dec_ctx);
    avformat_close_input(&fmt_ctx);
}

// Native frame size, adjusting for anamorphic
- (CGSize) displaySize
{
    AVRational sar = av_guess_sample_aspect_ratio(fmt_ctx, stream, NULL);
    if (sar.num > 1 && sar.den > 1)
        return CGSizeMake(av_rescale(dec_ctx->width, sar.num, sar.den), dec_ctx->height);
    else
        return CGSizeMake(dec_ctx->width, dec_ctx->height);
}

// Duration [s]
- (NSInteger) duration
{
    return fmt_ctx->duration > 0 ? (fmt_ctx->duration / AV_TIME_BASE) : 0; // We're not interested in sub-second accuracy
}

// Gets cover art if available, or nil.
- (CGImageRef) newCoverArtWithMode:(CoverArtMode)mode;
{
    // Cover art can appear as an extra video stream (e.g. mp4, wtv) or as attachment(s) (e.g. mkv).
    // (Note this isn't necessarily how they're encoded in the file, but how the FFmpeg codecs present them).

    AVStream *art_stream = NULL;
    int art_priority = 0;

    for (int idx=0; idx < fmt_ctx->nb_streams; idx++)
    {
        AVStream *s = fmt_ctx->streams[idx];
        AVCodecContext *ctx = s->codec;
        if (ctx && (ctx->codec_id == AV_CODEC_ID_PNG || ctx->codec_id == AV_CODEC_ID_MJPEG))
        {
            if (ctx->codec_type == AVMEDIA_TYPE_VIDEO && (s->disposition & AV_DISPOSITION_ATTACHED_PIC))
            {
                if (mode != CoverArtLandscape)  // Assume that unnamed cover art is *not* landscape, so don't return it
                    art_stream = s;

                break;      // prefer first if multiple
            }
            else if (ctx->codec_type == AVMEDIA_TYPE_ATTACHMENT)
            {
                // MKVs can contain multiple cover art - see http://matroska.org/technical/cover_art/index.html
                int priority;
                AVDictionaryEntry *filename = av_dict_get(s->metadata, "filename", NULL, 0);

                switch (mode)
                {
                case CoverArtThumbnail:     // Prefer small square/portrait.
                    if (!filename || !filename->value)
                        priority = 1;
                    else if (!strncasecmp(filename->value, "cover.", 6))
                        priority = 2;
                    else if (!strncasecmp(filename->value, "small_cover.", 12))
                        priority = 3;
                    else
                        priority = 1;
                    break;

                case CoverArtLandscape:    // Only return large landscape.
                    if (filename && filename->value && !strncasecmp(filename->value, "cover_land.", 11))
                        priority = 3;
                    else
                        priority = 0;
                    break;

                default:    // CoverArtDefault  Prefer large square/portrait.
                    if (!filename || !filename->value)
                        priority = 1;
                    else if (!strncasecmp(filename->value, "small_cover.", 12))
                        priority = 2;
                    else if (!strncasecmp(filename->value, "cover.", 6))
                        priority = 3;
                    else
                        priority = 1;
                }

                if (art_priority < priority)    // Prefer first if multiple with same priority
                {
                    art_priority = priority;
                    art_stream = s;
                }
            }
        }
    }

    // Extract data
    CFDataRef data;
    if (!art_stream)
        return nil;
    else if (art_stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
        data = CFDataCreateWithBytesNoCopy(NULL, art_stream->attached_pic.data, art_stream->attached_pic.size, kCFAllocatorNull);   // we'll dealloc when fmt_ctx is closed
    else
        data = CFDataCreateWithBytesNoCopy(NULL, art_stream->codec->extradata, art_stream->codec->extradata_size, kCFAllocatorNull);   // we'll dealloc when fmt_ctx is closed

    // wangle into a CGImage
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGImageRef image = (art_stream->codec->codec_id == AV_CODEC_ID_PNG) ?
        CGImageCreateWithPNGDataProvider (provider, NULL, false, kCGRenderingIntentDefault) :
        CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}


// gets snapshot and blocks until completion, timeout or failure.
- (CGImageRef) newSnapshotWithSize:(CGSize)size atTime:(NSInteger)seconds;
{
    if (!dec_ctx || !avcodec_is_open(dec_ctx))
        return nil;     // Can't decode video stream

    // offset for our screenshot
    int64_t timestamp = (stream->start_time <= 0) ? 0 : stream->start_time;
    if (seconds)
    {
        timestamp += av_rescale(seconds, stream->time_base.den, stream->time_base.num);
        if (av_seek_frame(fmt_ctx, stream_idx, timestamp, 0) < 0)
            return nil;
    }
    else
    {
        av_seek_frame(fmt_ctx, stream_idx, 0, AVSEEK_FLAG_BYTE);    // rewind
    }
    int64_t stoptime = timestamp + av_rescale(kMaxKeyframeTime, stream->time_base.den, stream->time_base.num);

    AVPacket pkt;
    av_init_packet(&pkt);
    pkt.data = NULL;   // let the demuxer allocate
    pkt.size = 0;

    AVFrame *frame;     // holds the raw frame data
    if (!(frame = av_frame_alloc()))
        return nil;

    int linesize = ((3 * (int) size.width + 15) / 16) * 16; // align for efficient swscale
    uint8_t *picture = NULL;   // points to the RGB data
    struct SwsContext *sws_ctx;

    int got_frame = 0;
    avcodec_flush_buffers(dec_ctx);    // Discard any buffered packets left over from previous call
    while (av_read_frame(fmt_ctx, &pkt) >= 0 && !got_frame)
    {
        if (pkt.stream_index == stream_idx)
            avcodec_decode_video2(dec_ctx, frame, &got_frame, &pkt);
        av_packet_unref(&pkt);

        // MPEG TS demuxer doesn't necessarily seek to keyframes. So keep looking for one.
        if (got_frame && !frame->key_frame && frame->pkt_pts != AV_NOPTS_VALUE && frame->pkt_pts < stoptime)
        {
            got_frame = 0;
            av_frame_unref(frame);
            continue;
        }
    }
    if (!got_frame ||
        !(picture = malloc(linesize * (int) size.height)) ||
        !(sws_ctx = sws_getContext(dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
                                   size.width, size.height, AV_PIX_FMT_RGB24,
                                   SWS_BICUBIC, NULL, NULL, NULL)))
    {
        free(picture);
        av_frame_free(&frame);
        return nil;     // Failed to find a single frame!
    }

    // convert raw frame data, and rescale if necessary
    uint8_t *const dst[4] = { picture };
    const int dstStride[4] = { linesize };
    sws_scale(sws_ctx, (const uint8_t *const *) frame->data, frame->linesize, 0, dec_ctx->height, dst, dstStride);
    sws_freeContext(sws_ctx);
    av_frame_free(&frame);

    // wangle into a CGImage
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, picture, linesize * (int) size.height, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(size.width, size.height, 8, 24, linesize,
                                     rgb, kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(rgb);
    CGDataProviderRelease(provider);
    CFRelease(data);    // frees the RGB data in "picture" too
    return image;
}
@end
