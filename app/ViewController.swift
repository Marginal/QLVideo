//
//  ViewController.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 15/11/2022.
//

import Cocoa


// Settings
let kSettingsLastVersion = "LastVersion"         // Last version ran - for upgrade check
let kSettingsSnapshotCount = "SnapshotCount"     // Max number of snapshots generated in Preview mode.
let kSettingsSnapshotTime  = "SnapshotTime"      // Seek offset for thumbnails and single Previews [s].
let kSettingsSnapshotAlways = "SnapshotAlways"   // Whether to generate static snapshot(s) even if playable Preview is available.

// Setting defaults
let kDefaultSnapshotTime = 60;    // CoreMedia generator appears to use 10s. Completely arbitrary.
let kDefaultSnapshotCount = 10;   // 7-14 fit in the left bar of the Preview window without scrolling, depending on the display vertical resolution.
let kMaxSnapshotCount = 25;

class ViewController: NSViewController {

    var defaults: UserDefaults?

    @IBOutlet var versionLabel: NSTextField!
    @IBOutlet var copyrightNote: NSTextField!

    @IBOutlet var snapshotTime: NSSlider!
    @IBOutlet var snapshotTimeValue: NSTextField!

    @IBOutlet var snapshotCount: NSSlider!
    @IBOutlet var snapshotCountValue: NSTextField!

    @IBOutlet var snapshotAlways: NSButton!
    @IBOutlet var regenerateNote: NSTextField!
    @IBOutlet var reindexingNote: NSTextField!

    // View is loaded but not yet displayed - read settings
    override func viewDidLoad() {
        super.viewDidLoad()

        let myBundle = Bundle.main
        let version: String = myBundle.infoDictionary!["CFBundleShortVersionString"] as! String
        versionLabel.stringValue = "Version \(version)"
        copyrightNote.stringValue = myBundle.infoDictionary!["NSHumanReadableCopyright"] as! String
        regenerateNote.isHidden = true
        reindexingNote.isHidden = true

        let suiteName: String = myBundle.infoDictionary!["ApplicationGroup"] as! String
        defaults = UserDefaults(suiteName: suiteName)
        if (defaults == nil) {
            NSLog("QLVideo preview can't access defaults for application group \(suiteName)")
        } else {
            if (isNewOrUpgraded(defaults: defaults!))
            {
                regenerateNote.isHidden = !resetCache()
                reindexingNote.isHidden = !resetSpotlight()
            }
        }

        if (defaults?.integer(forKey: kSettingsSnapshotTime) ?? kDefaultSnapshotTime <= 0) {
            snapshotTime.integerValue = kDefaultSnapshotTime
        } else {
            snapshotTime.integerValue = defaults?.integer(forKey: kSettingsSnapshotTime) ?? kDefaultSnapshotTime
        }
        snapshotTimeValue.stringValue = "\(snapshotTime.integerValue)" + "s"

        if (defaults?.integer(forKey: kSettingsSnapshotCount) ?? kDefaultSnapshotCount <= 0) {
            snapshotCount.integerValue = kDefaultSnapshotCount
        } else {
            snapshotCount.integerValue = defaults?.integer(forKey: kSettingsSnapshotCount) ?? kDefaultSnapshotCount
        }
        snapshotCountValue.integerValue = snapshotCount.integerValue

        snapshotAlways.state = (defaults?.bool(forKey: kSettingsSnapshotAlways) ?? false) ? NSControl.StateValue.on : NSControl.StateValue.off
    }

    // View is displayed in a window
    override func viewDidAppear() {
        super.viewDidAppear()
        self.view.window?.title = "QuickLook Video"
    }

    // snapshotTime slider changed - round to int, update text field, and update defaults
    @IBAction func snapshotTimeChanged(sender: NSSlider) {
        let value = snapshotTime.intValue
        snapshotTime.intValue = value
        snapshotTimeValue.stringValue = "\(value)" + "s"
        defaults?.set(value, forKey: kSettingsSnapshotTime)
    }

    // snapshotCount slider changed - round to int, update text field, and update defaults
    @IBAction func snapshotCountChanged(sender: NSSlider) {
        let value = snapshotCount.intValue
        snapshotCount.intValue = value
        snapshotCountValue.intValue = value
        defaults?.set(value, forKey: kSettingsSnapshotCount)
    }

    @IBAction func snapshotAlwaysChanged(sender: NSButton) {
        let value = (snapshotAlways.state == NSControl.StateValue.on)
        defaults?.set(value, forKey: kSettingsSnapshotAlways)
    }

    @IBAction func regenerateThumbnails(sender: NSButton) {
        defaults?.synchronize()
        regenerateNote.isHidden = !resetCache()
    }

    func isNewOrUpgraded(defaults: UserDefaults) -> Bool {
        let currentVersion = (Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! NSString).doubleValue
        let oldVersion = defaults.double(forKey: kSettingsLastVersion) // will be zero if not set
        defaults.set(currentVersion, forKey: kSettingsLastVersion)
        return (oldVersion < currentVersion)
    }
}

func resetCache() -> Bool {
    do {
        let task = try Process.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), arguments: ["-r", "cache"]) {
            (process: Process) in
            if (process.terminationStatus != 0) {
                NSLog("QLVideo app executing qlmanage -r cache: %d", process.terminationStatus)
            }
        }
        task.waitUntilExit()
        return true
    } catch {
        NSLog("QLVideo app executing qlmanage -r cache: \(error)")
        return false
    }
}

func resetSpotlight() -> Bool {
    let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/Video.mdimporter"
    do {
        let task = try Process.run(URL(fileURLWithPath: "/usr/bin/mdimport"), arguments: ["-r", mdimporter]) {
            (process: Process) in
            if (process.terminationStatus != 0) {
                NSLog("QLVideo app executing mdimport -r \(mdimporter): %d", process.terminationStatus)
            }
        }
        task.waitUntilExit()
        return true
    } catch {
        NSLog("QLVideo app executing mdimport -r \(mdimporter): \(error)")
        return false
    }
}
