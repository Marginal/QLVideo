//==============================================================================
//
//	DO NO MODIFY THE CONTENT OF THIS FILE
//
//	This file contains the generic CFPlug-in code necessary for your generator
//	To complete your generator implement the function in GenerateThumbnailForURL/GeneratePreviewForURL.c
//
//==============================================================================


#import <Cocoa/Cocoa.h>
#import <QuickLook/QuickLook.h>

#include <signal.h>
#include <dlfcn.h>

#include "libavformat/avformat.h"
#include "libavutil/log.h"

#include "generator.h"


// -----------------------------------------------------------------------------
//	constants
// -----------------------------------------------------------------------------

// Don't modify this line
#define PLUGIN_ID "4A60E117-F6DF-4B3C-9603-2BBE6CEC6972"

// Settings
NSString * const kSettingsSuiteName     = @"uk.org.marginal.qlvideo";
NSString * const kSettingsSnapshotCount = @"SnapshotCount";     // Max number of snapshots generated in Preview mode.
NSString * const kSettingsSnapshotTime  = @"SnapshotTime";      // Seek offset for thumbnails and single Previews [s].
NSString * const kSettingsSnapshotAlways= @"SnapshotAlways";    // Whether to generate static snapshot(s) even if playable Preview is available.

// Setting defaults
const int kDefaultSnapshotTime = 60;    // CoreMedia generator appears to use 10s. Completely arbitrary.
const int kDefaultSnapshotCount = 10;   // 7-14 fit in the left bar of the Preview window without scrolling, depending on the display vertical resolution.

// Implementation
const int kMinimumDuration = 5;         // Don't bother seeking clips shorter than this [s]. Completely arbitrary.
const int kMinimumPeriod = 60;          // Don't create snapshots spaced more closely than this [s]. Completely arbitrary.

extern int QLMemoryUsedCritical;        // From QuickLook framework
static const int kSatelliteMemory = 150 * 1024 * 1024; // Memory threshold for our QuickLookSatellite process

// Globals
BOOL brokenQLCoverFlow;
BOOL hackedQLDisplay;


//
// Below is the generic glue code for all plug-ins.
//
// You should not have to modify this code aside from changing
// names if you decide to change the names defined in the Info.plist
//


// -----------------------------------------------------------------------------
//	typedefs
// -----------------------------------------------------------------------------

// The thumbnail generation function to be implemented in GenerateThumbnailForURL.c
OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void* thisInterface, QLThumbnailRequestRef thumbnail);

// The preview generation function to be implemented in GeneratePreviewForURL.c
OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

// The layout for an instance of QuickLookGeneratorPlugIn
typedef struct __QuickLookGeneratorPluginType
{
    void        *conduitInterface;
    CFUUIDRef    factoryID;
    UInt32       refCount;
} QuickLookGeneratorPluginType;

// -----------------------------------------------------------------------------
//	prototypes
// -----------------------------------------------------------------------------
//	Forward declaration for the IUnknown implementation.
//

QuickLookGeneratorPluginType  *AllocQuickLookGeneratorPluginType(CFUUIDRef inFactoryID);
void                         DeallocQuickLookGeneratorPluginType(QuickLookGeneratorPluginType *thisInstance);
HRESULT                      QuickLookGeneratorQueryInterface(void *thisInstance,REFIID iid,LPVOID *ppv);
void                        *QuickLookGeneratorPluginFactory(CFAllocatorRef allocator,CFUUIDRef typeID);
ULONG                        QuickLookGeneratorPluginAddRef(void *thisInstance);
ULONG                        QuickLookGeneratorPluginRelease(void *thisInstance);

// -----------------------------------------------------------------------------
//	myInterfaceFtbl	definition
// -----------------------------------------------------------------------------
//	The QLGeneratorInterfaceStruct function table.
//
static QLGeneratorInterfaceStruct myInterfaceFtbl = {
    NULL,
    QuickLookGeneratorQueryInterface,
    QuickLookGeneratorPluginAddRef,
    QuickLookGeneratorPluginRelease,
    NULL,
    NULL,
    NULL,
    NULL
};


