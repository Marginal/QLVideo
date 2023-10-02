//
//  Snapshotter.h
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import <Cocoa/Cocoa.h>
#include <os/log.h>

#include <libavcodec/avcodec.h>
#include "libavformat/avformat.h"


#ifdef DEBUG
    #define LOGPRIVATE "%{public}@"
#else
    #define LOGPRIVATE "%{mask.hash}@"
#endif


typedef NS_ENUM(NSInteger, CoverArtMode)
{
    CoverArtDefault     = 0,
    CoverArtThumbnail   = 1,
    CoverArtLandscape   = 2,
};


@interface Snapshotter : NSObject
{
    AVCodecContext *dec_ctx;
    AVCodecContext *enc_ctx;    // Only allocated if needed
    int _pictures;              // "best" video stream is pre-computed pictures (i.e. DRMed content)
    int _channels;              // number of audio channels - purely for display
    NSString *_title;           // title for dsiplay

    // single pre-computed picture that ffmpeg doesn't understand or present as a stream
    int32_t picture_size;
    int64_t picture_off;
    int picture_width;
    int picture_height;
}

- (instancetype) initWithURL:(CFURLRef)url;
- (void) dealloc;
- (CGImageRef) newCoverArtWithMode:(CoverArtMode)mode;
- (NSData*) dataCoverArtWithMode:(CoverArtMode)mode;
- (CGImageRef) newSnapshotWithSize:(CGSize)size atTime:(NSInteger)seconds;
- (CFDataRef) newPNGWithSize:(CGSize)size atTime:(NSInteger)seconds;

// Really should be internal, but handy to share with csimporter
- (AVStream*) coverArtStreamWithMode:(CoverArtMode)mode;
@property (nonatomic,assign,readonly) AVFormatContext *fmt_ctx;
@property (nonatomic,assign,readonly) int audio_stream_idx;       // index of "best" audio stream
@property (nonatomic,assign,readonly) int video_stream_idx;       // index of "best" video stream

@property (nonatomic,assign,readonly) int pictures;
@property (nonatomic,assign,readonly) int channels;
@property (nonatomic,assign,readonly) CGSize displaySize;
@property (nonatomic,assign,readonly) CGSize previewSize;
@property (nonatomic,assign,readonly) NSInteger duration;
@property (nonatomic,retain,readonly) NSString *title;

@end
