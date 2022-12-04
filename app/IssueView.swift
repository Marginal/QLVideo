//
//  IssueView.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 01/12/2022.
//

import Cocoa


class IssueView: NSView {

    @IBOutlet weak var dropTarget: DropTarget!
    @IBOutlet weak var advice: NSTextField!
    @IBOutlet weak var sendButton: NSButton!

    var files:[String] = []

    override func awakeFromNib() {
        // Reformat list items in advice
        let style = NSMutableParagraphStyle()
        style.headIndent = NSAttributedString(string: " • ", attributes: [.font: advice.font!]).size().width
        advice.attributedStringValue = NSAttributedString.init(string: advice.stringValue.replacingOccurrences(of: "\n- ", with: "\n • "),
                                                               attributes: [.font: advice.font!,
                                                                            .paragraphStyle: style])
    }

    @IBAction func cancelReport(sender: NSButton) {
        reset()
        let delegate = NSApp.delegate as! AppDelegate
        delegate.issueWindow.close()
    }

    @IBAction func sendReport(sender: NSButton) {
        sendButton.isEnabled = false
        let version = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        let macOS = ProcessInfo().operatingSystemVersionString
        let machine = sysCtl("hw.machine")
        var hardware = "\(sysCtl("hw.model")) \(machine)"
        if machine == "arm64" {
            hardware = hardware + " neon=\(sysCtl("hw.optional.neon"))"
        } else if machine == "x86_64" {
            hardware = hardware + " avx2=\(sysCtl("hw.optional.avx2_0")) avx512f=\(sysCtl("hw.optional.avx512f"))"
        }
        var report = "Your description of the problem here!\n\n\n---\nQLVideo: \(version)\nmacOS: \(macOS)\nHardware: \(hardware)\n"

        // limit to one file to try to avoid hitting GitHub POST character limit
        for filenum in 0..<1 {
            var filereport = ""
            let videofile = files[filenum]
            do {
                try filereport.append("mdimport: \(helper("/usr/bin/mdimport", args: ["-n", "-d1"] + [videofile]).replacingOccurrences(of: "\n", with: " ")).\n")
            } catch {
                filereport.append("mdimport: \(error)\n")
            }
            do {
                try filereport.append("```json\n\(helper(Bundle.main.path(forAuxiliaryExecutable: "ffprobe")!, args: ["-loglevel", "error", "-print_format", "json", "-show_entries", "format=format_name,duration,size,bit_rate,probe_score:stream=codec_type,codec_name,profile,codec_tag_string,pix_fmt,sample_fmt,channel_layout,language,width,height,display_aspect_ratio:stream_disposition=default,attached_pic,timed_thumbnails"] + [videofile]).replacingOccurrences(of: "\n\n", with: "\n").replacingOccurrences(of: "    ", with: "  "))```\n")
            } catch {
                filereport.append("ffprobe: \(error)\n")
            }
            filereport = filereport.replacingOccurrences(of: videofile,
                                                         with: "*file*.\(NSString(string: videofile).pathExtension)")
            report.append("\(filereport)\n")
        }

        var url: URL
        if let encoded = report.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url = URL(string: "https://github.com/Marginal/QLVideo/issues/new?body=".appending(encoded))!
        } else {
            url = URL(string: "https://github.com/Marginal/QLVideo/issues/new")!
        }
        NSWorkspace.shared.open(url)

        reset()
        let delegate = NSApp.delegate as! AppDelegate
        delegate.issueWindow.close()
    }

    func reset() {
        files = []
        dropTarget.image = nil
        sendButton.isEnabled = false
    }
}

// https://www.appcoda.com/nspasteboard-macos/
class DropTarget: NSImageView {

    weak var parent: IssueView!

    override func awakeFromNib() {
        parent = (window?.contentView as! IssueView)
        registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options:[NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) {
            for item in items {
                let path = (item as! NSURL).path
                if path != nil {
                    parent.files.append(path!)
                }
            }
            if parent.files.count > 0 {
                self.image = NSImage(named: "NSMultipleDocuments")
                parent.sendButton.isEnabled = true
                return true
            }
        }
        return false;
    }
}

