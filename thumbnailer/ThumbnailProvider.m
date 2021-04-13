//
//  ThumbnailProvider.m
//  thumbnailer
//
//  Created by Jonathan Harris on 06/04/2021.
//

#import "ThumbnailProvider.h"

#import "Snapshotter.h"

// Settings
NSString * const kSettingsSuiteName     = @"uk.org.marginal.qlvideo";
NSString * const kSettingsSnapshotCount = @"SnapshotCount";     // Max number of snapshots generated in Preview mode.
NSString * const kSettingsSnapshotTime  = @"SnapshotTime";      // Seek offset for thumbnails and single Previews [s].
NSString * const kSettingsSnapshotAlways= @"SnapshotAlways";    // Whether to generate static snapshot(s) even if playable Preview is available.

// Setting defaults
const int kDefaultSnapshotTime = 60;    // CoreMedia generator appears to use 10s. Completely arbitrary.
const int kDefaultSnapshotCount = 10;   // 7-14 fit in the left bar of the Preview window without scrolling, depending on the display vertical resolution.
const int kMaxSnapshotCount = 100;

// Implementation
const int kMinimumDuration = 5;         // Don't bother seeking clips shorter than this [s]. Completely arbitrary.
const int kMinimumPeriod = 60;          // Don't create snapshots spaced more closely than this [s]. Completely arbitrary.


// Hack - Use undocumented property to set icon flavor
@implementation QLThumbnailReply(MyThumbnailReply)

+ (instancetype)replyWithContextSizeAndFlavor:(CGSize)contextSize flavor:(int)flavor drawingBlock:(BOOL (^)(CGContextRef context))drawingBlock
{
    QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:contextSize drawingBlock:drawingBlock];

    SEL selector = NSSelectorFromString(@"setIconFlavor:");
    if (selector)
    {
        NSMethodSignature *signature = [reply methodSignatureForSelector:selector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = reply;
        invocation.selector = selector;
        [invocation setArgument:&flavor atIndex:2];
        [invocation invoke];
    }

    return reply;
}

@end


@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request completionHandler:(void (^)(QLThumbnailReply * _Nullable, NSError * _Nullable))handler API_AVAILABLE(macos(10.15)) {
#ifdef DEBUG
    NSLog(@"QLVideo thumbnailer attributes=%@ scale=%.2lf minimumSize=%dx%d maximumSize=%dx%d %@",
          request.attributeKeys,
          request.scale,
          (int) request.minimumSize.width, (int) request.minimumSize.height,
          (int) request.maximumSize.width, (int) request.maximumSize.height,
          request.fileURL);
#endif

    // @autoreleasepool
    {
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:(__bridge CFURLRef) request.fileURL];
        if (!snapshotter)
        {
#ifdef DEBUG
            NSLog(@"QLVideo can't supply anything for %@", request.fileURL);
#endif
            return;
        }

        // Use cover art if present
        CGImageRef snapshot = [snapshotter newCoverArtWithMode:CoverArtThumbnail];
        if (snapshot)
        {
            CGSize size = CGSizeMake(CGImageGetWidth(snapshot), CGImageGetHeight(snapshot));
            CGSize scaled;
            if (size.width/request.maximumSize.width > size.height/request.maximumSize.height)
                scaled = CGSizeMake(request.maximumSize.width, round(size.height * request.maximumSize.width / size.width));
            else
                scaled = CGSizeMake(round(size.width * request.maximumSize.height / size.height), request.maximumSize.height);
            CGSize pixelsize = CGSizeMake(scaled.width * request.scale, scaled.height * request.scale);
#ifdef DEBUG
            NSLog(@"QLVideo supplying %dx%d cover art for %@", (int) pixelsize.width, (int) pixelsize.height, request.fileURL);
#endif
            // suppress letterbox mattes
            handler([QLThumbnailReply replyWithContextSizeAndFlavor:scaled flavor:kQLThumbnailIconGlossFlavor drawingBlock:^BOOL(CGContextRef  _Nonnull context) {
                (void) [snapshotter previewSize]; // retain underlying data for the duration of this block
                CGContextDrawImage(context, CGRectMake(0, 0, pixelsize.width, pixelsize.height), snapshot);
                CGImageRelease(snapshot);
                return YES;
            }], nil);

            return;
        }

        // No cover art - generate snapshot
        CGSize size = [snapshotter previewSize];
        CGSize scaled;
        if (size.width/request.maximumSize.width > size.height/request.maximumSize.height)
            scaled = CGSizeMake(request.maximumSize.width, round(size.height * request.maximumSize.width / size.width));
        else
            scaled = CGSizeMake(round(size.width * request.maximumSize.height / size.height), request.maximumSize.height);
        CGSize pixelsize = CGSizeMake(scaled.width * request.scale, scaled.height * request.scale);

        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
        NSInteger snapshot_time = [defaults integerForKey:kSettingsSnapshotTime];
        if (snapshot_time <= 0)
            snapshot_time = kDefaultSnapshotTime;

        NSInteger duration = [snapshotter duration];
        NSInteger time = duration < kMinimumDuration ? -1 : (duration < 2 * snapshot_time ? duration/2 : snapshot_time);
        snapshot = [snapshotter newSnapshotWithSize:scaled atTime:time];
        if (!snapshot && time > 0)
            snapshot = [snapshotter newSnapshotWithSize:size atTime:0];    // Failed. Try again at start.
        if (snapshot)
        {
#ifdef DEBUG
            NSLog(@"QLVideo supplying %dx%d %s for %@", (int) pixelsize.width, (int) pixelsize.height, [snapshotter pictures] ? "picture" : "snapshot", request.fileURL);
#endif
            // explicitly request letterbox mattes for UTIs that don't derive from public.media, such as com.microsoft.advanced-systems-format
            handler([QLThumbnailReply replyWithContextSizeAndFlavor:scaled flavor:kQLThumbnailIconMovieFlavor drawingBlock:^BOOL(CGContextRef  _Nonnull context) {
                (void) [snapshotter previewSize]; // retain underlying data for the duration of this block
                CGContextDrawImage(context, CGRectMake(0, 0, pixelsize.width, pixelsize.height), snapshot);
                CGImageRelease(snapshot);
                return YES;
            }], nil);

            return;
        }

#ifdef DEBUG
        NSLog(@"QLVideo couldn't get thumbnail for %@", request.fileURL);
#endif
    }
}

@end
