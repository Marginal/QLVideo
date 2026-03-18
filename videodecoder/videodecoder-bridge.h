//
//  videodecoder-bridge.h
//  QLVideo
//
//  Created by Jonathan Harris on 17/11/2025.
//

#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <libavutil/hdr_dynamic_vivid_metadata.h>

// FFmpeg internals
#include <libavutil/pixdesc.h>
#include <libavutil/hwcontext_videotoolbox.h>

// this project
#include "callbacks.h"
