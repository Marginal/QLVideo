//
//  ThumbnailProvider.h
//  thumbnailer
//
//  Created by Jonathan Harris on 06/04/2021.
//

#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

// Undocumented property
typedef NS_ENUM(NSInteger, QLThumbnailIconFlavor)
{
    kQLThumbnailIconPlainFlavor         = 0,
    kQLThumbnailIconRoundedFlavor       = 1,
    kQLThumbnailIconBookFlavor          = 2,
    kQLThumbnailIconMovieFlavor         = 3,
    kQLThumbnailIconAddressFlavor       = 4,
    kQLThumbnailIconImageFlavor         = 5,
    kQLThumbnailIconGlossFlavor         = 6,
    kQLThumbnailIconSlideFlavor         = 7,
    kQLThumbnailIconSquareFlavor        = 8,
    kQLThumbnailIconBorderFlavor        = 9,
    kQLThumbnailIconSquareBorderFlavor  = 10,
    kQLThumbnailIconCalendarFlavor      = 11,
    kQLThumbnailIconGridFlavor          = 12,
};

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(macos(10.15))
@interface ThumbnailProvider : QLThumbnailProvider
@end

NS_ASSUME_NONNULL_END
