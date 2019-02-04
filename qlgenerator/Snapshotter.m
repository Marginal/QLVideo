//
//  Snapshotter.m
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import "Snapshotter.h"

#include <libswscale/swscale.h>


static const int kMaxKeyframeTime = 4;  // How far to look for a keyframe [s]
static const int kMaxKeyframeBlankSkip = 2;  // How many keyframes to skip for being too black or too white

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
        AVStream *stream = fmt_ctx->streams[stream_idx];
        dec_ctx = stream->codec;
        avcodec_open2(dec_ctx, codec, NULL);
        _thumbnails = (stream->disposition == (AV_DISPOSITION_ATTACHED_PIC|AV_DISPOSITION_TIMED_THUMBNAILS) && ((int) stream->nb_frames > 0) ? (int) stream->nb_frames: 0);
    }

    // If we can't decode the video stream, might still be able to read metadata and cover art.
    return self;
}

- (void) dealloc
{
    avcodec_close(dec_ctx);
    avformat_close_input(&fmt_ctx);
    if (enc_ctx)
        avcodec_free_context(&enc_ctx); // also closes the codec
}

// Native frame size, adjusting for anamorphic
- (CGSize) displaySize
{
    if (stream_idx < 0)
        return CGSizeMake(0,0);

    AVRational sar = av_guess_sample_aspect_ratio(fmt_ctx, fmt_ctx->streams[stream_idx], NULL);
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
            if (ctx->codec_type == AVMEDIA_TYPE_VIDEO &&
                ((s->disposition & (AV_DISPOSITION_ATTACHED_PIC|AV_DISPOSITION_TIMED_THUMBNAILS)) == AV_DISPOSITION_ATTACHED_PIC))
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


// Private method. Gets snapshot as raw RGB, blocking until completion, timeout or failure.
- (int) newImageWithSize:(CGSize)size atTime:(NSInteger)seconds to:(uint8_t *const [])dst withStride:(const int [])dstStride
{
    if (stream_idx < 0)
        return -1;
    AVStream *stream = fmt_ctx->streams[stream_idx];

    if (!dec_ctx || !avcodec_is_open(dec_ctx))
        return -1;      // Can't decode video stream

    // offset for our screenshot
    int64_t timestamp = (stream->start_time == AV_NOPTS_VALUE) ? 0 : stream->start_time;
    int64_t stoptime;
    if (seconds > 0)
    {
        avcodec_flush_buffers(dec_ctx);    // Discard any buffered packets left over from previous call
        timestamp += av_rescale(seconds, stream->time_base.den, stream->time_base.num);
        stoptime = timestamp + av_rescale(kMaxKeyframeTime, stream->time_base.den, stream->time_base.num);
        if (av_seek_frame(fmt_ctx, stream_idx, timestamp, AVSEEK_FLAG_BACKWARD) < 0)    // AVSEEK_FLAG_BACKWARD is more reliable for MP4 container
            return -1;
    }
    else if (seconds == 0 && !(fmt_ctx->iformat->flags & AVFMT_NO_BYTE_SEEK))  // rewind
    {
        avcodec_flush_buffers(dec_ctx);    // Discard any buffered packets left over from previous call
        av_seek_frame(fmt_ctx, stream_idx, 0, AVSEEK_FLAG_BYTE);
        stoptime = av_rescale(kMaxKeyframeTime, stream->time_base.den, stream->time_base.num);
    }
    else    // Don't seek
    {
        stoptime = LLONG_MAX;
    }

    AVPacket pkt;
    av_init_packet(&pkt);
    pkt.data = NULL;   // let the demuxer allocate
    pkt.size = 0;

    AVFrame *frame;     // holds the raw frame data
    if (!(frame = av_frame_alloc()))
        return -1;

    int got_frame = 0;
    while (av_read_frame(fmt_ctx, &pkt) >= 0 && !got_frame)
    {
        if (pkt.stream_index == stream_idx)
        {
            avcodec_decode_video2(dec_ctx, frame, &got_frame, &pkt);

            if (got_frame && seconds > 0 &&
                (
                 // It's a small clip and we've ended up at a keyframe at start of it. Keep reading until desired time.
                 (seconds <= kMaxKeyframeTime && frame->pts < timestamp) ||
                 // MPEG TS demuxer doesn't necessarily seek to keyframes. So keep looking for one.
                 ((seconds > kMaxKeyframeTime && !frame->key_frame && frame->pts < stoptime))))
            {
                got_frame = 0;
                av_frame_unref(frame);
            }
        }
        av_packet_unref(&pkt);
    }
    if (!got_frame)
        return -1;     // Failed to find a single frame!

    // convert raw frame data, and rescale if necessary
    struct SwsContext *sws_ctx;
    if (!size.width || !size.height ||
        !(sws_ctx = sws_getContext(dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
                                   size.width, size.height, AV_PIX_FMT_RGB24,
                                   SWS_BICUBIC, NULL, NULL, NULL)))
    {
        av_frame_free(&frame);
        return -1;
    }
    sws_scale(sws_ctx, (const uint8_t *const *) frame->data, frame->linesize, 0, dec_ctx->height, dst, dstStride);
    sws_freeContext(sws_ctx);
    av_frame_free(&frame);

    return 0;
}

// Gets non-black snapshot and blocks until completion, timeout or failure.
- (CGImageRef) newSnapshotWithSize:(CGSize)size atTime:(NSInteger)seconds;
{
    uint8_t *picture = NULL;   // points to the RGB data
    int linesize = ((3 * (int) size.width + 15) / 16) * 16; // align for efficient swscale
    if (!(picture = malloc(linesize * (int) size.height)))
        return nil;

    uint8_t *const dst[4] = { picture };
    const int dstStride[4] = { linesize };
    for (int frame = 0; frame <= kMaxKeyframeBlankSkip; frame++)
    {
        if ([self newImageWithSize:size atTime:seconds to:dst withStride:dstStride])
        {
            free(picture);
            return nil;
        }

        // Check centre of 3x3 rectangle for not too dark or too light
        uint8_t *line = picture + linesize * ((int) size.height / 3) + (int) size.width;
        unsigned sum = 0;
        for (int y = 0; y < (int) size.height / 3; y++)
        {
            for (int x = 0; x < (int) size.width; x++)
                sum += line[x];
            line += linesize;
        }
        unsigned avg = sum / ((int) size.width * ((int) size.height / 3));
        if  (avg < 16 || avg > 240)   // arbitrary thresholds
            seconds = -1;   // next keyframe
        else
            break;
    }

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

// Gets snapshot and blocks until completion, timeout or failure.
- (CFDataRef) newPNGWithSize:(CGSize)size atTime:(NSInteger)seconds;
{
    // Allocate temporary frame for decoded RGB data
    AVFrame *rgb_frame = av_frame_alloc();
    if (!rgb_frame)
        return nil;
    rgb_frame->format = AV_PIX_FMT_RGB24;
    rgb_frame->width = (int) size.width;
    rgb_frame->height = (int) size.height;
    if (av_frame_get_buffer(rgb_frame, 32))
        return nil;

    if ([self newImageWithSize:size atTime:seconds to:rgb_frame->data withStride:rgb_frame->linesize])
    {
        av_frame_free(&rgb_frame);
        return nil;
    }

    if (!enc_ctx || enc_ctx->width != (int) size.width || enc_ctx->height != (int) size.height)
    {
        AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_PNG);
        enc_ctx = avcodec_alloc_context3(codec);
        enc_ctx->pix_fmt = AV_PIX_FMT_RGB24;
        enc_ctx->width = (int) size.width;
        enc_ctx->height = (int) size.height;
        enc_ctx->time_base.num = enc_ctx->time_base.den = 1;  // meaningless for PNG but can't be zero
        enc_ctx->compression_level = 1; // Z_BEST_SPEED = ~20% larger ~25% quicker than default
        if (avcodec_open2(enc_ctx, codec, NULL))
            return nil;
    }

    AVPacket pkt;
    av_init_packet(&pkt);
    pkt.data = NULL;   // let the muxer allocate
    pkt.size = 0;

    CFDataRef data = nil;
    int got_pkt = 0;
    if (!avcodec_encode_video2(enc_ctx, &pkt, rgb_frame, &got_pkt) && got_pkt)
    {
        data = CFDataCreateWithBytesNoCopy(NULL, pkt.data, pkt.size, kCFAllocatorMalloc);
    }
    av_frame_free(&rgb_frame);
    return data;
}

@end
