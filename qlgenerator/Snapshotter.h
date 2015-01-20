//
//  Snapshotter.h
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import <Cocoa/Cocoa.h>

#include <libavformat/avformat.h>

@interface Snapshotter : NSObject
{
    AVFormatContext *fmt_ctx;
    AVCodecContext *dec_ctx;
    int stream_idx;
    AVStream *stream;
    AVFrame *frame;     // holds the raw frame data for the last snapshot
    AVPicture picture;  // holds the RGB data for the last snapshot
    int _channels;      // number of audio channels - purely for display
    NSString *_title;   // and title
}

- (id) initWithURL:(CFURLRef)url;
- (void) dealloc;
- (CGSize) displaySize;
- (CGImageRef) CreateCoverArtWithSize:(CGSize)size;
- (CGImageRef) CreateSnapshotWithSize:(CGSize)size;

@property (nonatomic,assign,readonly) int channels;
@property (nonatomic,retain,readonly) NSString *title;

@end
