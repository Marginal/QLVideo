#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import <QTKit/QTKit.h>

#include <sys/stat.h>

#include "generator.h"
#include "snapshotter.h"


// Undocumented options
const CFStringRef kQLPreviewOptionModeKey = CFSTR("QLPreviewMode");
const CFStringRef kQLPreviewPropertyPageElementXPathKey = CFSTR("PageElementXPath");


typedef NS_ENUM(NSInteger, QLPreviewMode)
{
    kQLPreviewNoMode		= 0,
    kQLPreviewGetInfoMode	= 1,	// File -> Get Info and Column view in Finder
    kQLPreviewCoverFlowMode	= 2,	// Finder's Cover Flow view
    kQLPreviewUnknownMode	= 3,
    kQLPreviewSpotlightMode	= 4,	// Desktop Spotlight search popup bubble
    kQLPreviewQuicklookMode	= 5,	// File -> Quick Look in Finder (also qlmanage -p)
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

    @autoreleasepool {
#ifdef DEBUG
        NSLog(@"Preview %@ with options %@", [(__bridge NSURL*)url path], options);
#endif
        Snapshotter *snapshotter = [[Snapshotter alloc] initWithURL:url];
        if (!snapshotter || QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

        // Replace title string
        CFBundleRef myBundle = QLPreviewRequestGetGeneratorBundle(preview);
        CGSize size = [snapshotter displaySize];
        NSString *title, *channels;
        switch ([snapshotter channels])
        {
            case 0:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("🔇"),     NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 1:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("mono"),   NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 2:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("stereo"), NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 6:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("5.1"),    NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 7:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("6.1"),    NULL, myBundle, "Audio channel info in Preview window title")); break;
            case 8:
                channels = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("7.1"),    NULL, myBundle, "Audio channel info in Preview window title")); break;
            default:    // Quadraphonic, LCRS or something else
                channels = [NSString stringWithFormat:CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("%d🔉"), NULL, myBundle, "Audio channel info in Preview window title")),
                            [snapshotter channels]];
        }
        if ([snapshotter title])
            title = [NSString stringWithFormat:@"%@ (%d×%d %@)", [snapshotter title],
                     (int) size.width, (int) size.height, channels];
        else
            title = [NSString stringWithFormat:@"%@ (%d×%d %@)", [(__bridge NSURL *)url lastPathComponent],
                     (int) size.width, (int) size.height, channels];

        // The preview
        CGImageRef thePreview = NULL;

        // Prefer any cover art (if present) over a playable preview or static snapshot in Finder and Spotlight views
        QLPreviewMode previewMode = [((__bridge NSDictionary *)options)[(__bridge NSString *) kQLPreviewOptionModeKey] intValue];
        if (previewMode == kQLPreviewGetInfoMode || previewMode == kQLPreviewSpotlightMode)
            thePreview = [snapshotter newCoverArtWithMode:CoverArtDefault];

        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
        BOOL force_static = [defaults boolForKey:kSettingsSnapshotAlways];
        if (!thePreview && !force_static)
        {
            if (hackedQLDisplay)
            {
                // If QTKit can play it, then hand it off to
                // /System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/LegacyMovie.qldisplay symlinked as Movie.qldisplay

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

                QTMovie *movie = [QTMovie movieWithAttributes:@{QTMovieURLAttribute:(__bridge NSURL *)url,
                                                                QTMovieOpenForPlaybackAttribute:@true,
                                                                QTMovieOpenAsyncOKAttribute:@false}
                                                        error:nil];
                if (movie)
                {
                    QTTrack *track = [movie tracksOfMediaType:QTMediaTypeVideo].firstObject;
                    if (track)
                    {
                        QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, (__bridge CFDictionaryRef) @{(NSString *) kQLPreviewPropertyDisplayNameKey: title});
                        return kQLReturnNoError;    // early exit
                    }
                }
#pragma clang diagnostic pop
            }
            else
            {
                // If AVFoundation can play it, then hand it off to
                // /System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/Movie.qldisplay
                AVAsset *asset = [AVAsset assetWithURL:(__bridge NSURL *)url];
                if (asset)	// note: asset.playable==true doesn't imply there's a playable video track
                {
                    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
                    if (track && track.playable)
                    {
                        QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, (__bridge CFDictionaryRef) @{(NSString *) kQLPreviewPropertyDisplayNameKey: title});
                        return kQLReturnNoError;    // early exit
                    }
                }
            }
            if (QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

            // kQLPreviewCoverFlowMode is broken for "non-native" files on Mavericks - the user gets a blank window
            // if they invoke QuickLook soon after. Presumably QuickLookUI is caching and getting confused?
            // If we return nothing we get called again with no QLPreviewMode option. This somehow forces QuickLookUI to
            // correctly call us with kQLPreviewQuicklookMode when the user later invokes QuickLook. What a crock.
            if (brokenQLCoverFlow && previewMode == kQLPreviewCoverFlowMode)
                return kQLReturnNoError;    // early exit
        }

        // AVFoundation/QTKit can't play it

        // prefer landscape cover art (if present) over a static snapshot
        if (!thePreview && previewMode != kQLPreviewGetInfoMode && previewMode != kQLPreviewSpotlightMode)
            thePreview = [snapshotter newCoverArtWithMode:CoverArtLandscape];

        // Generate a contact sheet?
        NSInteger desired_image_count = [defaults integerForKey:kSettingsSnapshotCount];
        if (desired_image_count <= 0 || desired_image_count >= 100)
            desired_image_count = kDefaultSnapshotCount;

        NSInteger duration = [snapshotter duration];
        int image_count = duration <= 0 ? 0 : (int) (duration / kMinimumPeriod) - 1;
        if (image_count > desired_image_count)
            image_count = (int) desired_image_count;
        if (!thePreview && (previewMode == kQLPreviewNoMode || previewMode == kQLPreviewQuicklookMode) && image_count > 1)
        {
            NSString *html = @"<!DOCTYPE html>\n<html>\n<body style=\"background-color:black\">\n";
            NSMutableDictionary *attachments =[NSMutableDictionary dictionaryWithCapacity:image_count];

            // Use indode # to uniquify snapshot names, otherwise QuickLook can confuse them
            struct stat st;
            int64_t inode = 0;
            if (!stat([(__bridge NSURL *) url fileSystemRepresentation], &st))
                inode = st.st_ino;

            for (int i=0; i < image_count; i++)
            {
                if (QLPreviewRequestIsCancelled(preview))
                    return kQLReturnNoError;

                CGImageRef snapshot = [snapshotter newSnapshotWithSize:size atTime:(duration * (i + 1)) / (image_count + 1)];
                if (!snapshot && !i)
                    snapshot = [snapshotter newSnapshotWithSize:size atTime:0];  // Failed on first frame. Try again at start.
                if (!snapshot)
                    break;

                CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
                CGImageDestinationRef destination = CGImageDestinationCreateWithData(data, kUTTypePNG, 1, NULL);
                if (destination)
                {
                    CGImageDestinationAddImage(destination, snapshot, nil);
                    if (CGImageDestinationFinalize(destination))
                    {
                        html = [html stringByAppendingFormat:@"<div><img src=\"cid:%lld/%03d.png\" width=\"%d\" height=\"%d\"/></div>\n", inode, i, (int) size.width, (int) size.height];
                        [attachments setObject:@{(NSString *) kQLPreviewPropertyMIMETypeKey: @"image/png",
                                                 (NSString *) kQLPreviewPropertyAttachmentDataKey: (__bridge NSData *) data}
                                        forKey:[NSString stringWithFormat:@"%lld/%03d.png", inode, i]];
                    }
                    CFRelease(destination);
                }
                CFRelease(data);
                CGImageRelease(snapshot);
            }

            html = [html stringByAppendingString:@"</body>\n</html>\n"];
            QLPreviewRequestSetDataRepresentation(preview, (__bridge CFDataRef) [html dataUsingEncoding:NSUTF8StringEncoding], kUTTypeHTML,
                                                  (__bridge CFDictionaryRef) @{(NSString *) kQLPreviewPropertyDisplayNameKey: title,
                                                                               (NSString *) kQLPreviewPropertyTextEncodingNameKey: @"UTF-8",
                                                                               (__bridge NSString *) kQLPreviewPropertyPageElementXPathKey: @"/html/body/div",
                                                                               (NSString *) kQLPreviewPropertyPDFStyleKey: @(kQLPreviewPDFPagesWithThumbnailsOnLeftStyle),
                                                                               (NSString *) kQLPreviewPropertyAttachmentsKey: attachments});
            return kQLReturnNoError;    // early exit
        }

        // Fall back to generating a single snapshot

        if (!thePreview)
        {
            NSInteger snapshot_time = [defaults integerForKey:kSettingsSnapshotTime];
            if (snapshot_time <= 0)
                snapshot_time = kDefaultSnapshotTime;
            NSInteger time = duration < kMinimumDuration ? 0 : (duration < 2 * snapshot_time ? duration/2 : snapshot_time);
            thePreview = [snapshotter newSnapshotWithSize:size atTime:time];
            if (!thePreview && time)
                thePreview = [snapshotter newSnapshotWithSize:size atTime:0];    // Failed. Try again at start.
        }
        if (!thePreview)
            return kQLReturnNoError;

        // display
        if (QLPreviewRequestIsCancelled(preview))
        {
            CGImageRelease(thePreview);
            return kQLReturnNoError;
        }
        CGContextRef context = QLPreviewRequestCreateContext(preview, CGSizeMake(CGImageGetWidth(thePreview), CGImageGetHeight(thePreview)), true,
                                                             (__bridge CFDictionaryRef) @{(NSString *) kQLPreviewPropertyDisplayNameKey: title});
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
