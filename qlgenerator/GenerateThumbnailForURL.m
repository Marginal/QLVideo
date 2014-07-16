#import <QuickLook/QuickLook.h>

#import "snapshotter.h"

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);

/* -----------------------------------------------------------------------------
    Generate a thumbnail for file

   This function's job is to create thumbnail for designated file as fast as possible
   ----------------------------------------------------------------------------- */

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    // This is (probably) called on a thread other than Main (QLSupportsConcurrentRequests==true in Info.plist)
    // and we should block until completion.
    // https://developer.apple.com/library/prerelease/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool {
        VLCMedia *media = [VLCMedia mediaWithURL:(__bridge NSURL *) url];
        if (!media) return NSFileReadUnknownError;

        // obtain screenshot dimensions
        if (QLThumbnailRequestIsCancelled(thumbnail)) return noErr;
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

        CGSize scaled;
        if (size.width/maxSize.width > size.height/maxSize.height)
            scaled = CGSizeMake(maxSize.width, size.height * maxSize.width / size.width);
        else
            scaled = CGSizeMake(size.width * maxSize.height / size.height, maxSize.height);

        if (QLThumbnailRequestIsCancelled(thumbnail)) return noErr;
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithMedia:media];
        if (![snapshotter fetchSnapshotwithSize:scaled])
            return NSFileReadUnknownError;
        
        if (QLThumbnailRequestIsCancelled(thumbnail)) return noErr;
        QLThumbnailRequestSetImage(thumbnail, [snapshotter snapshot], NULL);
    }
    return noErr;
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{
    // Implement only if supported
}
