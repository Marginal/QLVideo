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

// Logging
static os_log_t logger = NULL;


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

    if (!logger)
        logger = os_log_create("uk.org.marginal.qlvideo", "thumbnailer");

    os_log_info(logger, "Thumbnailer " LOGPRIVATE " with attributes=%{public}@ scale=%.2lf minimumSize=%dx%d maximumSize=%dx%d",
                request.fileURL,
                request.attributeKeys, request.scale,
                (int) request.minimumSize.width, (int) request.minimumSize.height,
                (int) request.maximumSize.width, (int) request.maximumSize.height);

    // @autoreleasepool
    {
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:(__bridge CFURLRef) request.fileURL];
        if (!snapshotter)
        {
            os_log_error(logger, "Can't supply anything for " LOGPRIVATE, request.fileURL);
            return;
        }

        BOOL isCoverArt = false;

        // Use cover art if present
        CGImageRef snapshot = [snapshotter newCoverArtWithMode:CoverArtThumbnail];
        CGSize size; // Size in pixels of the source snapshot
        if (snapshot) {
            isCoverArt = true;
            size = CGSizeMake(CGImageGetWidth(snapshot), CGImageGetHeight(snapshot));
        } else {
            size = [snapshotter previewSize];
        }

        CGSize contextsize; // Size of the returned context - unscaled
        if (size.width/request.maximumSize.width > size.height/request.maximumSize.height) {
            contextsize = CGSizeMake(request.maximumSize.width, round(size.height * request.maximumSize.width / size.width));
        } else {
            contextsize = CGSizeMake(round(size.width * request.maximumSize.height / size.height), request.maximumSize.height);
        }
        CGSize snapshotsize = CGSizeMake(contextsize.width * request.scale, contextsize.height * request.scale);    // Size in pixels of the proportionally scaled snapshot

        CGSize imagesize;   // Size in pixels of the returned context - scaled
        if ((request.minimumSize.width == request.maximumSize.width) || (request.minimumSize.height == request.maximumSize.height)) {
            // Spotlight wants image centered in exactly sized context
            contextsize = request.maximumSize;
            imagesize = CGSizeMake(request.scale * request.maximumSize.width, request.scale * request.maximumSize.height);
        } else {
            // Finder wants proportionally sized context
            imagesize = snapshotsize;
        }

        if (!snapshot)
        {
            // No cover art - generate snapshot
            NSBundle *myBundle = [NSBundle mainBundle];
            NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:myBundle.infoDictionary[@"ApplicationGroup"]];
            NSInteger snapshot_time = [defaults integerForKey:kSettingsSnapshotTime];
            os_log_debug(logger, "SnapshotTime=%d", (int) snapshot_time);
            if (snapshot_time <= 0)
                snapshot_time = kDefaultSnapshotTime;

            NSInteger duration = [snapshotter duration];
            NSInteger time = duration < kMinimumDuration ? -1 : (duration < 2 * snapshot_time ? duration/2 : snapshot_time);
            snapshot = [snapshotter newSnapshotWithSize:snapshotsize atTime:time];
            if (!snapshot && time > 0)
                snapshot = [snapshotter newSnapshotWithSize:size atTime:0];    // Failed. Try again at start.
        }

        if (snapshot) {
            os_log_info(logger, "Supplying %dx%d %s for " LOGPRIVATE, (int) snapshotsize.width, (int) snapshotsize.height,
                        isCoverArt ? "cover art" : ([snapshotter pictures] ? "picture" : "snapshot"), request.fileURL);

            // explicitly request letterbox mattes for UTIs that don't derive from public.media such as com.microsoft.advanced-systems-format, and explicitly suppress them for cover art
            handler([QLThumbnailReply replyWithContextSizeAndFlavor:contextsize flavor:(isCoverArt ? kQLThumbnailIconGlossFlavor : kQLThumbnailIconMovieFlavor) drawingBlock:^BOOL(CGContextRef  _Nonnull context) {
                (void) [snapshotter previewSize]; // retain underlying data for the duration of this block
                int offx = (imagesize.width - snapshotsize.width) / 2;
                int offy = (imagesize.height - snapshotsize.height) / 2;
                CGContextDrawImage(context, CGRectMake(offx, offy, snapshotsize.width, snapshotsize.height), snapshot);
                CGImageRelease(snapshot);
                return YES;
            }], nil);

            return;
        }

        os_log_error(logger, "Couldn't get thumbnail for " LOGPRIVATE, request.fileURL);
    }
}

@end
