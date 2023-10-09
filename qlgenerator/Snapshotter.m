//
//  Snapshotter.m
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import "Snapshotter.h"

#include <string.h>
#include <libavformat/isom.h>
#include <libswscale/swscale.h>

#ifndef DEBUG
#include <pthread.h>
#include <signal.h>
#endif

static os_log_t logger = NULL;

static const int kMaxKeyframeTime = 5;  // How far to look for a keyframe [s]
static const int kMaxKeyframeBlankSkip = 4;  // How many keyframes to skip for being too black or too white

// Direct ffmpeg log output to system log
static void av_log_callback(void *avcl, int level, const char *fmt, va_list vl)
{
    int print_prefix = 0;
    char *line = NULL;

    if (level > av_log_get_level())
        return;

    int line_size = av_log_format_line2(avcl, level, fmt, vl, line, 0, &print_prefix);
    if (line_size <= 0 || !(line = malloc(line_size + 1)))
        return; // Can't log!

    print_prefix = 0;
    if (av_log_format_line2(avcl, level, fmt, vl, line, line_size + 1, &print_prefix) > 0)
    {
        switch (level)
        {
            case AV_LOG_PANIC:
                os_log_fault(logger, "%{public}s", line);
                break;

            case AV_LOG_FATAL:
                os_log_error(logger, "%{public}s", line);
                break;

            case AV_LOG_ERROR:
            case AV_LOG_WARNING:
            case AV_LOG_INFO:
                os_log_info(logger, "%{public}s", line);
                break;

            case AV_LOG_VERBOSE:
            case AV_LOG_DEBUG:
            case AV_LOG_TRACE:
            default:
                os_log_debug(logger, "%{public}s", line);
        }
    }
    free(line);
}


#ifndef DEBUG
void segv_handler(int signum)
{
    if (logger)
        os_log_fault(logger, "Thread exiting on signal %{darwin.signal}d", signum);
    pthread_exit(NULL);
}
#endif


@implementation Snapshotter

@synthesize fmt_ctx;
@synthesize audio_stream_idx;
@synthesize video_stream_idx;

+ (void) load
{
    if (!logger)
        logger = os_log_create("uk.org.marginal.qlvideo", "snapshotter");

    os_log_debug(logger, "Snapshotter load");

#ifndef DEBUG
    // Install a handler to kill this thread in the hope that other thumbnail threads in the ThumbnailsAgent process can continue
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    sa.sa_handler = segv_handler;
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
#endif

    av_log_set_callback(av_log_callback);
#ifndef DEBUG
    av_log_set_level(AV_LOG_WARNING|AV_LOG_SKIP_REPEATED);
#else
    av_log_set_level(AV_LOG_DEBUG|AV_LOG_SKIP_REPEATED);
#endif
}

