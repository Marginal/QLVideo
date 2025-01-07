//
//  PreviewViewController.swift
//  previewer
//
//  Created by Jonathan Harris on 05/01/2025.
//

import Cocoa
import Quartz
import OSLog

class PreviewViewController: NSViewController, QLPreviewingController {

    var logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "previewer")

    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        super.loadView()
        // Do any additional setup after loading the view.

        logger.info("PreviewViewController.loadView")
    }

    func preparePreviewOfSearchableItem(identifier: String, queryString: String?) async throws {
        // Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.
#if DEBUG
        logger.info("preparePreviewOfSearchableItem \(identifier, privacy:.public) \(queryString ?? "nil", privacy:.public)")
#else
        logger.info("preparePreviewOfSearchableItem \(identifier, privacy:.private(mask:.hash)) \(queryString ?? "nil", privacy:.private(mask:.hash))")
#endif
        // Perform any setup necessary in order to prepare the view.
        // Quick Look will display a loading spinner until this returns.
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.
#if DEBUG
        logger.info("preparePreviewOfFile \(url.path, privacy:.public)")
#else
        logger.info("preparePreviewOfFile \(url.path, privacy:.private(mask:.hash))")
#endif

        // Perform any setup necessary in order to prepare the view.

        // Quick Look will display a loading spinner until this returns.
    }

}
