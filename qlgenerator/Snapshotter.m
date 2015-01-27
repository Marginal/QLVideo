//
//  Snapshotter.m
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#include "Snapshotter.h"

#include <libswscale/swscale.h>


static const int kPositionSeconds = 60; // Completely arbitrary. CoreMedia generator appears to use 10s

@implementation Snapshotter

- (id)initWithURL:(CFURLRef)url;
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
    {
        avformat_close_input(&fmt_ctx);
        return nil;
    }

    // Find first audio stream and record channel count
    for (stream_idx=0; stream_idx < fmt_ctx->nb_streams; stream_idx++)
    {
        AVCodecContext *audio_ctx = fmt_ctx->streams[stream_idx]->codec;
        if (audio_ctx && audio_ctx->codec_type == AVMEDIA_TYPE_AUDIO)
        {
            _channels = audio_ctx->channels;
            break;
        }
    }

    AVDictionaryEntry *tag = av_dict_get(fmt_ctx->metadata, "title", NULL, 0);
    if (tag && tag->value)
        _title = @(tag->value);

    // Find first video stream and open appropriate codec
    AVCodec *codec = NULL;
    for (stream_idx=0; stream_idx < fmt_ctx->nb_streams; stream_idx++)
    {
        stream = fmt_ctx->streams[stream_idx];
        dec_ctx = stream->codec;
        if (dec_ctx && dec_ctx->codec_type == AVMEDIA_TYPE_VIDEO)
        {
            if (dec_ctx->height > 0)
                codec = avcodec_find_decoder(dec_ctx->codec_id);
            break;
        }
    }
    if (!codec || avcodec_open2(dec_ctx, codec, NULL))
    {
        avformat_close_input(&fmt_ctx);
        return nil;
    }

    // allocate frame container
    if (!(frame = av_frame_alloc()))
    {
        avcodec_close(dec_ctx);
        avformat_close_input(&fmt_ctx);
        return nil;
    }

    return self;
}

- (void) dealloc
{
    avpicture_free(&picture);
    av_frame_free(&frame);
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


// Gets cover art if available, or nil.
// size parameter is currently ignored - let QuickLook do any rescaling.
- (CGImageRef) CreateCoverArtWithSize:(CGSize)size;
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
                art_stream = s;
                break;      // prefer first if multiple
            }
            else if (ctx->codec_type == AVMEDIA_TYPE_ATTACHMENT)
            {
                // MKVs can contain multiple cover art - see http://matroska.org/technical/cover_art/index.html
                // We prefer small ('cos thumbnail) square/portrait.
                int priority;
                AVDictionaryEntry *filename = av_dict_get(s->metadata, "filename", NULL, 0);
                if (!filename || !filename->value)
                    priority = 1;
                else if (!strncasecmp(filename->value, "cover.", 6))
                    priority = 2;
                else if (!strncasecmp(filename->value, "small_cover.", 12))
                    priority = 3;
                else
                    priority = 1;
                if (art_priority < priority)
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
        data = CFDataCreateWithBytesNoCopy(NULL, art_stream->attached_pic.data, art_stream->attached_pic.size, kCFAllocatorNull);   // we'll dealloc
    else
        data = CFDataCreateWithBytesNoCopy(NULL, art_stream->codec->extradata, art_stream->codec->extradata_size, kCFAllocatorNull);   // we'll dealloc

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
// the data buffer backing the snapshot is only good 'til the next snapshot or until the object is destroyed, so not thread-safe
- (CGImageRef) CreateSnapshotWithSize:(CGSize)size;
{
    // offset for our screenshot
    if (fmt_ctx->duration > 2 * AV_TIME_BASE)   // just use first frame if duration unknown or less than 2 seconds
    {
        int64_t timestamp = (fmt_ctx->duration > kPositionSeconds * 2 * AV_TIME_BASE ?
                             av_rescale(kPositionSeconds,  stream->time_base.den, stream->time_base.num) :
                             av_rescale(fmt_ctx->duration, stream->time_base.den, 2 * AV_TIME_BASE * stream->time_base.num));   // or half way for short clips
        if (stream->start_time > 0)
            timestamp += stream->start_time;
        if (av_seek_frame(fmt_ctx, stream_idx, timestamp, AVSEEK_FLAG_BACKWARD) < 0)
            av_seek_frame(fmt_ctx, stream_idx, 0, AVSEEK_FLAG_BYTE);    // failed - try to rewind
    }

    AVPacket pkt;
    av_init_packet(&pkt);
    pkt.data = NULL;   // let the demuxer allocate
    pkt.size = 0;
    int got_frame = 0;

    while (av_read_frame(fmt_ctx, &pkt) >= 0)
    {
        if (pkt.stream_index == stream_idx)
            avcodec_decode_video2(dec_ctx, frame, &got_frame, &pkt);
        av_free_packet(&pkt);
        if (got_frame)
            break;
    }
    if (!got_frame) return nil;     // Failed to find a single frame!

    // allocate backing store for snapshot
    avpicture_free(&picture);   // not necessary if we're only called once, but harmless
    if (avpicture_alloc(&picture, AV_PIX_FMT_RGB24, size.width, size.height)) return nil;

    // convert raw frame data, and rescale if necessary
    struct SwsContext *sws_ctx = sws_getContext(dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
                                                size.width, size.height, AV_PIX_FMT_RGB24,
                                                SWS_BICUBIC, NULL, NULL, NULL);
    if (!sws_ctx) return nil;
    sws_scale(sws_ctx, (const uint8_t *const *) frame->data, frame->linesize, 0, dec_ctx->height, picture.data, picture.linesize);
    sws_freeContext(sws_ctx);

    // wangle into a CGImage
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, picture.data[0], size.width * size.height * 3, kCFAllocatorNull);   // we'll dealloc
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(size.width, size.height, 8, 24, size.width * 3,
                                     rgb, kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(rgb);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}
@end
