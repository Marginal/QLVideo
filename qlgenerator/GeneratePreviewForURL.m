#import <QuickLook/QuickLook.h>

#import "snapshotter.h"

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

/* -----------------------------------------------------------------------------
   Generate a preview for file

   This function's job is to create preview for designated file
   ----------------------------------------------------------------------------- */

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    // This is (probably) called on a thread other than Main (QLSupportsConcurrentRequests==true in Info.plist)
    // and we should block until completion.
    // https://developer.apple.com/library/prerelease/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool {
        VLCMedia *media = [VLCMedia mediaWithURL:(__bridge NSURL *) url];
        if (!media) return NSFileReadUnknownError;

        // obtain screenshot dimensions
        if (QLPreviewRequestIsCancelled(preview)) return noErr;
        CGSize size = CGSizeMake(0,0);
        for (NSDictionary *info in [media tracksInformation])
            if ([[info objectForKey:VLCMediaTracksInformationType] isEqualToString:VLCMediaTracksInformationTypeVideo])
            {
                size = CGSizeMake([[info objectForKey:VLCMediaTracksInformationVideoWidth]  floatValue],
                                  [[info objectForKey:VLCMediaTracksInformationVideoHeight] floatValue]);
                break;
            }
        if (size.height==0 || size.width==0)
            return NSFileReadUnknownError;
        
        if (QLPreviewRequestIsCancelled(preview)) return noErr;
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithMedia:media];
        if (![snapshotter fetchSnapshotwithSize:size])
            return NSFileReadUnknownError;

        // create the drawable
        if (QLPreviewRequestIsCancelled(preview)) return noErr;
        CGSize actualSize = CGSizeMake(CGImageGetWidth([snapshotter snapshot]), CGImageGetHeight([snapshotter snapshot]));
        CGContextRef context = QLPreviewRequestCreateContext(preview, actualSize, true, NULL);
        CGContextDrawImage(context, CGRectMake(0,0,actualSize.width,actualSize.height), [snapshotter snapshot]);
        QLPreviewRequestFlushContext(preview, context);
        CGContextRelease(context);
    }
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
    // Implement only if supported
}
