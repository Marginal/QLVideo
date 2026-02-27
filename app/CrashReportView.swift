//
//  CrashReportView.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 27/02/2026.
//

import Cocoa

final class CrashReportView: NSView {

    @IBOutlet weak var fileLabel: NSTextField!

    private var zipPath: URL?

    func configure(url: URL) {
        zipPath = url
        fileLabel.stringValue = url.lastPathComponent
    }

    @IBAction func ok(sender: NSButton) {
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)
    }

    @IBAction func revealInFinder(sender: NSButton) {
        if let path = zipPath {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        }
    }
}
