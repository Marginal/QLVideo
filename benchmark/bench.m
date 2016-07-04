//
//
//  bench.m
//  QLVideo
//
//  Run core snapshot generation code. Useful for benchmarking various ffmpeg builds.
//
//

#import <Quartz/Quartz.h>
#import <Cocoa/Cocoa.h>

#include "snapshotter.h"


static const int kMinimumPeriod = 60;
static const int kSnapshotCount = 10;
static const int kSnapshotTime  = 60;

int main(int argc, char *argv[])
{
    @autoreleasepool {

        av_log_set_level(AV_LOG_ERROR|AV_LOG_SKIP_REPEATED);
        av_register_all();

        CFURLRef url;
        if (argc != 2 || !(url = CFURLCreateWithFileSystemPath(NULL, CFStringCreateWithBytes(NULL, (UInt8*) argv[1], strlen(argv[1]), kCFStringEncodingUTF8, false), kCFURLPOSIXPathStyle , false)))
        {
            printf("Usage:\t%s [video file]\n", argv[0]);
            exit(1);
        }

        int loop, image_count = 0;
        Snapshotter *snapshotter;

        for (loop = 0; loop < 100; loop++)
        {
            snapshotter = [[Snapshotter alloc] initWithURL:url];
            if (!snapshotter)
            {
                printf("Can't read %s\n", [(__bridge NSURL *) url fileSystemRepresentation]);
                exit(1);
            }

            CGSize size = [snapshotter displaySize];
            NSInteger duration = [snapshotter duration];
            image_count = duration <= 0 ? 0 : (int) (duration / kMinimumPeriod) - 1;
            if (image_count > kSnapshotCount)
                image_count = kSnapshotCount;
            if (image_count < 1)
                image_count = 1;

            for (int i = 0; i < image_count; i++)
            {
                NSInteger time = image_count > 1 ? (duration * (i + 1)) / (image_count + 1) : (duration < 2 * kSnapshotTime ? duration/2 : kSnapshotTime);
#if 0   // Generate PNG from CGImageRef
                CGImageRef snapshot = [snapshotter newSnapshotWithSize:size atTime:time];
                if (!snapshot)
                {
                    printf("Can't generate image #%d at time %lds\n", i, (long) time);
                    exit(1);
                }
                CFMutableDataRef png = CFDataCreateMutable(NULL, 0);
                CGImageDestinationRef destination = CGImageDestinationCreateWithData(png, kUTTypePNG, 1, NULL);
                CGImageDestinationAddImage(destination, snapshot, nil);
                if (!CGImageDestinationFinalize(destination))
                {
                    printf("Can't generate PNG #%d at time %lds\n", i, (long) time);
                    exit(1);
                }
                CFRelease(destination);
                CFRelease(png);
                CGImageRelease(snapshot);
#else   // Generate PNG directly
                CFDataRef png = [snapshotter newPNGWithSize:size atTime:time];
                if (!png)
                {
                    printf("Can't generate PNG #%d at time %lds\n", i, (long) time);
                    exit(1);
                }
                CFRelease(png);
#endif
            }
        }

        printf ("Generated %dx%d snapshots at %dx%d\n", loop, image_count, (int) [snapshotter displaySize].width, (int) [snapshotter displaySize].height);
    }
    return 0;
}