void segv_handler(int signum)
{
    char *sCrashReporterInfo = dlsym(RTLD_DEFAULT, "__crashreporter_info__");

    if (sCrashReporterInfo && *sCrashReporterInfo)
        NSLog(@"Video.qlgenerator crashed: %s", sCrashReporterInfo);
    else
        NSLog(@"Video.qlgenerator crashed!");
    
    exit(EXIT_FAILURE);
}


// -----------------------------------------------------------------------------
//	AllocQuickLookGeneratorPluginType
// -----------------------------------------------------------------------------
//	Utility function that allocates a new instance.
//      You can do some initial setup for the generator here if you wish
//      like allocating globals etc...
//
QuickLookGeneratorPluginType *AllocQuickLookGeneratorPluginType(CFUUIDRef inFactoryID)
{
#ifndef DEBUG
    // Install a handler to kill the QuickLookSatellite process quietly on a crash so the user isn't alarmed by a crash report.
    struct sigaction sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    sa.sa_handler = segv_handler;
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);

    av_log_set_level(AV_LOG_FATAL|AV_LOG_SKIP_REPEATED);
#else
    av_log_set_level(AV_LOG_INFO |AV_LOG_SKIP_REPEATED);
#endif
    av_register_all();

    // Plugin intitialisation
    NSOperatingSystemVersion yosemite = { 10, 10, 0 };
    brokenQLCoverFlow = (!([[NSProcessInfo processInfo] respondsToSelector:@selector(isOperatingSystemAtLeastVersion:)] &&
                           [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:yosemite]));

    hackedQLDisplay = [[[[NSFileManager defaultManager] attributesOfItemAtPath:@"/System/Library/Frameworks/Quartz.framework/Frameworks/QuickLookUI.framework/PlugIns/Movie.qldisplay" error:nil] objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink];

    // Hack! Give our process enough memory to handle 4K H.265 content
    if (QLMemoryUsedCritical && QLMemoryUsedCritical < kSatelliteMemory)
        QLMemoryUsedCritical = kSatelliteMemory;

    /* the rest of this function is standard boilderplate */
    QuickLookGeneratorPluginType *theNewInstance;

    theNewInstance = (QuickLookGeneratorPluginType *)malloc(sizeof(QuickLookGeneratorPluginType));
    memset(theNewInstance,0,sizeof(QuickLookGeneratorPluginType));

    /* Point to the function table Malloc enough to store the stuff and copy the filler from myInterfaceFtbl over */
    theNewInstance->conduitInterface = malloc(sizeof(QLGeneratorInterfaceStruct));
    memcpy(theNewInstance->conduitInterface,&myInterfaceFtbl,sizeof(QLGeneratorInterfaceStruct));

    /*  Retain and keep an open instance refcount for each factory. */
    theNewInstance->factoryID = CFRetain(inFactoryID);
    CFPlugInAddInstanceForFactory(inFactoryID);

    /* This function returns the IUnknown interface so set the refCount to one. */
    theNewInstance->refCount = 1;
    return theNewInstance;
}

// -----------------------------------------------------------------------------
//	DeallocQuickLookGeneratorPluginType
// -----------------------------------------------------------------------------
//	Utility function that deallocates the instance when
//	the refCount goes to zero.
//      In the current implementation generator interfaces are never deallocated
//      but implement this as this might change in the future
//
void DeallocQuickLookGeneratorPluginType(QuickLookGeneratorPluginType *thisInstance)
{
    CFUUIDRef theFactoryID;

    theFactoryID = thisInstance->factoryID;
        /* Free the conduitInterface table up */
    free(thisInstance->conduitInterface);

        /* Free the instance structure */
    free(thisInstance);
    if (theFactoryID){
        CFPlugInRemoveInstanceForFactory(theFactoryID);
        CFRelease(theFactoryID);
    }
}

