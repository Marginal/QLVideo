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
    AVCodec *codec;
    AVFrame *frame;     // holds the raw frame data for the last snapshot
    AVPicture picture;  // holds the RGB data for the last snapshot
}
- (id) initWithURL:(CFURLRef)url;
- (void) dealloc;
- (CGSize) displaySize;
- (CGImageRef) CreateSnapshotWithSize:(CGSize)size;
@end
