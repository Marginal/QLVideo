#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>

#include "snapshotter.h"


OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);

/* -----------------------------------------------------------------------------
    Generate a thumbnail for file

   This function's job is to create thumbnail for designated file as fast as possible
   ----------------------------------------------------------------------------- */

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    // https://developer.apple.com/library/prerelease/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool {
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter) return kQLReturnNoError;

        // Use cover art if present
        CGImageRef snapshot = [snapshotter CreateCoverArtWithSize:maxSize];
        if (snapshot)
        {
            QLThumbnailRequestSetImage(thumbnail, snapshot, NULL);
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
