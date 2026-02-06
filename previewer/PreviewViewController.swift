//
//  PreviewViewController.swift
//  previewer
//
//  Created by Jonathan Harris on 05/01/2025.
//

import QuickLookUI
import WebKit

// Settings
let kSettingsSnapshotTime = "SnapshotTime"  // Seek offset for thumbnails and single Previews [s].

// Constants
let kDefaultSnapshotTime = 60
let kMinimumDuration = 5  // Don't bother seeking clips shorter than this [s].
let kDefaultSnapshotCount = 10
let kMinimumPeriod = 60  // Don't create snapshots spaced more closely than this [s].

let kWindowWidthThreshhold: CGFloat = 600  // Finder Column view max width = 560
let kWindowHeightThreshhold: CGFloat = 160  // Get Info height = 128, QuickLook minimum window height = 180

enum PreviewType { case snapshot, webView, contactSheet }

// Window title helper
func displayname(title: String, size: CGSize, duration: Int, channels: Int) -> String {
    var channelstring: String

    switch channels
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
    default:  // Quadraphonic, LCRS or something else
        channelstring = String(localized: "\(channels)🔉")
    }

    if duration <= 0 {
        return
            "\(title) (\(Int(size.width))×\(Int(size.height)), \(channelstring))"
    } else if duration < 60 {
        return
            "\(title) (\(Int(size.width))×\(Int(size.height)), \(channelstring), 0:\(duration))"
    } else {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.hour, .minute, .second]
        return
            "\(title) (\(Int(size.width))×\(Int(size.height)), \(channelstring), \(formatter.string(from:TimeInterval(duration)) ?? ""))"
    }
}

