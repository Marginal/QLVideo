//
//  AppDelegate.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 15/11/2022.
//

import Cocoa
import OSLog
import Security

// Settings
let kSettingsLastSpotlight = "LastSpotlight"  // Last version ran - for upgrade check
let kSettingsLastQuickLook = "LastQuickLook"  // Last version ran - for upgrade check
let kSettingsSnapshotCount = "SnapshotCount"  // Max number of snapshots generated in Preview mode.
let kSettingsSnapshotTime = "SnapshotTime"  // Seek offset for thumbnails and single Previews [s].
let kSettingsSnapshotAlways = "SnapshotAlways"  // Whether to generate static snapshot(s) even if playable Preview is available.

// Setting defaults
let kDefaultSnapshotTime = 10  // CoreMedia generator appears to use 10s.

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet var mainWindow: NSWindow!
    @IBOutlet var reportIssue: NSMenuItem!

    @IBOutlet var versionLabel: NSTextField!
    @IBOutlet var copyrightNote: NSTextField!

    @IBOutlet var snapshotTime: NSSlider!
    @IBOutlet var snapshotTimeValue: NSTextField!

    @IBOutlet var regenerateNote: NSTextField!
    @IBOutlet var reindexingNote: NSTextField!

    // Dialogs
    @IBOutlet var issueWindow: NSWindow!
    @IBOutlet var crashReportWindow: NSWindow!
    @IBOutlet var coverArtWindow: NSWindow!
    @IBOutlet var oldVersionWindow: NSWindow!

    var defaults: UserDefaults?
    var logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "app")

    lazy var snapshotTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    lazy var isSandboxed: Bool = {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == noErr,
            SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == noErr,
            let info = info as? [CFString: Any],
            let entitlements = info[kSecCodeInfoEntitlementsDict] as? [CFString: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox" as CFString] as? Bool ?? false
    }()

    // View is loaded but not yet displayed - read settings
    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Remove the searchable Help entry
        NSApplication.shared.helpMenu = NSMenu(title: "Unused")
        if isSandboxed { reportIssue.isHidden = true }

        let myBundle = Bundle.main
        let version: String = myBundle.infoDictionary!["CFBundleShortVersionString"] as! String
        versionLabel.stringValue = "Version \(version)"
        copyrightNote.stringValue = myBundle.infoDictionary!["NSHumanReadableCopyright"] as! String
        regenerateNote.isHidden = true
        reindexingNote.isHidden = true

        let suiteName: String = myBundle.infoDictionary!["ApplicationGroup"] as! String
        defaults = UserDefaults(suiteName: suiteName)
        if let defaults {
            if defaults.integer(forKey: kSettingsSnapshotTime) <= 0 {
                snapshotTime.integerValue = kDefaultSnapshotTime
            } else {
                snapshotTime.integerValue = defaults.integer(forKey: kSettingsSnapshotTime)
            }
        } else {
            snapshotTime.integerValue = kDefaultSnapshotTime
            logger.error("Can't access defaults for \(suiteName, privacy: .public)")
        }
        snapshotTimeValue.stringValue =
            snapshotTimeFormatter.string(from: TimeInterval(snapshotTime.integerValue)) ?? "\(snapshotTime.integerValue)"

        // Check if unsupported hardware and don't do further setup if so
        if sysCtl("hw.machine") == "x86_64" && sysCtl("hw.optional.avx2_0") != "yes" {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "QuickLook Video requires a late-2013 Mac or newer, with AVX2 support"
            alert.informativeText = "The QuickLook and Spotlight plugins will crash!"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        maybeResetCache(version)
        maybeResetSpotlight(version)
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
        if resetCache() {
            do {
                try helper("/usr/bin/killall", args: ["Finder"])
            } catch {
                // Managed to tell QuickLook to regenerate cache, but couldn't restart Finder - Sandboxed?
                regenerateNote.isHidden = false
                return
            }
        }
        regenerateNote.isHidden = true
    }

    @IBAction func showHelp(sender: NSMenuItem) {
        if isSandboxed {
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki")!)
        }
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        if isSandboxed {
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki")!)
        }
        return true
    }

    @IBAction func reportIssue(sender: NSMenuItem) {
        mainWindow.beginSheet(issueWindow, completionHandler: nil)
    }

    func showCrashReport(filePath: URL) {
        if let view = crashReportWindow.contentView as? CrashReportView {
            view.configure(url: filePath)
            mainWindow.beginSheet(crashReportWindow, completionHandler: nil)
        }
    }

    @IBAction func coverArt(sender: NSMenuItem) {
        coverArtWindow.makeKeyAndOrderFront(self)
    }

    // MARK:- plugin management

    // Reset the QuickLook cache if this is the first time this version of the app is run
    func maybeResetCache(_ currentVersion: String) {
        if let defaults {
            let oldVersion = defaults.double(forKey: kSettingsLastQuickLook)  // will be zero if not set
            if Double(currentVersion) ?? 0.0 > oldVersion && resetCache() {
                defaults.set(currentVersion, forKey: kSettingsLastQuickLook)
                regenerateNote.isHidden = false
            } else {
                regenerateNote.isHidden = true
            }
        }
    }

    // Reindex Spotlight metadata if this is the first time this version of the app is run
    func maybeResetSpotlight(_ currentVersion: String) {
        if let defaults {
            let oldVersion = defaults.double(forKey: kSettingsLastSpotlight)  // will be zero if not set
            if Double(currentVersion) ?? 0.0 > oldVersion {
                // Spotlight can be slow to notice new importers. Nothing we can do about that so poll.
                let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [self] timer in
                    let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/"
                    do {
                        let listing = try helper("/usr/bin/mdimport", args: ["-L"])
                        if listing.contains(mdimporter) {
                            timer.invalidate()
                            if resetSpotlight() {
                                defaults.set(currentVersion, forKey: kSettingsLastSpotlight)
                                reindexingNote.isHidden = false
                            } else {
                                reindexingNote.isHidden = true
                            }
                        }
                    } catch {
                        timer.invalidate()
                        reindexingNote.isHidden = true
                    }
                }
                timer.fire()
            } else {
                reindexingNote.isHidden = true
            }
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
    let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/QLVideo Metadata.mdimporter"
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
        throw NSError(domain: "uk.org.marginal.qlvideo", code: -1, userInfo: [NSLocalizedFailureReasonErrorKey: "\(error)"])
    }

    let stdout = String(data: (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: (task.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        throw NSError(
            domain: "uk.org.marginal.qlvideo",
            code: Int(task.terminationStatus),
            userInfo: [NSLocalizedFailureReasonErrorKey: stderr]
        )
    }

    return stdout + stderr
}
