#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>

#include "snapshotter.h"

// Implemented in main.m
extern NSBundle *myBundle;
extern BOOL brokenQLPrefetch;

typedef NS_ENUM(NSInteger, QLPreviewMode)
{
    kQLPreviewModeNone              = 0,
    kQLPreviewModeGetInfo           = 1,    // File -> Get Info and Column view in Finder
    kQLPreviewModeQuickLookPrefetch = 2,    // Be ready for QuickLook (called for selected file in Finder's Cover Flow view)
    kQLPreviewModeUnknown           = 3,
    kQLPreviewModeSpotlight         = 4,    // Desktop Spotlight search popup bubble
    kQLPreviewModeQuickLook         = 5,    // File -> Quick Look in Finder (also qlmanage -p)
};


OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

/* -----------------------------------------------------------------------------
   Generate a preview for file

   This function's job is to create preview for designated file
   ----------------------------------------------------------------------------- */

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    // https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    NSNumber *nsPreviewMode = ((__bridge NSDictionary *)options)[@"QLPreviewMode"];
#ifdef DEBUG
    NSLog(@"QLVideo QLPreviewMode=%@ %@", nsPreviewMode, url);
#endif

    @autoreleasepool {
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter || QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

        // Replace title string
        CGSize size = [snapshotter displaySize];
        NSString *title, *channels;
        switch ([snapshotter channels])
        {
            case 0:
                channels = myBundle ? [myBundle localizedStringForKey:@"🔇"     value:nil table:nil] : @"🔇"; break;
            case 1:
                channels = myBundle ? [myBundle localizedStringForKey:@"mono"   value:nil table:nil] : @"mono"; break;
            case 2:
                channels = myBundle ? [myBundle localizedStringForKey:@"stereo" value:nil table:nil] : @"stereo"; break;
            case 6:
                channels = myBundle ? [myBundle localizedStringForKey:@"5.1"    value:nil table:nil] : @"5.1"; break;
            case 7:
                channels = myBundle ? [myBundle localizedStringForKey:@"6.1"    value:nil table:nil] : @"6.1"; break;
            case 8:
                channels = myBundle ? [myBundle localizedStringForKey:@"7.1"    value:nil table:nil] : @"7.1"; break;
            default:    // Quadraphonic, LCRS or something else
                channels = [NSString stringWithFormat:(myBundle ? [myBundle localizedStringForKey:@"%d🔉" value:nil table:nil] : @"%d🔉"),
                            [snapshotter channels]];
        }
        if ([snapshotter title])
            title = [NSString stringWithFormat:@"%@ (%d×%d %@)", [snapshotter title],
                     (int) size.width, (int) size.height, channels];
        else
            title = [NSString stringWithFormat:@"%@ (%d×%d %@)", [(__bridge NSURL *)url lastPathComponent],
                     (int) size.width, (int) size.height, channels];
        NSDictionary *properties = @{(NSString *) kQLPreviewPropertyDisplayNameKey: title};

        // The preview
        CGImageRef thePreview = NULL;

        // Prefer any cover art (if present) over a playable preview or static snapshot in Finder and Spotlight views
        QLPreviewMode previewMode = nsPreviewMode.intValue;
        if (previewMode == kQLPreviewModeGetInfo || previewMode == kQLPreviewModeSpotlight)
            thePreview = [snapshotter CreateCoverArtWithMode:CoverArtDefault];

        if (!thePreview)
        {
            // If AVFoundation can play it, then hand it off to
            // /System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/Movie.qldisplay
            AVAsset *asset = [AVAsset assetWithURL:(__bridge NSURL *)url];
            if (asset)	// note: asset.playable==true doesn't imply there's a playable video track
            {
                AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
                if (track && track.playable)
                {
                    QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, (__bridge CFDictionaryRef) properties);
                    return kQLReturnNoError;    // early exit
                }
            }
            if (QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

            // kQLPreviewModeQuickLookPrefetch is broken for "non-native" files on Mavericks - the user gets a blank window
            // if they invoke QuickLook soon after. Presumambly QuickLookUI is caching and getting confused?
            // If we return nothing we get called again with no QLPreviewMode option. This somehow forces QuickLookUI to
            // correctly call us with kQLPreviewModeQuickLook when the user later invokes QuickLook. What a crock.
            if (brokenQLPrefetch && previewMode == kQLPreviewModeQuickLookPrefetch)
                return kQLReturnNoError;    // early exit

            // AVFoundation can't play it; prefer landscape cover art (if present) over a static snapshot
            if (previewMode == kQLPreviewModeQuickLook || previewMode == kQLPreviewModeQuickLookPrefetch || previewMode == kQLPreviewModeNone)
                thePreview = [snapshotter CreateCoverArtWithMode:CoverArtLandscape];
        }

        // Fall back to generating a static snapshot
        if (!thePreview)
            thePreview = [snapshotter CreateSnapshotWithSize:size];
        if (!thePreview)
            return kQLReturnNoError;

        // display
        if (QLPreviewRequestIsCancelled(preview))
        {
            CGImageRelease(thePreview);
            return kQLReturnNoError;
        }
        CGContextRef context = QLPreviewRequestCreateContext(preview, CGSizeMake(CGImageGetWidth(thePreview), CGImageGetHeight(thePreview)), true, (__bridge CFDictionaryRef) properties);
        CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(thePreview), CGImageGetHeight(thePreview)), thePreview);
        QLPreviewRequestFlushContext(preview, context);
        CGContextRelease(context);
        CGImageRelease(thePreview);
    }
    return kQLReturnNoError;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
    // Implement only if supported
}
