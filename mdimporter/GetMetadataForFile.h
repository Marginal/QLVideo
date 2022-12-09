//
//  GetMetadataForFile.h
//  QLVideo
//
//  Created by Jonathan Harris on 09/12/2022.
//

#ifndef GetMetadataForFile_h
#define GetMetadataForFile_h

#include <os/log.h>

#include "libavformat/avformat.h"
#include "libavutil/log.h"

#ifndef DEBUG
#include <pthread.h>
#include <signal.h>
#endif

#import <Cocoa/Cocoa.h>

extern os_log_t logger;

#endif /* GetMetadataForFile_h */
