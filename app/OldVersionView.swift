//
//  OldVersionView.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 04/12/2022.
//

import Cocoa


class OldVersionView: NSView {

    @IBOutlet weak var advice: NSTextField!
    @IBOutlet weak var helpButton: NSButton!
    @IBOutlet var authorizationPrompt: NSTextField!

    override func awakeFromNib() {
        authorizationPrompt.isHidden = true
        helpButton.setAccessibilityFocused(true)
    }

    @IBAction func dismess(sender: NSButton) {
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)
    }

    @IBAction func help(sender: NSButton) {
        NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki/Troubleshooting")!)
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)
    }

}