- (instancetype) initWithURL:(CFURLRef)url
{
    if (!(self = [super init]))
        return nil;

    int ret;
    if ((ret = avformat_open_input(&fmt_ctx, [[(__bridge NSURL*) url path] UTF8String], NULL, NULL)))
    {
        os_log_error(logger, "Can't open " LOGPRIVATE " - %{public}s", [(__bridge NSURL*) url path], av_err2str(ret));
        return nil;
    }

    if ((ret = avformat_find_stream_info(fmt_ctx, NULL)))
    {
        os_log_error(logger, "Can't find stream info for " LOGPRIVATE " - %{public}s", [(__bridge NSURL*) url path], av_err2str(ret));
        return nil;
    }

    // Find best audio stream and record channel count
    audio_stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (audio_stream_idx >= 0)
        _channels = fmt_ctx->streams[audio_stream_idx]->codecpar->ch_layout.nb_channels;

    AVDictionaryEntry *tag = av_dict_get(fmt_ctx->metadata, "title", NULL, 0);
    if (tag && tag->value)
        _title = @(tag->value);

    // Find best video stream and open appropriate codec
    const AVCodec *codec = NULL;
    video_stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (video_stream_idx >= 0)
    {
        AVStream *stream = fmt_ctx->streams[video_stream_idx];
        if (!(dec_ctx = avcodec_alloc_context3(NULL)))
            return nil;
        avcodec_parameters_to_context(dec_ctx, stream->codecpar);
        avcodec_open2(dec_ctx, codec, NULL);
        _pictures = (stream->disposition == (AV_DISPOSITION_ATTACHED_PIC|AV_DISPOSITION_TIMED_THUMBNAILS) && ((int) stream->nb_frames > 0) ? (int) stream->nb_frames: 0);
    }
    else
    {
        // Get best stream (for metadata) even though we can't view it
        video_stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (video_stream_idx < 0)
            return nil;     // no video streams - viewable or otherwise

        if (!(dec_ctx = avcodec_alloc_context3(NULL)))
            return nil;
        avcodec_parameters_to_context(dec_ctx, fmt_ctx->streams[video_stream_idx]->codecpar);

        // Special handling for Canon CRM movies which have a custom codec that ffmpeg doesn't understand, and a single JPEG preview picture
        if ((tag = av_dict_get(fmt_ctx->metadata, "major_brand", NULL, AV_DICT_MATCH_CASE)) && !strncmp(tag->value, "crx ", 4))
        {

            // MOVContext *mov = fmt_ctx->priv_data;
            AVIOContext *pb = fmt_ctx->pb;
            int64_t file_size = avio_size(pb);
            avio_seek(pb, 0, SEEK_SET);
            if (pb->seekable & AVIO_SEEKABLE_NORMAL)
            {
                while(avio_tell(pb) <= file_size - 8 && !avio_feof(pb))
                {
                    MOVAtom atom;
                    int64_t atom_off = avio_tell(pb);    // offset of start of atom
                    atom.size = avio_rb32(pb);
                    atom.type = avio_rl32(pb);
                    if (atom.size == 0)
                        atom.size = file_size - atom_off; // size 0 -> extends to EOF
                    else if (atom.size == 1 && avio_tell(pb) <= file_size - 16) // extended size
                        atom.size = avio_rb64(pb);
                    if (atom_off + atom.size > file_size)
                        break;  // file truncated
                    if (atom.type == MKTAG('u','u','i','d'))
                    {
                        static const uint8_t uuid_prvw[] = { 0xea, 0xf4, 0x2b, 0x5e, 0x1c, 0x98, 0x4b, 0x88, 0xb9, 0xfb, 0xb7, 0xdc, 0x40, 0x6e, 0x4d, 0x16 };
                        uint8_t uuid[16];
                        if (avio_read(pb, uuid, sizeof(uuid)) != sizeof(uuid))
                            break;
                        if (!memcmp(uuid, uuid_prvw, sizeof(uuid)))
                        {
                            MOVAtom prvw;
                            avio_rb64(pb);  // unknown = 1
                            prvw.size = avio_rb32(pb);
                            prvw.type = avio_rl32(pb);
                            if (prvw.type == MKTAG('P','R','V','W'))
                            {
                                avio_rb32(pb);  // unknown = 0
                                avio_rb16(pb);  // unknown = 1
                                picture_width = avio_rb16(pb);
                                picture_height= avio_rb16(pb);
                                avio_rb16(pb);  // unknown = 1
                                picture_size = avio_rb32(pb);
                                picture_off = avio_tell(pb);
                                _pictures = 1;
                                break;
                            }
                        };
                    }
                    avio_seek(pb, atom_off + atom.size, SEEK_SET);
                }
            }
        }
    }

    // If we can't decode the video stream, might still be able to read metadata and cover art.
    return self;
}

- (void) dealloc
{
    os_log_debug(logger, "Snapshotter dealloc");
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&fmt_ctx);
    if (enc_ctx)
        avcodec_free_context(&enc_ctx); // also closes the codec
}

// Native frame size, adjusting for anamorphic
- (CGSize) displaySize
{
    if (video_stream_idx < 0)
        return CGSizeMake(0,0);

    AVRational sar = av_guess_sample_aspect_ratio(fmt_ctx, fmt_ctx->streams[video_stream_idx], NULL);
    if (sar.num > 1 && sar.den > 1)
        return CGSizeMake(av_rescale(dec_ctx->width, sar.num, sar.den), dec_ctx->height);
    else
        return CGSizeMake(dec_ctx->width, dec_ctx->height);
}

// Native size of the preview we generate
- (CGSize) previewSize
{
    if (picture_width && picture_height)
        return CGSizeMake(picture_width, picture_height);
    else
        return [self displaySize];
}

// Duration [s]
- (NSInteger) duration
{
    return fmt_ctx->duration > 0 ? (fmt_ctx->duration / AV_TIME_BASE) : 0; // We're not interested in sub-second accuracy
}

