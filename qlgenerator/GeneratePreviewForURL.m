#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>

#include <sys/stat.h>
#include <sys/malloc.h>

#include "generator.h"
#import "Snapshotter.h"
#import "Player.h"


// Undocumented options
const CFStringRef kQLPreviewOptionModeKey = CFSTR("QLPreviewMode");
const CFStringRef kQLPreviewPropertyPageElementXPathKey = CFSTR("PageElementXPath");


typedef NS_ENUM(NSInteger, QLPreviewMode)
{
    kQLPreviewNoMode		= 0,
    kQLPreviewGetInfoMode	= 1,	// File -> Get Info and Column view in Finder
    kQLPreviewCoverFlowMode	= 2,	// Finder's Cover Flow view
    kQLPreviewSpotlightMode	= 4,	// Desktop Spotlight search popup bubble
    kQLPreviewQuicklookMode	= 5,	// File -> Quick Look in Finder (also qlmanage -p)
    // From 10.13 High Sierra:
    kQLPreviewHSQuicklookMode	= 6,	// File -> Quick Look in Finder
    kQLPreviewHSSpotlightMode	= 9,	// Desktop Spotlight search context bubble
};


// Limit contact sheet to 4K to try to avoid breaking QuickLook's memory limit
static const int kMaxWidth = 3840;
static const int kMaxHeight = 2160;


OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

// Window title
NSString* displayname(CFBundleRef bundle, NSString *title, CGSize size, NSInteger duration, int channels)
{
    NSString *channelstring;
    NSString *ret;

    switch (channels)
    {
        case 0:
            channelstring = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("🔇"),     NULL, bundle, "Audio channel info in Preview window title")); break;
        case 1:
            channelstring = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("mono"),   NULL, bundle, "Audio channel info in Preview window title")); break;
        case 2:
            channelstring = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("stereo"), NULL, bundle, "Audio channel info in Preview window title")); break;
        case 6:
            channelstring = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("5.1"),    NULL, bundle, "Audio channel info in Preview window title")); break;
        case 7:
            channelstring = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("6.1"),    NULL, bundle, "Audio channel info in Preview window title")); break;
        case 8:
            channelstring = CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("7.1"),    NULL, bundle, "Audio channel info in Preview window title")); break;
        default:    // Quadraphonic, LCRS or something else
            channelstring = [NSString stringWithFormat:CFBridgingRelease(CFCopyLocalizedStringFromTableInBundle(CFSTR("%d🔉"), NULL, bundle, "Audio channel info in Preview window title")), channels];
    }

    // Format duration like Finder (NSDateComponentsFormatter doesn't seem to be able to do this)
    if (duration <= 0)
        ret = [NSString stringWithFormat:@"%@ (%d×%d, %@)", title, (int) size.width, (int) size.height, channelstring];
    else if (duration < 60)
        ret = [NSString stringWithFormat:@"%@ (%d×%d, %@, 00:%02ld)", title, (int) size.width, (int) size.height, channelstring, duration];
    else if (duration < 3600)
        ret = [NSString stringWithFormat:@"%@ (%d×%d, %@, %02ld:%02ld)", title, (int) size.width, (int) size.height, channelstring, duration / 60, duration % 60];
    else
        ret = [NSString stringWithFormat:@"%@ (%d×%d, %@, %02ld:%02ld:%02ld)", title, (int) size.width, (int) size.height, channelstring, duration / 3600, (duration / 60) % 60, duration % 60];

    return ret;
}


