//
//  formatreader-bridge.h
//  QLVideo
//

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>

// FFmpeg internals
#include <libavutil/pixdesc.h>
#include <libswresample/swresample_internal.h> // for SwrContext

// this project
#include "callbacks.h"
