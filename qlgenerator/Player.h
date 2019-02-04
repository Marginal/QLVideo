//
//  player.h
//  qlgenerator
//
//  Created by Jonathan Harris on 03/02/2019.
//

#import <AVFoundation/AVFoundation.h>

#ifndef player_h
#define player_h

@interface Player : NSObject
{
    AVURLAsset *_asset;
    AVPlayerItem *_playerItem;
    AVPlayer *_player;
    dispatch_semaphore_t _semaphore;
}

- (instancetype) initWithURL:(NSURL*)url;
+ (instancetype) playerWithURL:(NSURL*)url;
- (void) dealloc;
- (BOOL) playable;
- (NSString *) title;
- (int) channels;
- (CGSize) displaySize;
- (NSInteger) duration;

@end

#endif /* player_h */
