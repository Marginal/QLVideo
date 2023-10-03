//
//  player.m
//  qlgenerator
//
//  Created by Jonathan Harris on 03/02/2019.
//

#import <Foundation/Foundation.h>

#import "Player.h"

#ifdef DEBUG
#  include <os/log.h>
extern os_log_t logger;
#endif

@implementation Player

- (instancetype) initWithURL:(NSURL*)url;
{
    if (self = [super init])
    {
        _semaphore = dispatch_semaphore_create(0);
        _asset = [AVURLAsset assetWithURL:url];
        _playerItem = [AVPlayerItem playerItemWithAsset:_asset automaticallyLoadedAssetKeys:@[@"playable", @"hasProtectedContent"]];
        [_playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:nil];
        _player = [AVPlayer playerWithPlayerItem:_playerItem];
        return self;
    }
    else
        return nil;
}

+ (instancetype) playerWithURL:(NSURL*)url;
{
    return [[self alloc] initWithURL:url];
}

// This will be called on main thread, so 'playable' better not be also called on main thread
- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context;
{
    if ([keyPath isEqualToString:@"status"])
    {
        NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
        if ([statusNumber isKindOfClass:[NSNumber class]] && statusNumber.integerValue > AVPlayerItemStatusUnknown)
            dispatch_semaphore_signal(_semaphore);
    }
}

- (void) dealloc
{
    [_playerItem removeObserver:self forKeyPath:@"status" context:nil];
}

- (BOOL) playable;
{
    dispatch_semaphore_wait(_semaphore, DISPATCH_TIME_FOREVER); // Wait for observeValueForKeyPath callback
    // AVAsset.playable and AVAssetTrack.playable return false negatives for some HEVC content on Mojave.
    // AVAsset.playable and AVPlayerItem.status return false positives for content where only the audio is playable (e.g.
    // Eutelsat.Demo.HEVC.ts) but in this case either AVAsset says there's no video tracks or AVPlayerItem.presentationSize is zero.

#ifdef DEBUG
    AVAssetTrack *videotrack = [_asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    os_log_info(logger, "\nAsset playable=%d, readable=%d, protected=%d\nTrack %{public}@, playable=%d, decodable=%d, enabled=%d\nPlayerItem status=%ld, width=%d, error=%{public}@",
                _asset.playable, _asset.readable, _asset.hasProtectedContent,
                videotrack, videotrack.playable, videotrack.decodable, videotrack.enabled,
                (long)_playerItem.status, (int) _playerItem.presentationSize.width, _playerItem.error);
#endif

    return (_playerItem.status == AVPlayerItemStatusReadyToPlay &&
            _playerItem.presentationSize.width &&
            [_asset tracksWithMediaType:AVMediaTypeVideo].firstObject &&
            ![_asset hasProtectedContent]);
}

- (NSString *) title
{
    AVMetadataItem  *theTitle = [AVMetadataItem metadataItemsFromArray:_asset.commonMetadata withKey:@"title" keySpace:AVMetadataKeySpaceCommon].firstObject;
    return (theTitle ? (NSString*) theTitle.value : nil);
}

- (int) channels
{
    int ret = 0;

    for (AVAssetTrack *assettrack in [_asset tracksWithMediaType:AVMediaTypeAudio])
    {
        for (int i = 0; i < assettrack.formatDescriptions.count; i++)
        {
            CMAudioFormatDescriptionRef desc = (__bridge CMAudioFormatDescriptionRef)assettrack.formatDescriptions[i];
            const AudioStreamBasicDescription *stream = CMAudioFormatDescriptionGetStreamBasicDescription(desc);
            if (stream && stream->mChannelsPerFrame > ret)
                ret = stream->mChannelsPerFrame;
        }
    }
    return ret;
}

- (CGSize) displaySize;
{
    return _playerItem.presentationSize;
}

- (NSInteger) duration;
{
    CMTime time = _asset.duration;  // For transport streams (e.g. hd_dts_orchestra_short-DWEU.m2ts) more reliable than AVPlayerItem.duration
    return CMTIME_IS_NUMERIC(time) ? time.value / time.timescale : 0;
}
@end
