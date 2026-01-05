//
//  simpleplayer.swift
//  simpleplayer
//
//  Created by Jonathan Harris on 01/12/2025.
//

import AVKit
import MediaToolbox
import SwiftUI
import VideoToolbox

@main
struct SimplePlayer: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    init() {
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        VTRegisterSupplementalVideoDecoderIfAvailable(0x7670_3038) // vp08
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        print("VP8 decode available: \(VTIsHardwareDecodeSupported(0x7670_3038))")
        print("VP9 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
        print("AV1 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")
    }
}

struct ContentView: View {
    @State private var player = AVPlayer()
    @State private var showingOpenPanel = false
    @State private var statusObserver: NSKeyValueObservation?
    @State private var emptyObserver: NSKeyValueObservation?
    @State private var fullObserver: NSKeyValueObservation?

    var body: some View {
        VStack {
            VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit)
            Button("Open Video…") { showingOpenPanel = true }.padding()
        }
        .frame(minWidth: 480, minHeight: 320)
        .fileImporter(
            isPresented: $showingOpenPanel,
            allowedContentTypes: [.movie, .video, .audio, .audiovisualContent],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    print("Selected URL: \(url)")

                    // Access security-scoped resource (macOS sandbox)
                    guard url.startAccessingSecurityScopedResource() else {
                        print("Failed to access security-scoped resource for URL: \(url)")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    printTrackInfo(url: url)

                    let item = AVPlayerItem(url: url)

                    // Observe status to surface errors from AVPlayerItem
                    statusObserver = item.observe(\.status, options: [.new]) { item, _ in
                        switch item.status {
                        case .readyToPlay:
                            print("AVPlayerItem is ready to play")
                        case .failed:
                            print("AVPlayerItem failed: \(item.error?.localizedDescription ?? "Unknown error")")
                        case .unknown:
                            print("AVPlayerItem status is unknown")
                        @unknown default:
                            print("AVPlayerItem status is an unknown new case \(item.status.rawValue)")
                        }
                    }
                    emptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { item, change in
                        print("AVPlayerItem playbackBufferEmpty=\(change.newValue, default: "unknown")")
                    }
                    fullObserver = item.observe(\.isPlaybackBufferFull, options: [.new]) { item, change in
                        print("AVPlayerItem playbackBufferFull=\(change.newValue, default: "unknown")")
                    }

                    NotificationCenter.default.addObserver(
                        forName: AVPlayerItem.didPlayToEndTimeNotification,
                        object: item,
                        queue: .main
                    ) { notification in
                        print("AVPlayerItem didPlayToEndTimeNotification \(notification)")
                    }
                    NotificationCenter.default.addObserver(
                        forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                        object: item,
                        queue: .main
                    ) { notification in
                        print("AVPlayerItem failedToPlayToEndTimeNotification \(notification)")
                    }
                    NotificationCenter.default.addObserver(
                        forName: AVPlayerItem.newErrorLogEntryNotification,
                        object: item,
                        queue: .main
                    ) { notification in
                        print("AVPlayerItem newErrorLogEntryNotification \(notification)")
                    }

                    self.player.replaceCurrentItem(with: item)
                    self.player.play()
                }
            default:
                break
            }
        }
    }
}

func printTrackInfo(url: URL) {
    let asset = AVURLAsset(url: url)
    for track in asset.tracks {
        for format in track.formatDescriptions {
            print(format)
            let format = format as! CMFormatDescription
            if let atoms = format.extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [CFString: Data] {
                for (key, value) in atoms {
                    print(
                        "\(key): length=\(value.count) \(value.reduce("data=", { result, byte in String(format: "%@ %02x", result, byte) }))"
                    )
                }
            }
        }
    }
}

func printAudioInfo(url: URL) {
    var status: OSStatus = noErr
    var audioFile: AudioFileID?
    var propertySize: UInt32 = 0
    var propertyWriteable: UInt32 = 0

    status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
    guard status == noErr, let audioFile else {
        if status == kAudioFileUnsupportedFileTypeError {
            print("Could not open audio file, Unsupported File Type")
        } else {
            print("Could not open audio file, status: \(status)")
        }
        return
    }

    status = AudioFileGetPropertyInfo(audioFile, kAudioFilePropertyDataFormat, &propertySize, &propertyWriteable)
    if status != noErr || propertySize <= 0 {
        print("AudioFileGetPropertyInfo kAudioFilePropertyDataFormat failed, status: \(status)")
    } else {
        var asbd = AudioStreamBasicDescription()
        status = AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &propertySize, &asbd)
        if status != noErr {
            print("AudioFileGetProperty kAudioFilePropertyDataFormat failed, status: \(status)")
        } else {
            print(
                "sampleRate:\(Int(asbd.mSampleRate)) formatID:\"\(String(asbd.mFormatID, radix:16))\" formatFlags:0x\(String(asbd.mFormatFlags, radix:16)) bytesPerPacket:\(asbd.mBytesPerPacket) framesPerPacket:\(asbd.mFramesPerPacket) bytesPerFrame:\(asbd.mBytesPerFrame) channelsPerFrame:\(asbd.mChannelsPerFrame) bitsPerChannel:\(asbd.mBitsPerChannel)"
            )
        }
    }

    status = AudioFileGetPropertyInfo(audioFile, kAudioFilePropertyChannelLayout, &propertySize, &propertyWriteable)
    if status != noErr || propertySize <= 0 {
        print("AudioFileGetPropertyInfo kAudioFilePropertyChannelLayout failed, status: \(status)")
    } else {
        let layoutPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        let layout = layoutPtr.assumingMemoryBound(to: AudioChannelLayout.self).pointee

        status = AudioFileGetProperty(audioFile, kAudioFilePropertyChannelLayout, &propertySize, layoutPtr)
        if status != noErr {
            print("AudioFileGetProperty kAudioFilePropertyChannelLayout failed, status: \(status)")
        } else {
            print("Layout tag: \(layout.mChannelLayoutTag)")
        }
    }

    status = AudioFileGetPropertyInfo(audioFile, kAudioFilePropertyMagicCookieData, &propertySize, &propertyWriteable)
    if status != noErr || propertySize <= 0 {
        print("AudioFileGetPropertyInfo kAudioFilePropertyMagicCookieData failed, status: \(status)")
    } else {
        let cookiePtr = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(propertySize))

        status = AudioFileGetProperty(audioFile, kAudioFilePropertyMagicCookieData, &propertySize, cookiePtr.baseAddress!)
        if status != noErr {
            print("AudioFileGetProperty kAudioFilePropertyMagicCookieData failed, status: \(status)")
        } else {
            let hex = cookiePtr.map({ String(format: "%02x", $0) }).joined(separator: " ")
            print("Magic cookie: \(hex)")
        }
    }

}
