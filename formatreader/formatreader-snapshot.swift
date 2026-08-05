//
//  formatreader-snapshot.swift
//

import Accelerate
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension FormatReader {

    // Some format/codec combinations return EAGAIN from av_receive_frame() on the first frame, which results
    // in no thumbnails.
    // Some media just happens to have a black frame at the snapshot time.
    // Generate pseudo artwork for the thumbnail to handle both cases.
    // Assumes that streams are enabled/disabled as they would be when a thumbnail request is made
    func generateSnapshot() -> NSData? {
        guard bestVideo != AVERROR_STREAM_NOT_FOUND else { return nil }
        let stream = fmt_ctx!.pointee.streams[Int(bestVideo)]!

        // Set up decode context
        guard let codec = avcodec_find_decoder(stream.pointee.codecpar!.pointee.codec_id) else { return nil }
        var dec_ctx = avcodec_alloc_context3(codec)
        if dec_ctx == nil { return nil }
        defer { avcodec_free_context(&dec_ctx) }
        var ret = avcodec_parameters_to_context(dec_ctx, stream.pointee.codecpar!)
        if ret < 0 { return nil }
        dec_ctx!.pointee.thread_type = FF_THREAD_FRAME|FF_THREAD_SLICE
        dec_ctx!.pointee.thread_count = 0  // auto
        ret = avcodec_open2(dec_ctx, codec, nil)
        if ret < 0 { return nil }

        // HDR content is probably in a more modern format and not going to be problematic, so don't incur the overhead
        // Logic abbrevated from fixupColors()
        guard dec_ctx!.pointee.color_trc != AVCOL_TRC_SMPTE2084 && dec_ctx!.pointee.color_trc != AVCOL_TRC_ARIB_STD_B67 else {
            return nil
        }
        let pixDesc = av_pix_fmt_desc_get(dec_ctx!.pointee.pix_fmt)
        let bitDepth = pixDesc!.pointee.comp.0.depth  // not always accurate but works for supported formats
        guard bitDepth <= 8 || dec_ctx!.pointee.color_primaries != AVCOL_PRI_BT2020 else { return nil }

        // Set up for decode
        let srcWidth = dec_ctx!.pointee.width
        let srcHeight = dec_ctx!.pointee.height
        var dstWidth = srcWidth
        let dstHeight = srcHeight
        let sar = av_guess_sample_aspect_ratio(fmt_ctx!, &stream.pointee, nil)
        if sar.num != 0 && (sar.num != 1 || sar.den != 1) {
            dstWidth = Int32(Int(av_rescale_rnd(Int64(srcWidth), Int64(sar.num), Int64(sar.den), AV_ROUND_NEAR_INF)))
        }
        guard
            let sws_ctx = sws_getContext(
                Int32(srcWidth),
                Int32(srcHeight),
                dec_ctx!.pointee.pix_fmt,
                Int32(dstWidth),
                Int32(dstHeight),
                AV_PIX_FMT_BGRA,
                Int32(SWS_BICUBIC.rawValue | SWS_FULL_CHR_H_INT.rawValue),
                nil,
                nil,
                nil
            )
        else { return nil }
        defer { sws_freeContext(sws_ctx) }

        // Decoded image
        var dstStride = (4 * dstWidth + 63) & ~63
        guard let dstData = malloc(Int(dstStride * dstHeight)) else { return nil }
        defer { free(dstData) }
        var dstPlane0: UnsafeMutablePointer<UInt8>? = dstData.assumingMemoryBound(to: UInt8.self)

        var pkt = av_packet_alloc()
        guard pkt != nil else { return nil }
        defer { av_packet_free(&pkt) }
        var frame = av_frame_alloc()
        guard frame != nil else { return nil }
        defer { av_frame_free(&frame) }

        for lumaThreshold in [32.0, 16.0] {  // Try to get a decently bright image, or at least not a terrible one
            // Seek to snapshot time
            if stream.pointee.duration != AV_NOPTS_VALUE {
                guard
                    avformat_seek_file(
                        fmt_ctx,
                        bestVideo,
                        Int64.min,
                        Int64((Double(stream.pointee.duration) * snapshotTime).rounded()),
                        Int64.max,
                        0
                    ) >= 0
                else { return nil }
            } else {
                guard
                    avformat_seek_file(
                        fmt_ctx,
                        -1,
                        Int64.min,
                        Int64((Double(fmt_ctx!.pointee.duration) * snapshotTime).rounded()),
                        Int64.max,
                        0
                    ) >= 0
                else { return nil }
            }

            // demux
            var loopCount = 30  // Give up after this many video frames
            while loopCount > 0 && av_read_frame(fmt_ctx, pkt) >= 0 {
                if pkt!.pointee.stream_index != bestVideo {
                    av_packet_unref(pkt)
                    continue
                }
                loopCount -= 1

                // decode
                guard avcodec_send_packet(dec_ctx, pkt) >= 0 else { continue }  // Can get invalid data after a seek with some older formats. Keep going.
                av_packet_unref(pkt)
                repeat {
                    let ret = avcodec_receive_frame(dec_ctx, frame)
                    if ret == AVERROR_EAGAIN { break }
                    guard ret >= 0 else { return nil }

                    // Convert using native size - macOS will resize to the desired size before caching the result
                    let outHeight = withUnsafePointer(to: &frame!.pointee.linesize) { srcLinesizeTuple in
                        srcLinesizeTuple.withMemoryRebound(to: Int32.self, capacity: Int(AV_NUM_DATA_POINTERS)) {
                            srcLinesizePtr in
                            sws_scale(
                                sws_ctx,
                                UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(frame!.pointee.extended_data)),
                                srcLinesizePtr,
                                0,
                                srcHeight,
                                &dstPlane0,
                                &dstStride
                            )
                        }
                    }
                    guard outHeight > 0 else { return nil }

                    // Calculate brightness of centre half of the image
                    let roiW = max(1, dstWidth / 2)
                    let roiH = max(1, dstHeight / 2)

                    // Accumulate R/G/B ignoring alpha
                    var sumR: UInt64 = 0
                    var sumG: UInt64 = 0
                    var sumB: UInt64 = 0
                    for y in 0..<roiH {
                        let rowStart = dstPlane0!.advanced(by: Int((dstHeight / 4 + y) * dstStride + dstWidth))
                        var p = UnsafePointer<UInt8>(rowStart)
                        for _ in 0..<roiW {
                            sumB &+= UInt64(p[0])
                            sumG &+= UInt64(p[1])
                            sumR &+= UInt64(p[2])
                            p = p.advanced(by: 4)
                        }
                    }
                    // Average channels and calulate Luma using BT.709
                    let count = Double(roiW * roiH)
                    let avgR = Double(sumR) / count
                    let avgG = Double(sumG) / count
                    let avgB = Double(sumB) / count
                    let luma = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
                    if luma < lumaThreshold || luma >= 256.0 - lumaThreshold { continue }  // too dark or bright

                    // wangle into a CGImage
                    guard
                        let data = CFDataCreateWithBytesNoCopy(
                            kCFAllocatorDefault,
                            dstData,
                            CFIndex(dstStride * dstHeight),
                            kCFAllocatorNull
                        ),
                        let provider = CGDataProvider(data: data),
                        let image = CGImage(
                            width: Int(dstWidth),
                            height: Int(dstHeight),
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: Int(dstStride),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(alpha: .premultipliedFirst, component: .integer, byteOrder: .order32Little),
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent
                        )
                    else { return nil }

                    // Encode as PNG
                    let outData = CFDataCreateMutable(kCFAllocatorDefault, 0)
                    guard let destination = CGImageDestinationCreateWithData(outData!, UTType.png.identifier as CFString, 1, nil)
                    else { return nil }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { return nil }
                    return outData as NSData?

                } while true
            }
        }
        return nil
    }

}
