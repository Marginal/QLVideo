//
//  Snapshotter.h
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import <Cocoa/Cocoa.h>
#import <MediaToolbox/MediaToolbox.h>
#include <os/log.h>

#include "libavformat/avformat.h"
#include <libavcodec/avcodec.h>

#ifdef DEBUG
#define LOGPRIVATE "%{public}@"
#else
#define LOGPRIVATE "%{mask.hash}@"
#endif

typedef NS_ENUM(NSInteger, CoverArtMode) {
    CoverArtDefault = 0,
    CoverArtThumbnail = 1,
    CoverArtLandscape = 2,
};

@interface Snapshotter : NSObject {
    AVCodecContext *dec_ctx;
    AVCodecContext *enc_ctx; // Only allocated if needed
    int _pictures;           // "best" video stream is pre-computed pictures (i.e. DRMed content)
    int _channels;           // number of audio channels - purely for display
    NSString *_title;        // title for dsiplay

    // single pre-computed picture that ffmpeg doesn't understand or present as a stream, and that we treat like a timed thumbnail
    int32_t picture_size;
    int64_t picture_off;
    int picture_width;
    int picture_height;
}

- (instancetype _Nullable)initWithURL:(CFURLRef _Nonnull)url;
- (void)dealloc;
- (CGImageRef _Nullable)newCoverArtWithMode:(CoverArtMode)mode CF_RETURNS_RETAINED;
- (CGImageRef _Nullable)newSnapshotWithSize:(CGSize)size atTime:(NSInteger)seconds CF_RETURNS_RETAINED;
- (CFDataRef _Nullable)newPNGWithSize:(CGSize)size atTime:(NSInteger)seconds CF_RETURNS_RETAINED;

// Really should be internal, but handy to share with csimporter
- (AVStream *_Nullable)coverArtStreamWithMode:(CoverArtMode)mode;
@property(nonatomic, assign, readonly, nullable) AVFormatContext *fmt_ctx;
@property(nonatomic, assign, readonly) int audio_stream_idx; // index of "best" audio stream
@property(nonatomic, assign, readonly) int video_stream_idx; // index of "best" video stream

@property(nonatomic, assign, readonly) int pictures;
@property(nonatomic, assign, readonly) int channels;
@property(nonatomic, assign, readonly) CGSize displaySize;
@property(nonatomic, assign, readonly) CGSize previewSize;
@property(nonatomic, assign, readonly) NSInteger duration;
@property(nonatomic, retain, readonly, nullable) NSString *videoCodec;
@property(nonatomic, retain, readonly, nullable) NSString *title;

@end
