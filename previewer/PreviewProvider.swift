//
//  PreviewProvider.swift
//  previewer
//
//  Created by Jonathan Harris on 05/01/2025.
//


import Cocoa
import Quartz
import OSLog

// Settings
var kSettingsSnapshotTime  = "SnapshotTime";      // Seek offset for thumbnails and single Previews [s].

// Constants
var kDefaultSnapshotTime = 60
var kDefaultSnapshotCount = 10
var kMinimumDuration = 5       // Don't bother seeking clips shorter than this [s].
var kMinimumPeriod = 60        // Don't create snapshots spaced more closely than this [s].


class PreviewProvider: QLPreviewProvider, QLPreviewingController {


    /*
     Use a QLPreviewProvider to provide data-based previews.
     
     To set up your extension as a data-based preview extension:

     - Modify the extension's Info.plist by setting
       <key>QLIsDataBasedPreview</key>
       <true/>
     
     - Add the supported content types to QLSupportedContentTypes array in the extension's Info.plist.

     - Change the NSExtensionPrincipalClass to this class.
       e.g.
       <key>NSExtensionPrincipalClass</key>
       <string>$(PRODUCT_MODULE_NAME).PreviewProvider</string>
     
     - Implement providePreview(for:)
     */
    var logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "previewer")

    // Window title
    func displayname(title:String, size:CGSize, duration:Int, channels:Int) -> String
    {
        var channelstring:String

        switch (channels)
        {
            case 0:
            channelstring = String(localized: "🔇")
            case 1:
            channelstring = String(localized: "mono")
            case 2:
            channelstring = String(localized: "stereo")
            case 6:
            channelstring = String(localized: "5.1")
            case 7:
            channelstring = String(localized: "6.1")
            case 8:
            channelstring = String(localized: "7.1")
            default:    // Quadraphonic, LCRS or something else
            channelstring = String(localized: "\(channels)🔉")
        }

        if (duration <= 0) {
            return "\(title) (\(Int(size.width))×\(Int(size.height)), \(channelstring))"
        }
        else if (duration < 60) {
            return "\(title) (\(Int(size.width))×\(Int(size.height)), \(channelstring), 0:\(duration))"
        }
        else {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .positional
            formatter.allowedUnits = [.hour, .minute, .second]
            return "\(title) (\(Int(size.width))×\(Int(size.height)), \(channelstring), \(formatter.string(from:TimeInterval(duration)) ?? ""))"
        }
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {

        //You can create a QLPreviewReply in several ways, depending on the format of the data you want to return.
        //To return Data of a supported content type:

        guard let snapshotter = Snapshotter.init(url: request.fileURL as CFURL) else {
#if DEBUG
            logger.info("providePreview failed to load \(request.fileURL.path, privacy:.public)")
#else
            logger.info("providePreview failed to load \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif
            throw NSError()
        }
#if DEBUG
        logger.info("providePreview \(request.fileURL.path, privacy:.public)")
#else
        logger.info("providePreview \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif


        var image_count:Int
        if (snapshotter.pictures > 0) {
            // "best" video stream is pre-computed pictures e.g. chapter markers in encrypted movies
            image_count = Int(snapshotter.pictures) > kDefaultSnapshotCount ? kDefaultSnapshotCount : Int(snapshotter.pictures)
        } else if (snapshotter.duration <= 0) {
            image_count = 0
        } else if (snapshotter.duration <= kMinimumPeriod) {
            image_count = 1
        } else {
            image_count = Int(snapshotter.duration / kMinimumPeriod) - 1
            if (image_count > kDefaultSnapshotCount) {
                image_count = kDefaultSnapshotCount
            }
        }

        // Generate a contact sheet
        let coverdata = snapshotter.dataCoverArt(with:.landscape)
#if false
        if (image_count > 1 || (image_count > 0 && coverdata != nil)) {
            let reply = QLPreviewReply(dataOfContentType: .html,
                                       contentSize: snapshotter.previewSize) { [self, snapshotter] replyToUpdate in
                var content = "<html>\n<head></head>\n<body style=\"background-color:black\">\n"
                // Use inode # to uniquify snapshot names, since (older?) QuickLook can confuse them
                let inode:Int = (try? FileManager.default.attributesOfItem(atPath:request.fileURL.path)[.systemFileNumber] as? Int) ?? 0
                if let coverdata {
#if DEBUG
                    logger.info("Supplying sheet with cover art for \(request.fileURL.path, privacy:.public)")
#else
                    logger.info("Supplying sheet with cover art for \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif
                    replyToUpdate.attachments["\(inode)/cover"] = QLPreviewReplyAttachment(data:coverdata, contentType:.image)
                    content += "<div><img src=\"cid:\(inode)/cover\" width=\"\(snapshotter.previewSize.width)\"></div>\n"
                } else {
#if DEBUG
                    logger.info("Supplying contact sheet \(request.fileURL.path, privacy:.public)")
#else
                    logger.info("Supplying contact sheet for \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif
                }
                for i in 0..<image_count {
                    guard let png = snapshotter.newPNG(with:snapshotter.previewSize, atTime:(snapshotter.duration * (i + 1)) / (image_count + 1)) else {
                        break
                    }
                    replyToUpdate.attachments["\(inode)/\(i).png"] = QLPreviewReplyAttachment(data:png as Data, contentType:.png)
                    content += "<div><img src=\"cid:\(inode)/\(i).png\" width=\"\(snapshotter.previewSize.width)\"></div>\n"
                }
                content += "</body>\n</html>\n"
                guard let contentData = content.data(using: .utf8) else {
                    throw NSError()
                }
                replyToUpdate.title = displayname(title:snapshotter.title ?? request.fileURL.lastPathComponent, size: snapshotter.displaySize, duration: snapshotter.duration, channels: Int(snapshotter.channels))
                return contentData
            }
            return reply
        }
#endif

        // Just cover art
        if let coverdata {
            let coversize = snapshotter.coverArtSize(with:.landscape)
            let reply = QLPreviewReply(dataOfContentType: .image,
                                       contentSize: coversize) { [self, snapshotter] replyToUpdate in

                replyToUpdate.title = displayname(title:snapshotter.title ?? request.fileURL.lastPathComponent, size: snapshotter.displaySize, duration: snapshotter.duration, channels: Int(snapshotter.channels))
                return coverdata
            }
#if DEBUG
            logger.info("Supplying \(Int(coversize.width))x\(Int(coversize.height)) cover art for \(request.fileURL.path, privacy:.public)")
#else
            logger.info("Supplying \(Int(coversize.width))x\(Int(coversize.height)) cover art for \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif
            return reply
        }

        // Just a single snapshot
        var snapshotTime = kDefaultSnapshotTime
        if let info = Bundle.main.infoDictionary,
           let suiteName = info["ApplicationGroup"] as? String,
           let defaults = UserDefaults(suiteName: suiteName) {
            snapshotTime = defaults.integer(forKey: kSettingsSnapshotTime)
            if (snapshotTime <= 0) {
                snapshotTime = kDefaultSnapshotTime
            }
        }
        let time = snapshotter.duration < kMinimumDuration ? -1 : (snapshotter.duration < 2 * snapshotTime ? snapshotter.duration/2 : snapshotTime)

        var thePreview = snapshotter.newSnapshot(with:snapshotter.previewSize, atTime:time)
        if thePreview == nil {
            // Failed. Try again at start.
            thePreview = snapshotter.newSnapshot(with:snapshotter.previewSize, atTime:0)
        }
        if (thePreview == nil)
        {
#if DEBUG
            logger.info("Can't supply anything for \(request.fileURL.path, privacy:.public)")
#else
            logger.info("Can't supply anything for \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif
            throw NSError()
        }

        let reply = QLPreviewReply(contextSize: snapshotter.previewSize, isBitmap: false) { [self, snapshotter]
            (context : CGContext, replyToUpdate : QLPreviewReply) in
            context.draw(thePreview!,
                         in:CGRectMake(0, 0, snapshotter.previewSize.width, snapshotter.previewSize.height),
                         byTiling: false)
            replyToUpdate.title = displayname(title:snapshotter.title ?? request.fileURL.lastPathComponent, size: snapshotter.displaySize, duration: snapshotter.duration, channels: Int(snapshotter.channels))
        }
#if DEBUG
        logger.info("Supplying \(Int(snapshotter.previewSize.width))x\(Int(snapshotter.previewSize.height)) snapshot for \(request.fileURL.path, privacy:.public)")
#else
        logger.info("Supplying \(Int(snapshotter.previewSize.width))x\(Int(snapshotter.previewSize.height)) snapshot for \(request.fileURL.path, privacy:.private(mask:.hash))")
#endif
        return reply
    }
}
