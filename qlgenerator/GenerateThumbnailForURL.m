#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>

#include "snapshotter.h"

// Undocumented properties
const CFStringRef kQLThumbnailPropertyIconModeKey   = CFSTR("IconMode");
const CFStringRef kQLThumbnailPropertyIconFlavorKey = CFSTR("IconFlavor");

typedef NS_ENUM(NSInteger, IconFlavor)
{
    IconFlavorPlain     = 0,
    IconFlavorShadow    = 1,
    IconFlavorBook      = 2,
    IconFlavorMovie     = 3,
    IconFlavorAddress   = 4,
    IconFlavorImage     = 5,
    IconFlavorGloss     = 6,
    IconFlavorSlide     = 7,
    IconFlavorSquare    = 8,
    IconFlavorBorder    = 9,
    // = 10,
    IconFlavorCalendar  = 11,
    IconFlavorPattern   = 12,
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

    @autoreleasepool {
#ifdef DEBUG
        NSLog(@"QLVideo options=%@ size=%dx%d %@", options, (int) maxSize.width, (int) maxSize.height, url);
#endif
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter) return kQLReturnNoError;

        // Use cover art if present
        CGImageRef snapshot = [snapshotter CreateCoverArtWithMode:CoverArtThumbnail];
        if (snapshot)
        {
            NSDictionary *properties = @{(__bridge NSString *) kQLThumbnailPropertyIconFlavorKey: @(IconFlavorGloss) }; // suppress letterbox mattes
            QLThumbnailRequestSetImage(thumbnail, snapshot, (__bridge CFDictionaryRef) properties);
            CGImageRelease(snapshot);
            return kQLReturnNoError;
        }

        // determine thumbnail size (scale up if video is tiny)
        CGSize size = [snapshotter displaySize];
        CGSize scaled;
        if (size.width/maxSize.width > size.height/maxSize.height)
            scaled = CGSizeMake(maxSize.width, round(size.height * maxSize.width / size.width));
        else
            scaled = CGSizeMake(round(size.width * maxSize.height / size.height), maxSize.height);

        if (QLThumbnailRequestIsCancelled(thumbnail)) return kQLReturnNoError;
        snapshot = [snapshotter CreateSnapshotWithSize:scaled];
        if (!snapshot) return kQLReturnNoError;
        
        QLThumbnailRequestSetImage(thumbnail, snapshot, NULL);
        CGImageRelease(snapshot);
        return kQLReturnNoError;
    }
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{
    // Implement only if supported
}
