#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>

#include "generator.h"
#import "Snapshotter.h"

// Undocumented properties
const CFStringRef kQLThumbnailPropertyIconFlavorKey = CFSTR("IconFlavor");
const CFStringRef kQLThumbnailPropertyIconFlavorKey_10_15 = CFSTR("icon");

typedef NS_ENUM(NSInteger, QLThumbnailIconFlavor)
{
    kQLThumbnailIconPlainFlavor		= 0,
    kQLThumbnailIconShadowFlavor	= 1,
    kQLThumbnailIconBookFlavor		= 2,
    kQLThumbnailIconMovieFlavor		= 3,
    kQLThumbnailIconAddressFlavor	= 4,
    kQLThumbnailIconImageFlavor		= 5,
    kQLThumbnailIconGlossFlavor		= 6,
    kQLThumbnailIconSlideFlavor		= 7,
    kQLThumbnailIconSquareFlavor	= 8,
    kQLThumbnailIconBorderFlavor	= 9,
    // = 10,
    kQLThumbnailIconCalendarFlavor	= 11,
    kQLThumbnailIconPatternFlavor	= 12,
};


OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);

/* -----------------------------------------------------------------------------
    Generate a thumbnail for file

   This function's job is to create thumbnail for designated file as fast as possible
   ----------------------------------------------------------------------------- */

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    // https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

#ifndef DEBUG   // Skip this check to enable debugging with qlmanage -t ...
    // On Catalina and later the QLThumbnailGenerator application extension generates thumbnails. On Ventura and later this isn't even called.
    if (newQuickLook) {
        os_log_info(logger, "Ignoring thumbnail request for " LOGPRIVATE " with options=%{public}@ UTI=%{public}@ size=%dx%d", url, options, contentTypeUTI, (int) maxSize.width, (int) maxSize.height);
        return kQLReturnNoError;
    }
#endif

    CGImageRef snapshot = NULL;

    @autoreleasepool
    {
        os_log_info(logger, "Thumbnail " LOGPRIVATE " with options=%{public}@ UTI=%{public}@ size=%dx%d", url, options, contentTypeUTI, (int) maxSize.width, (int) maxSize.height);
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter) return kQLReturnNoError;

        // Use cover art if present
        snapshot = [snapshotter newCoverArtWithMode:CoverArtThumbnail];
        if (snapshot)
        {
            os_log_info(logger, "Supplying %ldx%ld cover art for " LOGPRIVATE, CGImageGetWidth(snapshot), CGImageGetHeight(snapshot), url);

            CFStringRef flavor = newQuickLook ? kQLThumbnailPropertyIconFlavorKey_10_15 : kQLThumbnailPropertyIconFlavorKey;
            NSDictionary *properties = @{(__bridge NSString *) flavor: @(kQLThumbnailIconGlossFlavor) }; // suppress letterbox mattes
            QLThumbnailRequestSetImage(thumbnail, snapshot, (__bridge CFDictionaryRef) properties);
            CGImageRelease(snapshot);
            return kQLReturnNoError;
        }

        // determine thumbnail size (scale up if video is tiny)
        CGSize size = [snapshotter previewSize];
        if (!size.width || !size.height)
            return kQLReturnNoError;

        NSNumber *scaleFactor = ((__bridge NSDictionary *) options)[(__bridge NSString *) kQLThumbnailOptionScaleFactorKey];	// can be >1 on Retina displays
        CGSize desired = scaleFactor.boolValue ? CGSizeMake(maxSize.width * scaleFactor.floatValue, maxSize.height * scaleFactor.floatValue) : CGSizeMake(maxSize.width, maxSize.height);
        CGSize scaled;
        if (size.width/desired.width > size.height/desired.height)
            scaled = CGSizeMake(desired.width, round(size.height * desired.width / size.width));
        else
            scaled = CGSizeMake(round(size.width * desired.height / size.height), desired.height);

        if (QLThumbnailRequestIsCancelled(thumbnail)) return kQLReturnNoError;

        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
        NSInteger snapshot_time = [defaults integerForKey:kSettingsSnapshotTime];
        if (snapshot_time <= 0)
            snapshot_time = kDefaultSnapshotTime;

        NSInteger duration = [snapshotter duration];
        NSInteger time = duration < kMinimumDuration ? -1 : (duration < 2 * snapshot_time ? duration/2 : snapshot_time);
        snapshot = [snapshotter newSnapshotWithSize:scaled atTime:time];
        if (!snapshot && time > 0)
            snapshot = [snapshotter newSnapshotWithSize:size atTime:0];    // Failed. Try again at start.
    }   // Free snapshotter and ffmpeg resources before handing back to QuickLook

    if (snapshot)
    {
        os_log_info(logger, "Supplying %ldx%ld snapshot/picture for " LOGPRIVATE, CGImageGetWidth(snapshot), CGImageGetHeight(snapshot), url);

        // explicitly request letterbox mattes for UTIs that don't derive from public.media, such as com.microsoft.advanced-systems-format
        CFStringRef flavor = newQuickLook ? kQLThumbnailPropertyIconFlavorKey_10_15 : kQLThumbnailPropertyIconFlavorKey;
        NSDictionary *properties = @{(__bridge NSString *) flavor: @(kQLThumbnailIconMovieFlavor) };
        QLThumbnailRequestSetImage(thumbnail, snapshot,  (__bridge CFDictionaryRef) properties);
        CGImageRelease(snapshot);
    }
    return kQLReturnNoError;
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{
    // Implement only if supported
}
