#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>

#include "snapshotter.h"

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

/* -----------------------------------------------------------------------------
   Generate a preview for file

   This function's job is to create preview for designated file
   ----------------------------------------------------------------------------- */

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    // https://developer.apple.com/library/prerelease/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool {
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter) return NSFileReadUnknownError;
        
        if (QLPreviewRequestIsCancelled(preview)) return noErr;
        CGSize size = [snapshotter displaySize];
        CGImageRef snapshot = [snapshotter CreateSnapshotWithSize:size];
        if (!snapshot) return NSFileReadUnknownError;

        if (QLPreviewRequestIsCancelled(preview))
        {
            CGImageRelease(snapshot);
            return noErr;
        }
        CGContextRef context = QLPreviewRequestCreateContext(preview, size, true, NULL);
        CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), snapshot);
        QLPreviewRequestFlushContext(preview, context);
        CGContextRelease(context);
        CGImageRelease(snapshot);
    }
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
    // Implement only if supported
}
