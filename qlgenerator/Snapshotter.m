//
//  Snapshotter.m
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import "Snapshotter.h"

static const float kPositionSeconds = 10.f;
static const double kTimeoutSeconds = 12;	// longer than VLCMediaThumbnailer timeout (10s) and shorter than launchd timeout (20s)

@implementation Snapshotter

- (id)initWithMedia:(VLCMedia *)media;
{
    if (!(self = [super init]))
        return nil;
    _media = media;
    _thumbnailer = [VLCMediaThumbnailer thumbnailerWithMedia:_media andDelegate:self];
    _snapshot = nil;
    _done = dispatch_semaphore_create(0);
    return self;
}

// gets snapshot and blocks until completion, timeout or failure. Returns true on success.
- (bool)fetchSnapshotwithSize:(CGSize)size;
{
    // offset for our screenshot. Use 10s like the CoreMedia generator
    VLCTime *length = [_media lengthWaitUntilDate:[NSDate dateWithTimeIntervalSinceNow:kTimeoutSeconds]];
    if (length && [[length numberValue] floatValue] > 2000.f*kPositionSeconds)
        _thumbnailer.snapshotPosition = (kPositionSeconds * 1000.f) / [[length numberValue] floatValue];
    else
        _thumbnailer.snapshotPosition = 0.5f;
    _thumbnailer.thumbnailHeight = size.height;
    _thumbnailer.thumbnailWidth = size.width;
    
    [_thumbnailer fetchThumbnail];
    if (dispatch_semaphore_wait(_done, dispatch_time(DISPATCH_TIME_NOW, kTimeoutSeconds * 1000000000)))
        return false;	// Shouldn't happen: VLCMediaThumbnailer hung without timing out!
    return (_snapshot != nil);
}

- (void)mediaThumbnailer:(VLCMediaThumbnailer *)mediaThumbnailer didFinishThumbnail:(CGImageRef)thumbnail
{
    // Called on Main thread
    _snapshot = thumbnail;
    dispatch_semaphore_signal(_done);
}

- (void)mediaThumbnailerDidTimeOut:(VLCMediaThumbnailer *)mediaThumbnailer
{
    // Called on Main thread
    dispatch_semaphore_signal(_done);
}
@end
