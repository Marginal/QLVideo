//
//  formatreader-bridge.h
//  QLVideo
//
//  Created by Jonathan Harris on 17/11/2025.
//

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>

// FFmpeg internals
#include <libavutil/pixdesc.h>
#include <libswresample/swresample_internal.h> // for SwrContext

// this project
#include "callbacks.h"
