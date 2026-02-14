//
//  simpleplayer.swift
//  simpleplayer
//
//  Created by Jonathan Harris on 01/12/2025.
//

import AVKit
import CoreVideo
import MediaToolbox
import Metal
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
        print("VP8 decode available: \(VTIsHardwareDecodeSupported(0x7670_3038))")
        print("VP9 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
        print("AV1 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")
        print("Dolby Vision decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC))")
        printUTIs()
        printPixFmts()
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
            HStack {
                Button("Open Video…") { showingOpenPanel = true }
                Button("Seek to 10s") { player.seek(to: CMTime(value: 10_000_000, timescale: 1_000_000)) }  // QuickLook thumbnail snapshot time
            }
            .padding()
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
                    self.player.seek(to: CMTime(value: 10_000_000, timescale: 1_000_000))  // Start at 10s like QuickLook thumbnailer
                    self.player.play()
                }
            default:
                break
            }
        }
    }
}

// Helper to convert FourCC to readable string
func fourCCString(_ f: OSType) -> String {
    let chars: [CChar] = [
        CChar((f >> 24) & 0xFF),
        CChar((f >> 16) & 0xFF),
        CChar((f >> 8) & 0xFF),
        CChar(f & 0xFF),
        0,
    ]
    return String(cString: chars)
}

// Try creating a CVPixelBuffer with IOSurface backing
func canCreateIOSurfacePixelBuffer(format: OSType) -> Bool {
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: format,
        kCVPixelBufferWidthKey: 16,
        kCVPixelBufferHeightKey: 16,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]

    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        format,
        attrs as CFDictionary,
        &pb
    )
    return status == kCVReturnSuccess && pb != nil
}

// Check Metal GPU renderability
func isMetalRenderable(format: OSType, device: MTLDevice) -> Bool {
    // Try to map CVPixelFormat → MTLPixelFormat
    // This is not exhaustive but covers all GPU‑renderable formats
    let mapping: [OSType: MTLPixelFormat] = [
        kCVPixelFormatType_32BGRA: .bgra8Unorm,
        kCVPixelFormatType_32RGBA: .rgba8Unorm,
        kCVPixelFormatType_64RGBAHalf: .rgba16Float,
        kCVPixelFormatType_128RGBAFloat: .rgba32Float,
        kCVPixelFormatType_OneComponent8: .r8Unorm,
        kCVPixelFormatType_OneComponent16Half: .r16Float,
        kCVPixelFormatType_OneComponent32Float: .r32Float,
    ]

    guard let mtlFormat = mapping[format] else {
        return false
    }

    return device.supportsTextureSampleCount(1) && mtlFormat != .invalid
}

func printUTIs(){
    // AVFoundation supported content
    if #available(macOS 26.0, *) {
        let ext = AVURLAsset.audiovisualContentTypes.map { "\($0.preferredMIMEType ?? "???"): \($0.tags[.filenameExtension] ?? [])" }
        print("\naudiovisualContentTypes:\n\(ext.joined(separator: "\n"))")
    } else {
        print("\naudiovisualMIMETypes:\n\(AVURLAsset.audiovisualMIMETypes())")
        print("audiovisualTypes:\n\(AVURLAsset.audiovisualTypes())")
    }
}

func printPixFmts() {

    // Main enumeration
    let device = MTLCreateSystemDefaultDevice()!

    if let allFormatsCF = CVPixelFormatDescriptionArrayCreateWithAllPixelFormatTypes(kCFAllocatorDefault) {
        let allFormats = allFormatsCF as NSArray

        print("\nIOSurface‑compatible CVPixelFormats:")
        for case let fmtNumber as NSNumber in allFormats {
            let fmt = OSType(fmtNumber.uint32Value)

            let desc = CVPixelFormatDescriptionCreateWithPixelFormatType(kCFAllocatorDefault, fmt)! as NSDictionary
            let gpuRenderable = isMetalRenderable(format: fmt, device: device)
            let creatable = canCreateIOSurfacePixelBuffer(format: fmt)

            print(
                "\(fourCCString(fmt)) (0x\(String(fmt, radix: 16))) GPU:\(gpuRenderable ? "YES" : "NO ") IOSurface:\(creatable ? "YES" : "NO ") Range:\(desc[kCVPixelFormatComponentRange] ?? "???")"
            )
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
    print("Metadata:")
    for item in asset.metadata { print(String(describing: item)) }
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