// created anew for each item previewed
class PreviewViewController: NSViewController, QLPreviewingController, NSCollectionViewDataSource,
    NSCollectionViewDelegateFlowLayout
{

    let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "previewer")

    var snapshotter: Snapshotter?
    var hasCoverArt: Bool = false
    var snapshotSize: CGSize = .zero
    var images: [NSImage?] = []
    var timer: Timer? = nil
    var webViewVideoIsStopped: Bool = false

    @IBOutlet weak var sidebar: NSScrollView!
    @IBOutlet weak var sidebarCollection: NSCollectionView!
    @IBOutlet weak var snapshot: NSImageView!
    @IBOutlet weak var webView: WKWebView!

    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        logger.debug("PreviewViewController.loadView")
        super.loadView()
        // Do any additional setup after loading the view.
        snapshot.layer!.backgroundColor = .black  // CoreMedia previewer does this in Finder's Column & Gallery views
        sidebarCollection.backgroundColors = [.clear]
        sidebarCollection.register(NSNib(nibNamed: "SidebarItem", bundle: nil), forItemWithIdentifier: SidebarItem.identifier)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        logger.debug("collectionView.numberOfItemsInSection \(section) = \(self.images.count)")
        return self.images.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        logger.debug("collectionView.itemForRepresentedObjectAt \(indexPath)")
        let item = collectionView.makeItem(withIdentifier: SidebarItem.identifier, for: indexPath) as! SidebarItem
        item.imageView!.image = images[indexPath.item]
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        logger.debug("collectionView.didSelectItemsAt \(indexPaths)")
        snapshot.image = images[indexPaths.first!.item]
    }

    #if DEBUG
        override func rightMouseDown(with event: NSEvent) {
            // Opportunity to hit a breakpoint after layout & display
            logger.debug("rightMouseDown with \(event)")
        }
    #endif

    // Hide Views other than the one we want to show
    func setupPreview(_ previewType: PreviewType) {
        switch previewType {
        case .snapshot:
            sidebar.removeFromSuperview()
            webView.removeFromSuperview()
        case .webView:
            sidebar.removeFromSuperview()
            snapshot.removeFromSuperview()
        case .contactSheet:
            webView.removeFromSuperview()
        }
    }

    // returns MIME type for format&codec combinations that a webView will render in a <video> tag
    func webViewSupports(ext: String, codec: String?) -> String? {
        // av1 codec is only supported (in mp4/m4v only?) on M3 and later
        if codec == nil {
            return nil
        } else if ext.caseInsensitiveCompare("webm") == .orderedSame && (codec == "vp8" || codec == "vp9") {
            return "video/webm"
        } else if ext.caseInsensitiveCompare("mp4") == .orderedSame && (codec == "h264" || codec == "hevc") {
            return "video/mp4"
        } else if ext.caseInsensitiveCompare("m4v") == .orderedSame && (codec == "h264" || codec == "hevc") {
            return "video/x-m4v"
        }
        return nil
    }

    func preparePreviewOfSearchableItem(identifier: String, queryString: String?) async throws {
        // Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.
        #if DEBUG
            logger.info(
                "preparePreviewOfSearchableItem \(identifier, privacy:.public) \(queryString ?? "nil", privacy:.public)"
            )
        #else
            logger.info(
                "preparePreviewOfSearchableItem \(identifier, privacy:.private(mask:.hash)) \(queryString ?? "nil", privacy:.private(mask:.hash))"
            )
        #endif
        throw NSError(domain: "uk.org.marginal.qlvideo", code: -1, userInfo: [NSLocalizedFailureReasonErrorKey: "Not supported"])
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.
        #if DEBUG
            logger.info("preparePreviewOfFile \(url.path, privacy:.public)")
        #else
            logger.info(
                "preparePreviewOfFile \(url.path, privacy:.private(mask:.hash))"
            )
        #endif

        guard let snapshotter = Snapshotter(url: url as CFURL) else {
            #if DEBUG
                logger.info(
                    "preparePreviewOfFile failed to open \(url.path, privacy:.public)"
                )
            #else
                logger.info(
                    "preparePreviewOfFile failed to open \(url.path, privacy:.private(mask:.hash))"
                )
            #endif
            throw NSError(
                domain: "uk.org.marginal.qlvideo", code: -1, userInfo: [NSLocalizedFailureReasonErrorKey: "Failed to open"])
        }
        snapshotSize = snapshotter.previewSize

        // Should we prepare a full-sized (QLPreviewViewStyle.normal) preview for e.g. Finder's QuickLook
        // or a single image (QLPreviewViewStyle.compact) for e.g. Finder's Column view and Get Info panel.
        // Don't know how to get hold of QLPreviewViewStyle from here, so use window size to decide
        if view.frame.width < kWindowWidthThreshhold || view.frame.height < kWindowHeightThreshhold {
            // QLPreviewViewStyle.compact

            // use WebView to load supported files
            if let mimeType = webViewSupports(ext: url.pathExtension, codec: snapshotter.videoCodec) {
                // Fit to width
                let size = NSSize(width: view.frame.width, height: view.frame.width * snapshotSize.height / snapshotSize.width)
                setupPreview(.webView)
                webView.loadFileURL(url, allowingReadAccessTo: url)
                webView.loadHTMLString(
                    """
                    <html>
                    <meta name="viewport" content="width=\(size.width), height=\(size.height)" />
                    <body style="background-color:black;margin:0;padding:0;">
                        <video controls width="width=\(size.width)" height="\(size.height)">
                            <source src="\(url.lastPathComponent)" type="\(mimeType)" />
                    </body>
                    </html>
                    """, baseURL: url.deletingLastPathComponent())
                preferredContentSize = size
                return
            } else if let coverart = snapshotter.newCoverArt(
                with: view.frame.width < kWindowHeightThreshhold ? .thumbnail : .default)
            {
                snapshotSize = CGSize(width: coverart.width, height: coverart.height)
                snapshot.image = NSImage(cgImage: coverart, size: .zero)
            } else {
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

                if let image = snapshotter.newSnapshot(with: snapshotSize, atTime: time) {
                    snapshot.image = NSImage(cgImage: image, size: .zero)
                } else if let image = snapshotter.newSnapshot(with: snapshotSize, atTime: 0) {
                    // Failed. Try again at start.
                    snapshot.image = NSImage(cgImage: image, size: .zero)
                } else {
                    #if DEBUG
                        logger.info(
                            "preparePreviewOfFile can't supply anything for \(url.path, privacy:.public)"
                        )
                    #else
                        logger.info(
                            "preparePreviewOfFile can't supply anything for \(url.path, privacy:.private(mask:.hash))"
                        )
                    #endif
                    throw NSError(
                        domain: "uk.org.marginal.qlvideo", code: -1,
                        userInfo: [NSLocalizedFailureReasonErrorKey: "Can't supply anything"])
                }
            }
            setupPreview(.snapshot)
            snapshot.frame = NSRect(origin: CGPointZero, size: view.frame.size)
            // Fit to width
            preferredContentSize = NSSize(
                width: view.frame.width, height: view.frame.width * snapshotSize.height / snapshotSize.width)
            return
        }

        //
        // QLPreviewViewStyle.normal
        //

        // This doesn't actually do anything :(
        view.window?.title = displayname(
            title: snapshotter.title ?? url.lastPathComponent, size: snapshotter.displaySize, duration: snapshotter.duration,
            channels: Int(snapshotter.channels))

        // use WebView to load supported files
        if let mimeType = webViewSupports(ext: url.pathExtension, codec: snapshotter.videoCodec) {
            setupPreview(.webView)
            webView.loadFileURL(url, allowingReadAccessTo: url)
            webView.loadHTMLString(
                """
                <html>
                <meta name="viewport" content="width=\(snapshotSize.width), height=\(snapshotSize.height)" />
                <body style="background-color:black;margin:0;padding:0;">
                    <video controls autoplay width="width=\(snapshotSize.width)" height="\(snapshotSize.height)">
                        <source src="\(url.lastPathComponent)" type="\(mimeType)" />
                </body>
                </html>
                """, baseURL: url.deletingLastPathComponent())
            preferredContentSize = NSSize(width: snapshotSize.width, height: snapshotSize.height)
            return
        }

        var imageCount = 0

        if snapshotter.pictures > 0 {
            // "best" video stream is pre-computed pictures e.g. chapter markers in encrypted movies
            imageCount = Int(snapshotter.pictures)
        } else if snapshotter.duration <= kMinimumPeriod {
            imageCount = 1
        } else {
            imageCount = Int(snapshotter.duration / kMinimumPeriod) - 1
            if imageCount > kDefaultSnapshotCount {
                imageCount = kDefaultSnapshotCount
            }
        }

        for i in 0..<imageCount {
            if let image = snapshotter.newSnapshot(
                with: snapshotSize,
                atTime: snapshotter.duration < kMinimumDuration ? -1 : snapshotter.duration * (i + 1) / (imageCount + 1))
            {
                images.append(NSImage(cgImage: image, size: .zero))
            } else if i == 0 {
                // Failed. Try again at start.
                if let image = snapshotter.newSnapshot(with: snapshotSize, atTime: 0) {
                    images.append(NSImage(cgImage: image, size: .zero))
                }
                break
            } else {
                break
            }
        }

        // prepend cover art
        if let coverart = snapshotter.newCoverArt(with: .landscape) {
            hasCoverArt = true
            if images.count == 0 {
                // If we only have cover art use its dimensions
                snapshotSize = CGSize(width: coverart.width, height: coverart.height)
            }
            images.insert(NSImage(cgImage: coverart, size: .zero), at: 0)
        }

        if images.count == 0 {
            #if DEBUG
                logger.info(
                    "preparePreviewOfFile can't supply anything for \(url.path, privacy:.public)"
                )
            #else
                logger.info(
                    "preparePreviewOfFile can't supply anything for \(url.path, privacy:.private(mask:.hash))"
                )
            #endif
            throw NSError(
                domain: "uk.org.marginal.qlvideo", code: -1, userInfo: [NSLocalizedFailureReasonErrorKey: "Can't supply anything"]
            )
        } else if images.count == 1 {
            setupPreview(.snapshot)
            snapshot.image = images[0]
            snapshot.frame = NSRect(origin: CGPointZero, size: view.frame.size)
            preferredContentSize = snapshotSize
        } else {
            setupPreview(.contactSheet)
            snapshot.image = images[0]
            if snapshotSize.width / snapshotSize.height > 4.0 / 3.0 {
                (sidebarCollection.collectionViewLayout as! NSCollectionViewFlowLayout).itemSize = CGSize(
                    width: 170, height: 10 + 160 * snapshotSize.height / snapshotSize.width)
            } else {
                (sidebarCollection.collectionViewLayout as! NSCollectionViewFlowLayout).itemSize = CGSize(
                    width: 10 + 120 * snapshotSize.width / snapshotSize.height, height: 130)
            }
            preferredContentSize = NSSize(width: snapshotSize.width + sidebar.frame.width, height: snapshotSize.height)
            sidebarCollection.reloadData()
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkVisibility()
        }
    }

    func checkVisibility() {
        guard let window = view.window else {
            pauseVideo()
            return
        }
        
        if window.level.rawValue > NSWindow.Level.normal.rawValue {
            if webViewVideoIsStopped {
                resumeVideoIfNeeded()
            }
        } else {
            pauseVideo()
        }
    }

    func pauseVideo() {
        webViewVideoIsStopped = true
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause());")
    }

    func resumeVideoIfNeeded() {
        webViewVideoIsStopped = false
        let js = """
            document.querySelectorAll('video').forEach(video => {
                video.currentTime = 0;
                video.play().catch(e => {
                    console.log('Play interrupted:', e);
                });
            });
        """
        webView.evaluateJavaScript(js)
    }

    deinit {
        timer?.invalidate()
    }
}
