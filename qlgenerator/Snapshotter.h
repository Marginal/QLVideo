//
//  Snapshotter.h
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import <Cocoa/Cocoa.h>

#include "libavformat/avformat.h"


typedef NS_ENUM(NSInteger, CoverArtMode)
{
    CoverArtDefault     = 0,
    CoverArtThumbnail   = 1,
    CoverArtLandscape   = 2,
};


@interface Snapshotter : NSObject
{
    AVFormatContext *fmt_ctx;
    AVCodecContext *dec_ctx;
    int stream_idx;
    AVStream *stream;
    int _channels;      // number of audio channels - purely for display
    NSString *_title;   // and title
}

- (instancetype) initWithURL:(CFURLRef)url;
- (void) dealloc;
- (CGSize) displaySize;
- (NSInteger) duration;
- (CGImageRef) CreateCoverArtWithMode:(CoverArtMode)mode;
- (CGImageRef) CreateSnapshotWithSize:(CGSize)size atTime:(NSInteger)seconds;

@property (nonatomic,assign,readonly) int channels;
@property (nonatomic,retain,readonly) NSString *title;

@end