// -----------------------------------------------------------------------------
//	QuickLookGeneratorQueryInterface
// -----------------------------------------------------------------------------
//	Implementation of the IUnknown QueryInterface function.
//
HRESULT QuickLookGeneratorQueryInterface(void *thisInstance,REFIID iid,LPVOID *ppv)
{
    CFUUIDRef interfaceID;

    interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault,iid);

    if (CFEqual(interfaceID,kQLGeneratorCallbacksInterfaceID)){
            /* If the Right interface was requested, bump the ref count,
             * set the ppv parameter equal to the instance, and
             * return good status.
             */
        ((QLGeneratorInterfaceStruct *)((QuickLookGeneratorPluginType *)thisInstance)->conduitInterface)->GenerateThumbnailForURL = GenerateThumbnailForURL;
        ((QLGeneratorInterfaceStruct *)((QuickLookGeneratorPluginType *)thisInstance)->conduitInterface)->CancelThumbnailGeneration = CancelThumbnailGeneration;
        ((QLGeneratorInterfaceStruct *)((QuickLookGeneratorPluginType *)thisInstance)->conduitInterface)->GeneratePreviewForURL = GeneratePreviewForURL;
        ((QLGeneratorInterfaceStruct *)((QuickLookGeneratorPluginType *)thisInstance)->conduitInterface)->CancelPreviewGeneration = CancelPreviewGeneration;
        ((QLGeneratorInterfaceStruct *)((QuickLookGeneratorPluginType*)thisInstance)->conduitInterface)->AddRef(thisInstance);
        *ppv = thisInstance;
        CFRelease(interfaceID);
        return S_OK;
    }else{
        /* Requested interface unknown, bail with error. */
        *ppv = NULL;
        CFRelease(interfaceID);
        return E_NOINTERFACE;
    }
}

// -----------------------------------------------------------------------------
// QuickLookGeneratorPluginAddRef
// -----------------------------------------------------------------------------
//	Implementation of reference counting for this type. Whenever an interface
//	is requested, bump the refCount for the instance. NOTE: returning the
//	refcount is a convention but is not required so don't rely on it.
//
ULONG QuickLookGeneratorPluginAddRef(void *thisInstance)
{
    ((QuickLookGeneratorPluginType *)thisInstance )->refCount += 1;
    return ((QuickLookGeneratorPluginType*) thisInstance)->refCount;
}

// -----------------------------------------------------------------------------
// QuickLookGeneratorPluginRelease
// -----------------------------------------------------------------------------
//	When an interface is released, decrement the refCount.
//	If the refCount goes to zero, deallocate the instance.
//
ULONG QuickLookGeneratorPluginRelease(void *thisInstance)
{
    ((QuickLookGeneratorPluginType*)thisInstance)->refCount -= 1;
    if (((QuickLookGeneratorPluginType*)thisInstance)->refCount == 0){
        DeallocQuickLookGeneratorPluginType((QuickLookGeneratorPluginType*)thisInstance );
        return 0;
    }else{
        return ((QuickLookGeneratorPluginType*) thisInstance )->refCount;
    }
}

// -----------------------------------------------------------------------------
//  QuickLookGeneratorPluginFactory
// -----------------------------------------------------------------------------
void *QuickLookGeneratorPluginFactory(CFAllocatorRef allocator,CFUUIDRef typeID)
{
    QuickLookGeneratorPluginType *result;
    CFUUIDRef                 uuid;

        /* If correct type is being requested, allocate an
         * instance of kQLGeneratorTypeID and return the IUnknown interface.
         */
    if (CFEqual(typeID,kQLGeneratorTypeID)){
        uuid = CFUUIDCreateFromString(kCFAllocatorDefault,CFSTR(PLUGIN_ID));
        result = AllocQuickLookGeneratorPluginType(uuid);
        CFRelease(uuid);
        return result;
    }
        /* If the requested type is incorrect, return NULL. */
    return NULL;
}

