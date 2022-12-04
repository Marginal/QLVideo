//
//  AppDelegate.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 15/11/2022.
//

import Cocoa


// Settings
let kSettingsLastSpotlight = "LastSpotlight"     // Last version ran - for upgrade check
let kSettingsLastQuickLook = "LastQuickLook"     // Last version ran - for upgrade check
let kSettingsSnapshotCount = "SnapshotCount"     // Max number of snapshots generated in Preview mode.
let kSettingsSnapshotTime  = "SnapshotTime"      // Seek offset for thumbnails and single Previews [s].
let kSettingsSnapshotAlways = "SnapshotAlways"   // Whether to generate static snapshot(s) even if playable Preview is available.

// Setting defaults
let kDefaultSnapshotTime = 60;    // CoreMedia generator appears to use 10s. Completely arbitrary.
let kDefaultSnapshotCount = 10;   // 7-14 fit in the left bar of the Preview window without scrolling, depending on the display vertical resolution.
let kMaxSnapshotCount = 25;

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet var mainWindow: NSWindow!

    @IBOutlet var versionLabel: NSTextField!
    @IBOutlet var copyrightNote: NSTextField!

    @IBOutlet var snapshotTime: NSSlider!
    @IBOutlet var snapshotTimeValue: NSTextField!

    @IBOutlet var regenerateNote: NSTextField!
    @IBOutlet var reindexingNote: NSTextField!

    // Help
    @IBOutlet var issueWindow: NSWindow!

    var defaults: UserDefaults?

    lazy var snapshotTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    // View is loaded but not yet displayed - read settings

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Remove the searchable Help entry
        NSApplication.shared.helpMenu = NSMenu(title: "Unused")

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
            maybeResetCache(version)
            maybeResetSpotlight(version)
        }

        if (defaults?.integer(forKey: kSettingsSnapshotTime) ?? kDefaultSnapshotTime <= 0) {
            snapshotTime.integerValue = kDefaultSnapshotTime
        } else {
            snapshotTime.integerValue = defaults?.integer(forKey: kSettingsSnapshotTime) ?? kDefaultSnapshotTime
        }
        snapshotTimeValue.stringValue = snapshotTimeFormatter.string(from: TimeInterval(snapshotTime.integerValue)) ?? "\(snapshotTime.integerValue)"

        // Check if unsupported hardware and don't do further setup if so
        if sysCtl("hw.machine") == "x86_64" && sysCtl("hw.optional.avx2_0") != "yes" {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "QuickLook Video requires a late-2013 Mac or newer, with AVX2 support"
            alert.informativeText = "The QuickLook and Spotlight plugins will crash!"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK:- UI actions

    // snapshotTime slider changed - round to int, update text field, and update defaults
    @IBAction func snapshotTimeChanged(sender: NSSlider) {
        let value = snapshotTime.intValue
        snapshotTime.intValue = value
        snapshotTimeValue.stringValue = snapshotTimeFormatter.string(from: TimeInterval(value)) ?? "\(value)"
        defaults?.set(value, forKey: kSettingsSnapshotTime)
    }

    @IBAction func regenerateThumbnails(sender: NSButton) {
        defaults?.synchronize()
        regenerateNote.isHidden = !resetCache()
    }

    @IBAction func showHelp(sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki")!)
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki")!)
    }

    @IBAction func reportIssue(sender: NSMenuItem) {
        mainWindow.beginSheet(issueWindow, completionHandler: nil)
    }

    // MARK:- plugin management

    // Reset the QuickLook cache if this is the first time this version of the app is run
    func maybeResetCache(_ currentVersion: String) {
        let oldVersion = defaults!.double(forKey: kSettingsLastQuickLook) // will be zero if not set
        if Double(currentVersion)! > oldVersion  && resetCache() {
            defaults!.set(currentVersion, forKey: kSettingsLastQuickLook)
            regenerateNote.isHidden = false
        } else {
            regenerateNote.isHidden = true
        }
    }

    // Reindex Spotlight metadata if this is the first time this version of the app is run
    func maybeResetSpotlight(_ currentVersion: String) {
        let oldVersion = defaults!.double(forKey: kSettingsLastSpotlight) // will be zero if not set
        if Double(currentVersion)! > oldVersion {
            // Spotlight can be slow to notice new importers
            // Nothing we can do about that so poll
            let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { timer in
                let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/Video.mdimporter"
                do {
                    let listing = try helper("/usr/bin/mdimport", args: ["-L"])
                    if listing.contains(mdimporter) {
                        timer.invalidate()
                        if resetSpotlight() {
                            self.defaults!.set(currentVersion, forKey: kSettingsLastSpotlight)
                            self.reindexingNote.isHidden = false
                        } else {
                            self.reindexingNote.isHidden = true
                        }
                    }
                } catch {
                    timer.invalidate()
                    self.reindexingNote.isHidden = true
                }
            }
            timer.fire()
        } else {
            reindexingNote.isHidden = true
        }
    }
}

// MARK:- Helper functions

func resetCache() -> Bool {
    do {
        try helper("/usr/bin/qlmanage", args: ["-r", "cache"])
        return true
    } catch {
        return false
    }
}

func resetSpotlight() -> Bool {
    let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/Video.mdimporter"
    do {
        try helper("/usr/bin/mdimport", args: ["-r", mdimporter])
        return true
    } catch {
        return false
    }
}

func sysCtl(_ name: String) -> String {
    var size = 0
    if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 {
        return "???"
    }
    var value = [CChar](repeating: 0, count: size)
    if sysctlbyname(name, &value, &size, nil, 0) != 0 {
        return "???"
    }

    // sysctl can return a int32, uint64 or chars. TODO: handle uint
    if size == 4 && value[0] == 1 {
        return "yes"
    } else if size == 4 && value[0] == 0 {
        return "no"
    } else {
        return String(cString: value)
    }
}

@discardableResult
func helper(_ exe: String, args: [String]) throws -> String {
    let task = Process()
    do {
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
    } catch {
        throw NSError(domain: "uk.org.marginal.qlvideo",
                      code: -1,
                      userInfo:["executable": exe, "status": "\(error)"])
    }

    let stdout = String(data: (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
    let stderr = String(data: (task.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
    if (task.terminationStatus != 0) {
        throw NSError(domain: "uk.org.marginal.qlvideo",
                      code: Int(task.terminationStatus),
                      userInfo:["executable": exe, "status": task.terminationStatus])
    }

    return stdout + stderr
}

