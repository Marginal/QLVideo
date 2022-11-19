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

@property (nonatomic,assign,readonly) BOOL playable;
@property (nonatomic,assign,readonly) int channels;
@property (nonatomic,assign,readonly) CGSize displaySize;
@property (nonatomic,assign,readonly) NSInteger duration;
@property (nonatomic,assign,readonly) NSString *title;

@end

#endif /* player_h */