// Gets cover art if available, or nil.
- (NSData *) dataCoverArtWithMode:(CoverArtMode)mode
{
    AVStream *art_stream = [self coverArtStreamWithMode: mode];

    // Extract data
    NSData *data;
    if (!art_stream)
        return nil;
    else if (art_stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
        data = [NSData dataWithBytes: art_stream->attached_pic.data length: art_stream->attached_pic.size];
    else
        data = [NSData dataWithBytes: art_stream->codecpar->extradata length: art_stream->codecpar->extradata_size];
    return data;
}

// Gets cover art if available, or nil.
- (CGImageRef) newCoverArtWithMode:(CoverArtMode)mode
{
    AVStream *art_stream = [self coverArtStreamWithMode: mode];

    // Extract data
    CFDataRef data;
    if (!art_stream)
        return nil;
    else if (art_stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
        data = CFDataCreateWithBytesNoCopy(NULL, art_stream->attached_pic.data, art_stream->attached_pic.size, kCFAllocatorNull);   // we'll dealloc when fmt_ctx is closed
    else
        data = CFDataCreateWithBytesNoCopy(NULL, art_stream->codecpar->extradata, art_stream->codecpar->extradata_size, kCFAllocatorNull);   // we'll dealloc when fmt_ctx is closed

    // wangle into a CGImage
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGImageRef image = (art_stream->codecpar->codec_id == AV_CODEC_ID_PNG) ?
        CGImageCreateWithPNGDataProvider (provider, NULL, false, kCGRenderingIntentDefault) :
        CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CFRelease(data);

    if (image && (!CGImageGetWidth(image) || !CGImageGetHeight(image)))
    {
        os_log_info(logger, "Zero sized cover art %ldx%ld", CGImageGetWidth(image), CGImageGetHeight(image));
        CGImageRelease(image);
        return nil;
    }
    return image;

}

// Find stream with best cover art, or -1
- (AVStream*) coverArtStreamWithMode:(CoverArtMode)mode
{
    AVStream *art_stream = NULL;
    int art_priority = 0;

    for (int idx=0; idx < fmt_ctx->nb_streams; idx++)
    {
        AVStream *s = fmt_ctx->streams[idx];
        AVCodecParameters *params = s->codecpar;
        if (params && (params->codec_id == AV_CODEC_ID_PNG || params->codec_id == AV_CODEC_ID_MJPEG))
        {
            /* Depending on codec and ffmpeg version cover art may be represented as attachment or as additional video stream(s) */
            if (params->codec_type == AVMEDIA_TYPE_ATTACHMENT ||
                (params->codec_type == AVMEDIA_TYPE_VIDEO &&
                 ((s->disposition & (AV_DISPOSITION_ATTACHED_PIC|AV_DISPOSITION_TIMED_THUMBNAILS)) == AV_DISPOSITION_ATTACHED_PIC)))
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

    return art_stream;
}


// Private method. Gets snapshot as raw RGB, blocking until completion, timeout or failure.
- (int) newImageWithSize:(CGSize)size atTime:(NSInteger)seconds to:(uint8_t *const [])dst withStride:(const int [])dstStride
{
    if (video_stream_idx < 0)
        return -1;
    AVStream *stream = fmt_ctx->streams[video_stream_idx];

    if (!dec_ctx || !avcodec_is_open(dec_ctx))
        return -1;      // Can't decode video stream

    // offset for our screenshot
    if (!_pictures && seconds >= 0)      // Ignore time if we're serving pre-computed pictures
    {
        int ret;
        int64_t timestamp = ((fmt_ctx->start_time == AV_NOPTS_VALUE) ? 0 : fmt_ctx->start_time) + seconds * AV_TIME_BASE;
        if ((ret = avformat_seek_file(fmt_ctx, -1, INT64_MIN, timestamp, timestamp, 0) < 0))
        {
            os_log_info(logger, "Can't seek to %lds - %{public}s", (long)seconds, av_err2str(ret));
            return -1;
        }
    }

    AVPacket *pkt = NULL;
    if (!(pkt = av_packet_alloc()))
        return -1;

    AVFrame *frame = NULL; // holds the raw frame data
    if (!(frame = av_frame_alloc()))
        return -1;

    int64_t stop_pts = 0;
    avcodec_flush_buffers(dec_ctx); // Discard any buffered packets left over from previous call
    do
    {
        int ret;

        if ((ret = av_read_frame(fmt_ctx, pkt)))
        {
            os_log_info(logger, "Failed to extract a packet starting at %lds - %{public}s", (long)seconds, av_err2str(ret));
            break;
        }
        else if (pkt->stream_index == video_stream_idx)
        {
            if (!stop_pts)
            {
                stop_pts = pkt->pts + av_rescale(kMaxKeyframeTime, stream->time_base.den, stream->time_base.num);
            }

            if ((ret = avcodec_send_packet(dec_ctx, pkt)))
            {
                // MPEG TS demuxer doesn't necessarily seek to keyframes. So keep looking for a decodable frame.
                if (pkt->pts > stop_pts)
                {
                    os_log_info(logger, "Can't decode a packet - giving up!");
                    break;    // Failed to decode
                }
                else
                {
                    os_log_debug(logger, "Can't decode packet with PTS=%lld - %{public}s", pkt->pts, av_err2str(ret));
                    av_packet_unref(pkt);
                    continue;
                }
            }

            if ((ret = avcodec_receive_frame(dec_ctx, frame)))
            {
                if (ret == AVERROR(EAGAIN))
                {
                    av_frame_unref(frame);
                    av_packet_unref(pkt);
                    continue; // Keep trying
                }
                else
                {
                    os_log_info(logger, "Can't get frame at PTS=%lld - %{public}s", pkt->pts, av_err2str(ret));
                    break;    // Failed to decode
                }
            }

            // We have a frame but it won't be useful if it's not a keyframe, which can happen because MPEG TS demuxer doesn't
            // necessarily seek to keyframes, or because we skipped a frame for being blank. So keep looking for a keyframe.
            if (!frame->key_frame && pkt->pts < stop_pts)
            {
                av_frame_unref(frame);
                av_packet_unref(pkt);
                continue;
            }

            // convert raw frame data, and rescale if necessary
            struct SwsContext *sws_ctx;
            if (!(sws_ctx = sws_getContext(dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
                                           size.width, size.height, AV_PIX_FMT_RGB24,
                                           SWS_BICUBIC, NULL, NULL, NULL)))
                break;  // Failed to convert

            sws_scale(sws_ctx, (const uint8_t *const *) frame->data, frame->linesize, 0, dec_ctx->height, dst, dstStride);
            sws_freeContext(sws_ctx);
            avcodec_flush_buffers(dec_ctx); // Discard any buffered packets
            av_frame_free(&frame);
            av_packet_free(&pkt);
            return 0;
        }
        else // not a video packet
        {
            av_packet_unref(pkt);
        }
    }
    while (1);

    // Failed to decode frame
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return -1;
}

// Gets non-black snapshot and blocks until completion, timeout or failure.
- (CGImageRef) newSnapshotWithSize:(CGSize)size atTime:(NSInteger)seconds;
{
    uint8_t *picture = NULL;   // points to the RGB data

    // single pre-computed picture that ffmpeg doesn't understand or present as a stream
    if (_pictures && picture_size)
    {
        AVIOContext *pb = fmt_ctx->pb;
        if (avio_seek(pb, picture_off, SEEK_SET) < 0 ||
            !(picture = malloc(picture_size)))
            return nil;
        if (avio_read(pb, picture, picture_size) != picture_size)
        {
            free(picture);
            return nil;
        }
        // wangle into a CGImage
        CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, picture, picture_size, kCFAllocatorMalloc);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGImageRef image = CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        CFRelease(data);    // frees the JPEG data in "picture" too
        return image;
    }

    // video frames or pre-computed pictures presented as a stream
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

        if (_pictures)  // Skip non-blank check for pre-computed pictures
            break;

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
        {
            os_log_debug(logger, "Skipping blank frame");
            seconds = -1;   // next keyframe
        }
        else
        {
            break;
        }
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
        const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_PNG);
        enc_ctx = avcodec_alloc_context3(codec);
        enc_ctx->pix_fmt = AV_PIX_FMT_RGB24;
        enc_ctx->width = (int) size.width;
        enc_ctx->height = (int) size.height;
        enc_ctx->time_base.num = enc_ctx->time_base.den = 1;  // meaningless for PNG but can't be zero
        enc_ctx->compression_level = 1; // Z_BEST_SPEED = ~20% larger ~25% quicker than default
        if (avcodec_open2(enc_ctx, codec, NULL))
            return nil;
    }

    AVPacket *pkt;
    if (!(pkt = av_packet_alloc()))
        return nil;

    CFDataRef data = nil;
    if (!avcodec_send_frame(enc_ctx, rgb_frame) && !avcodec_receive_packet(enc_ctx, pkt))
    {
        data = CFDataCreateWithBytesNoCopy(NULL, pkt->data, pkt->size, kCFAllocatorMalloc);
    }
    av_frame_free(&rgb_frame);
    return data;
}

@end
