//
//  Snapshotter.h
//  QLVideo
//
//  Created by Jonathan Harris on 13/07/2014.
//
//

#import <Cocoa/Cocoa.h>
#import <VLCKit/VLCKit.h>

@interface Snapshotter : NSOperation <VLCMediaThumbnailerDelegate>
{
    VLCMedia *_media;
    VLCMediaThumbnailer *_thumbnailer;
    dispatch_semaphore_t _done;
}
- (id)initWithMedia:(VLCMedia *)media;
- (bool)fetchSnapshotwithSize:(CGSize)size;
@property (readonly) CGImageRef snapshot;
@end