/* -----------------------------------------------------------------------------
   Generate a preview for file

   This function's job is to create preview for designated file
   ----------------------------------------------------------------------------- */

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    // https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLImplementationOverview.html

    @autoreleasepool
    {
        os_log_info(logger, "Preview with options=%{public}@ UTI=%{public}@ for %{public}@", options, contentTypeUTI, [(__bridge NSURL*)url path]);
        Snapshotter *snapshotter = nil;

        // Prefer any cover art (if present) over a playable preview or static snapshot in Finder and Spotlight views
        QLPreviewMode previewMode = [((__bridge NSDictionary *)options)[(__bridge NSString *) kQLPreviewOptionModeKey] intValue];
        if (previewMode == kQLPreviewGetInfoMode || previewMode == kQLPreviewSpotlightMode || previewMode == kQLPreviewHSSpotlightMode)
        {
            snapshotter = [[Snapshotter alloc] initWithURL:url];
            if (!snapshotter || QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;

            CGImageRef cover = [snapshotter newCoverArtWithMode:CoverArtDefault];
            if (cover)
            {
                CGSize coversize = CGSizeMake(CGImageGetWidth(cover), CGImageGetHeight(cover));
                os_log_info(logger, "Supplying %dx%d cover art for %{public}@", (int) coversize.width, (int) coversize.height, [(__bridge NSURL*)url path]);
                CGContextRef context = QLPreviewRequestCreateContext(preview, coversize, true, nil);
                CGContextDrawImage(context, CGRectMake(0, 0, coversize.width, coversize.height), cover);
                QLPreviewRequestFlushContext(preview, context);
                CGContextRelease(context);
                CGImageRelease(cover);
                return kQLReturnNoError;    // early exit
            }
        }

        // If AVFoundation can play it, then hand it off to
        // /System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/Movie.qldisplay
        // On Catalina and later QuickLook only hands off UTIs to us that AVFoundation definitely can't handle.
        if (QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;
        CFBundleRef myBundle = QLPreviewRequestGetGeneratorBundle(preview);
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSettingsSuiteName];
        os_log_debug(logger, "QLvideo preview defaults=%@", defaults);
        os_log_debug(logger, "QLvideo preview SnapshoCount=%ld", (long)[defaults integerForKey:kSettingsSnapshotCount]);

        if (![defaults boolForKey:kSettingsSnapshotAlways])
            @autoreleasepool    // Reduce peak footprint
        {
            Player *player = [Player playerWithURL:(__bridge NSURL *)url];

            if (player.playable)
            {
                os_log_info(logger, "Handing off %{public}@ to AVFoundation", [(__bridge NSURL*)url path]);
                NSString *title = [player title];
                if (!title)
                    title = [(__bridge NSURL *)url lastPathComponent];
                NSDictionary *properties = @{(NSString *) kQLPreviewPropertyDisplayNameKey: displayname(myBundle, title, player.displaySize, player.duration, player.channels)};
                QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, (__bridge CFDictionaryRef) properties);
                return kQLReturnNoError;    // early exit
            }

            // kQLPreviewCoverFlowMode is broken for "non-native" files on Mavericks - the user gets a blank window
            // if they invoke QuickLook soon after. Presumably QuickLookUI is caching and getting confused?
            // If we return nothing we get called again with no QLPreviewMode option. This somehow forces QuickLookUI to
            // correctly call us with kQLPreviewQuicklookMode when the user later invokes QuickLook. What a crock.
            if (brokenQLCoverFlow && previewMode == kQLPreviewCoverFlowMode)
                return kQLReturnNoError;    // early exit

            if (QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;
        }   // Free AVFoundation resources before proceeding

        // AVFoundation/QTKit can't play it
        if (!snapshotter)
        {
            snapshotter = [[Snapshotter alloc] initWithURL:url];
            if (!snapshotter || QLPreviewRequestIsCancelled(preview)) return kQLReturnNoError;
        }

        // Replace title string
        NSString *title = [snapshotter title];
        if (!title)
            title = [(__bridge NSURL *)url lastPathComponent];
        NSString *theTitle = displayname(myBundle, title, snapshotter.displaySize, snapshotter.duration, snapshotter.channels);

        // prefer landscape cover art (if present) over a static snapshot
        if (previewMode != kQLPreviewGetInfoMode && previewMode != kQLPreviewSpotlightMode && previewMode != kQLPreviewHSSpotlightMode)
        {
            CGImageRef cover = [snapshotter newCoverArtWithMode:CoverArtLandscape];
            if (cover)
            {
                CGSize coversize = CGSizeMake(CGImageGetWidth(cover), CGImageGetHeight(cover));
                os_log_info(logger, "Supplying %dx%d cover art for %{public}@", (int) coversize.width, (int) coversize.height, [(__bridge NSURL*)url path]);
                NSDictionary *properties = @{(NSString *) kQLPreviewPropertyDisplayNameKey: theTitle};
                CGContextRef context = QLPreviewRequestCreateContext(preview, coversize, true, (__bridge CFDictionaryRef) properties);
                CGContextDrawImage(context, CGRectMake(0, 0, coversize.width, coversize.height), cover);
                QLPreviewRequestFlushContext(preview, context);
                CGContextRelease(context);
                CGImageRelease(cover);
                return kQLReturnNoError;    // early exit
            }
        }

        CGSize size = [snapshotter previewSize];

        // How many images should we generate?
        NSInteger desired_image_count = [defaults integerForKey:kSettingsSnapshotCount];
        if (desired_image_count <= 0 || desired_image_count >= kMaxSnapshotCount)
            desired_image_count = kDefaultSnapshotCount;

        NSInteger duration = [snapshotter duration];
        int image_count;
        if ([snapshotter pictures])
        {
            // "best" video stream is pre-computed pictures
            image_count = [snapshotter pictures];
            if (image_count >= kMaxSnapshotCount)
                image_count = kMaxSnapshotCount;

            // AV_DISPOSITION_TIMED_THUMBNAILS is undocumented and semantics are unclear.
            // Appears that the first thumbnail is duplicated in the stream, so read and discard.
            if (image_count > 1)
                [snapshotter newSnapshotWithSize:CGSizeMake(0,0) atTime:-1];
        }
        else
        {
            image_count = duration <= 0 ? 0 : (int) (duration / kMinimumPeriod) - 1;
            if (image_count > desired_image_count)
                image_count = (int) desired_image_count;
        }

        // Generate a contact sheet
        if ((previewMode == kQLPreviewNoMode || previewMode == kQLPreviewQuicklookMode || previewMode == kQLPreviewHSQuicklookMode) && image_count > 1)
        {
            NSString *html = @"<!DOCTYPE html>\n<html>\n<body style=\"background-color:black\">\n";
            NSMutableDictionary *attachments =[NSMutableDictionary dictionaryWithCapacity:image_count];

            // Use inode # to uniquify snapshot names, otherwise QuickLook can confuse them
            struct stat st;
            int64_t inode = 0;
            if (!stat([(__bridge NSURL *) url fileSystemRepresentation], &st))
                inode = st.st_ino;

            CGSize scaled;
            if (size.width <= kMaxWidth && size.height <= kMaxHeight)
                scaled = size;
            else if (size.width/kMaxWidth > size.height/kMaxHeight)
                scaled = CGSizeMake(kMaxWidth, round(size.height * kMaxWidth / size.width));
            else
                scaled = CGSizeMake(round(size.width * kMaxHeight / size.height), kMaxHeight);

            for (int i=0; i < image_count; i++)
            {
                if (QLPreviewRequestIsCancelled(preview))
                    return kQLReturnNoError;

                CFDataRef png = [snapshotter newPNGWithSize:scaled atTime:(duration * (i + 1)) / (image_count + 1)];
                if (!png && !i)
                    png = [snapshotter newPNGWithSize:scaled atTime:0];  // Failed on first frame. Try again at start.
                if (!png)
                    break;
                html = [html stringByAppendingFormat:@"<div><img src=\"cid:%lld/%03d.png\" width=\"%d\" height=\"%d\"/></div>\n", inode, i, (int) scaled.width, (int) scaled.height];
                [attachments setObject:@{(NSString *) kQLPreviewPropertyMIMETypeKey: @"image/png",
                                         (NSString *) kQLPreviewPropertyAttachmentDataKey: (__bridge NSData *) png}
                                forKey:[NSString stringWithFormat:@"%lld/%03d.png", inode, i]];
                CFRelease(png);
            }

            html = [html stringByAppendingString:@"</body>\n</html>\n"];
            NSDictionary *properties = @{(NSString *) kQLPreviewPropertyDisplayNameKey: theTitle,
                                         (NSString *) kQLPreviewPropertyTextEncodingNameKey: @"UTF-8",
                                         (__bridge NSString *) kQLPreviewPropertyPageElementXPathKey: @"/html/body/div",
                                         (NSString *) kQLPreviewPropertyPDFStyleKey: @(kQLPreviewPDFPagesWithThumbnailsOnLeftStyle),
                                         (NSString *) kQLPreviewPropertyAttachmentsKey: attachments};
            os_log_info(logger, "Supplying %lu %dx%d images for %{public}@", [properties[(NSString *) kQLPreviewPropertyAttachmentsKey] count], (int) scaled.width, (int) scaled.height, [(__bridge NSURL*)url path]);
            QLPreviewRequestSetDataRepresentation(preview, (__bridge CFDataRef) [html dataUsingEncoding:NSUTF8StringEncoding], kUTTypeHTML,
                                                  (__bridge CFDictionaryRef) properties);
            return kQLReturnNoError;    // early exit
        }

        // Fall back to generating a single snapshot
        NSInteger snapshot_time = [defaults integerForKey:kSettingsSnapshotTime];
        if (snapshot_time <= 0)
            snapshot_time = kDefaultSnapshotTime;
        NSInteger time = duration < kMinimumDuration ? -1 : (duration < 2 * snapshot_time ? duration/2 : snapshot_time);
        CGImageRef thePreview = [snapshotter newSnapshotWithSize:size atTime:time];
        if (!thePreview && time > 0)
            thePreview = [snapshotter newSnapshotWithSize:size atTime:0];    // Failed. Try again at start.
        if (thePreview)
        {
            CGSize size = CGSizeMake(CGImageGetWidth(thePreview), CGImageGetHeight(thePreview));
# if 0  // Make small image for running with no OpenGL acceleration (e.g. under virtualisation) to avoid QuickLookUIHelper timing out
            const int kMaxWidth = 640;
            const int kMaxHeight = 480;
            CGSize original = CGSizeMake(CGImageGetWidth(thePreview), CGImageGetHeight(thePreview));
            if (original.width <= kMaxWidth && original.height <= kMaxHeight)
                ;
            else if (original.width/kMaxWidth > original.height/kMaxHeight)
                size = CGSizeMake(kMaxWidth, round(original.height * kMaxWidth / original.width));
            else
                size = CGSizeMake(round(original.width * kMaxHeight / original.height), kMaxHeight);
# endif
            os_log_info(logger, "Supplying %dx%d image for %{public}@", (int) size.width, (int) size.height, [(__bridge NSURL*)url path]);
            NSDictionary *properties = @{(NSString *) kQLPreviewPropertyDisplayNameKey: theTitle};
            CGContextRef context = QLPreviewRequestCreateContext(preview, size, true, (__bridge CFDictionaryRef) properties);
            CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), thePreview);
            QLPreviewRequestFlushContext(preview, context);
            CGContextRelease(context);
            CGImageRelease(thePreview);
        }
        else
        {
            os_log_error(logger, "Can't supply anything for %@", [(__bridge NSURL*)url path]);
        }
    }
    return kQLReturnNoError;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
    // Implement only if supported
}
