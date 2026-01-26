//
//  formatreaderfactory.swift
//  QLVideo
//
//  Created by Jonathan Harris on 17/11/2025.
//

import Foundation
import MediaExtension
import OSLog

let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "formatreader")

class FormatReaderFactory: NSObject, MEFormatReaderExtension {

    required override init() {
        super.init()
        // Send FFmpeg logs to system log
        #if DEBUG
            logger.debug("FormatReaderFactory init")
            av_log_set_level(AV_LOG_DEBUG | AV_LOG_SKIP_REPEATED)
        #else
            av_log_set_level(AV_LOG_WARNING | AV_LOG_SKIP_REPEATED)
        #endif
        setup_av_log_callback()
        #if DEBUG
            // AVFoundation supported content
            logger.log("audiovisualMIMETypes: \(AVURLAsset.audiovisualMIMETypes(), privacy: .public)")
            if #available(macOS 26.0, *) {
                let ext = AVURLAsset.audiovisualContentTypes.map { $0.preferredFilenameExtension ?? "?" }
                logger.log("audiovisualContentTypes: \(ext, privacy: .public)")
            } else {
                logger.log("audiovisualTypes: \(AVURLAsset.audiovisualTypes(), privacy: .public)")
            }
        #endif
    }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws
        -> any MEFormatReader
    {
        //let err = AVERROR(errorCode: -0x2bb2afa8, context: "test", file: primaryByteSource.fileName)
        //logger.critical("testing error: \(err), \(err.localizedDescription, privacy: .public)")
        #if DEBUG
            let identifier: String = primaryByteSource.contentType?.identifier ?? "unknown"
            logger.debug(
                "FormatReaderFactory formatReader \(primaryByteSource.fileName, privacy:.public) \(identifier, privacy:.public)"
            )
        #endif  // DEBUG
        return FormatReader(primaryByteSource: primaryByteSource)
    }
}
