//
//  videodecoder.swift
//
//  Created by Jonathan Harris on 21/01/2026.
//

import Foundation
import MediaExtension
import OSLog

let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "videodecoder")

class VideoDecoderFactory: NSObject, MEVideoDecoderExtension {

    required override init() {
        super.init()
        // Send FFmpeg logs to system log
        #if DEBUG
            logger.debug("VideoDecoderFactory init")
            av_log_set_level(AV_LOG_DEBUG | AV_LOG_SKIP_REPEATED)
        #else
            av_log_set_level(AV_LOG_WARNING | AV_LOG_SKIP_REPEATED)
        #endif
        setup_av_log_callback()
    }

    func makeVideoDecoder(
        codecType: CMVideoCodecType,
        videoFormatDescription: CMVideoFormatDescription,
        videoDecoderSpecifications: [String: Any],
        pixelBufferManager extensionDecoderPixelBufferManager: MEVideoDecoderPixelBufferManager
    ) throws -> any MEVideoDecoder {
        #if DEBUG
            logger.debug(
                "VideoDecoderFactory makeVideoDecoder format:\(String(describing: videoFormatDescription), privacy:.public) specifications:\(videoDecoderSpecifications, privacy:.public)"
            )
        #endif  // DEBUG
        return try VideoDecoder(
            codecType: codecType,
            videoFormatDescription: videoFormatDescription,
            videoDecoderSpecifications: videoDecoderSpecifications,
            pixelBufferManager: extensionDecoderPixelBufferManager
        )
    }
}

