//
//  ThumbnailProvider.swift
//  thumbnailer
//
//  Created by Jonathan Harris on 12/01/2025.
//

import QuickLookThumbnailing

// Settings
let kSettingsSnapshotTime = "SnapshotTime"  // Seek offset for thumbnails and single Previews [s].

// Constants
let kDefaultSnapshotTime = 60
let kMinimumDuration = 5  // Don't bother seeking clips shorter than this [s].

// Undocumented property
enum QLThumbnailIconFlavor: Int {
    case plainFlavor = 0
    case roundedFlavor = 1
    case bookFlavor = 2
    case movieFlavor = 3
    case addressFlavor = 4
    case imageFlavor = 5
    case glossFlavor = 6
    case slideFlavor = 7
    case squareFlavor = 8
    case borderFlavor = 9
    case squareBorderFlavor = 10
    case calendarFlavor = 11
    case gridFlavor = 12
}

class ThumbnailProvider: QLThumbnailProvider {

    var logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "previewer")

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void)
    {
        var isCoverArt = false

        guard let snapshotter = Snapshotter.init(url: request.fileURL as CFURL)
        else {
            #if DEBUG
                logger.info(
                    "provideThumbnail failed to open \(request.fileURL.path, privacy:.public)"
                )
            #else
                logger.info(
                    "provideThumbnail failed to open \(request.fileURL.path, privacy:.private(mask:.hash))"
                )
            #endif
            handler(
                nil,
                NSError(domain: "uk.org.marginal.qlvideo", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to open file"]))
            return
        }

        // Use cover art if present
        var size: CGSize  // Size in pixels of the source snapshot
        var snapshot = snapshotter.newCoverArt(with: .thumbnail)
        if snapshot != nil {
            isCoverArt = true
            size = CGSize(width: snapshot!.width, height: snapshot!.height)
        } else {
            size = snapshotter.previewSize
        }

        var contextSize: CGSize  // Size of the returned context - unscaled
        if size.width / request.maximumSize.width > size.height
            / request.maximumSize.height
        {
            contextSize = CGSize(
                width: request.maximumSize.width, height: round(size.height * request.maximumSize.width / size.width))
        } else {
            contextSize = CGSize(
                width: round(size.width * request.maximumSize.height / size.height), height: request.maximumSize.height)
        }
        let snapshotSize = CGSize(width: contextSize.width * request.scale, height: contextSize.height * request.scale)  // Size in pixels of the proportionally scaled snapshot

        var imageSize: CGSize  // Size in pixels of the returned context - scaled
        if (request.minimumSize.width == request.maximumSize.width) || (request.minimumSize.height == request.maximumSize.height)
        {
            // Spotlight wants image centered in exactly sized context
            contextSize = request.maximumSize
            imageSize = CGSize(
                width: request.scale * request.maximumSize.width, height: request.scale * request.maximumSize.height)
        } else {
            // Finder wants proportionally sized context
            imageSize = snapshotSize
        }

        if snapshot == nil {
            // No cover art - generate snapshot
            var snapshotTime = kDefaultSnapshotTime
            if let info = Bundle.main.infoDictionary,
                let suiteName = info["ApplicationGroup"] as? String,
                let defaults = UserDefaults(suiteName: suiteName)
            {
                snapshotTime = defaults.integer(forKey: kSettingsSnapshotTime)
                if snapshotTime <= 0 {
                    snapshotTime = kDefaultSnapshotTime
                }
            }
            let time =
                snapshotter.duration < kMinimumDuration
                ? -1 : (snapshotter.duration < 2 * snapshotTime ? snapshotter.duration / 2 : snapshotTime)

            snapshot = snapshotter.newSnapshot(with: snapshotSize, atTime: time)
            if snapshot == nil {
                // Failed. Try again at start.
                snapshot = snapshotter.newSnapshot(with: snapshotSize, atTime: 0)
            }
        }

        if snapshot == nil {
            #if DEBUG
                logger.info(
                    "Can't supply anything for \(request.fileURL.path, privacy:.public)"
                )
            #else
                logger.info(
                    "Can't supply anything for \(request.fileURL.path, privacy:.private(mask:.hash))"
                )
            #endif
            handler(
                nil,
                NSError(
                    domain: "uk.org.marginal.qlvideo", code: 0, userInfo: [NSLocalizedDescriptionKey: "Can't supply anything"]))
            return
        } else {
            #if DEBUG
                logger.info(
                    "Supplying \(Int(snapshot!.width))x\(Int(snapshot!.height)) \(isCoverArt ? "cover art" : (snapshotter.pictures != 0 ? "picture" : "snapshot"), privacy:.public) for \(request.fileURL.path, privacy:.public)"
                )
            #else
                logger.info(
                    "Supplying \(Int(snapshot!.width))x\(Int(snapshot!.height)) \(isCoverArt ? "cover art" : (snapshotter.pictures != 0 ? "picture" : "snapshot"), privacy:.public) for \(request.fileURL.path, privacy:.private(mask:.hash))"
                )
            #endif

            let reply = QLThumbnailReply(
                contextSize: contextSize,
                drawing: { context in
                    // Draw the thumbnail here.
                    // Return true if the thumbnail was successfully drawn inside this block.
                    let offX = (imageSize.width - snapshotSize.width) / 2
                    let offY = (imageSize.height - snapshotSize.height) / 2
                    context.draw(
                        snapshot!,
                        in: CGRect(
                            x: offX, y: offY, width: snapshotSize.width,
                            height: snapshotSize.height))
                    return true
                })

            // explicitly request letterbox mattes for UTIs that don't derive from public.media such as com.microsoft.advanced-systems-format, and explicitly suppress them for cover art
            typealias setIconFlavorMethod = @convention(c) (NSObject, Selector, NSInteger) -> Bool
            let selector = NSSelectorFromString("setIconFlavor:")
            let methodIMP = reply.method(for: selector)
            let method = unsafeBitCast(methodIMP, to: setIconFlavorMethod.self)
            _ = method(
                reply, selector, (isCoverArt ? QLThumbnailIconFlavor.glossFlavor : QLThumbnailIconFlavor.movieFlavor).rawValue)

            handler(reply, nil)
        }
    }
}
