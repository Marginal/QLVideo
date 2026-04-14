//
//  videodecoder-hdr.swift
//  QLVideo
//
//  HDR passthrough: convert planar YUV 10/12/16-bit frames to biplanar P010 CVPixelBuffers
//  with HDR metadata attachments, letting macOS handle display-adaptive tone mapping.
//

import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

extension VideoDecoder {

    // Supported planar YUV formats for HDR passthrough.
    // All input formats are converted to 10-bit biplanar for macOS display pipeline.
    private static let hdrFormats:
        [Int32: (bitDepth: UInt32, uvShiftX: UInt32, uvShiftY: UInt32, videoRange: OSType, fullRange: OSType)] = [
            // 420: half width, half height chroma
            AV_PIX_FMT_YUV420P10LE.rawValue: (
                10, 1, 1, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            ),
            AV_PIX_FMT_YUV420P12LE.rawValue: (
                12, 1, 1, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            ),
            AV_PIX_FMT_YUV420P16LE.rawValue: (
                16, 1, 1, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            ),
            // 422: half width, full height chroma
            AV_PIX_FMT_YUV422P10LE.rawValue: (
                10, 1, 0, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            ),
            AV_PIX_FMT_YUV422P12LE.rawValue: (
                12, 1, 0, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            ),
            AV_PIX_FMT_YUV422P16LE.rawValue: (
                16, 1, 0, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            ),
            // 444: full width, full height chroma
            AV_PIX_FMT_YUV444P10LE.rawValue: (
                10, 0, 0, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            ),
            AV_PIX_FMT_YUV444P12LE.rawValue: (
                12, 0, 0, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            ),
            AV_PIX_FMT_YUV444P16LE.rawValue: (
                16, 0, 0, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            ),
        ]

    // Build the HDR version of a PixelBufferConfig. Called from makePixelBufferConfig() in videodecoder.swift
    func hdrPixelBufferConfig(frame: UnsafePointer<AVFrame>) -> PixelBufferConfig? {
        // Must be a supported planar format and HDR (PQ or HLG transfer function)
        guard let formatInfo = VideoDecoder.hdrFormats[frame.pointee.format],
            frame.pointee.color_trc == AVCOL_TRC_SMPTE2084 || frame.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67
        else {
            return nil
        }
        let pixelFormat = frame.pointee.color_range == AVCOL_RANGE_JPEG ? formatInfo.fullRange : formatInfo.videoRange

        // Build propagated attachments from the frame's color properties
        var attachments: [String: Any] = [:]
        if let primaries = av_map_videotoolbox_color_primaries_from_av(frame.pointee.color_primaries) {
            attachments[kCVImageBufferColorPrimariesKey as String] = primaries.takeRetainedValue()
        }
        if let transfer = av_map_videotoolbox_color_trc_from_av(frame.pointee.color_trc) {
            attachments[kCVImageBufferTransferFunctionKey as String] = transfer.takeRetainedValue()
        }
        if let matrix = av_map_videotoolbox_color_matrix_from_av(frame.pointee.colorspace) {
            attachments[kCVImageBufferYCbCrMatrixKey as String] = matrix.takeRetainedValue()
        }
        if let chromaLoc = av_map_videotoolbox_chroma_loc_from_av(frame.pointee.chroma_location) {
            attachments[kCVImageBufferChromaLocationTopFieldKey as String] = chromaLoc.takeRetainedValue()
        }

        // Pass through pixel aspect ratio from the CMFormatDescription so the display system handles anamorphic stretch
        if let sar = formatDescription.extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? [CFString: NSNumber],
            let num = sar[kCVImageBufferPixelAspectRatioHorizontalSpacingKey],
            let den = sar[kCVImageBufferPixelAspectRatioVerticalSpacingKey],
            num != den
        {
            attachments[kCVImageBufferPixelAspectRatioKey as String] = sar
        }

        // Add mastering display, content light level, and ambient viewing environment metadata
        if let mdmSideData = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) {
            let mdm = UnsafeRawPointer(mdmSideData.pointee.data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self).pointee
            if let bytes = VideoDecoder.serializeMasteringDisplayMetadata(mdm) {
                attachments[kCVImageBufferMasteringDisplayColorVolumeKey as String] = bytes
            }
        }
        if let cllSideData = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) {
            let cll = UnsafeRawPointer(cllSideData.pointee.data).assumingMemoryBound(to: AVContentLightMetadata.self).pointee
            if let bytes = VideoDecoder.serializeContentLightLevel(cll) {
                attachments[kCVImageBufferContentLightLevelInfoKey as String] = bytes
            }
        }
        if let aveSideData = av_frame_get_side_data(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT) {
            let ave = UnsafeRawPointer(aveSideData.pointee.data).assumingMemoryBound(to: AVAmbientViewingEnvironment.self).pointee
            if let bytes = VideoDecoder.serializeAmbientViewingEnvironment(ave) {
                attachments[kCVImageBufferAmbientViewingEnvironmentKey as String] = bytes
            }
        }

        return PixelBufferConfig(
            pixelBufferAttributes: [
                kCVPixelBufferWidthKey as String: frame.pointee.width as CFNumber,
                kCVPixelBufferHeightKey as String: frame.pointee.height as CFNumber,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64 as CFNumber,
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as CFBoolean,
                kCVBufferPropagatedAttachmentsKey as String: attachments,
            ],
            bitDepth: formatInfo.bitDepth,
            uvShiftX: formatInfo.uvShiftX,
            uvShiftY: formatInfo.uvShiftY
        )
    }

    // Convert a planar YUV 10/12/16-bit AVFrame to a biplanar 10-bit CVPixelBuffer.
    // Significant bits are left-justified in a 16-bit container (top 10 bits, bottom 6 bits zero).
    // Do this on the CPU since the source data is on the CPU, and the GPU will be busy doing color conversion and tonemapping
    func hdrConvertToBiPlanar(frame: UnsafePointer<AVFrame>, pixelBuffer: CVPixelBuffer) -> Error? {

        guard let config = pixelBufferConfig, config.isHDR else {
            return CVReturnError(errorCode: Int(kCVReturnUnsupported), context: "hdrConvertToBiPlanar")
        }

        let srcWidth = Int(frame.pointee.width)
        let srcHeight = Int(frame.pointee.height)
        let uvWidth = srcWidth >> Int(config.uvShiftX)
        let uvHeight = srcHeight >> Int(config.uvShiftY)

        // Calculate the bit shift to convert source bit depth to P010's left-justified 10-bit layout.
        // P010: 10 significant bits in bits [15:6], bottom 6 bits zero.
        // Net shift = 16 - bitDepth (always left shift, or no shift for 16-bit).
        // Source 10-bit: value in bits [9:0]  -> shift left by 6
        // Source 12-bit: value in bits [11:0] -> shift left by 4 (loses 2 LSBs)
        // Source 16-bit: value in bits [15:0] -> no shift (loses 6 LSBs)
        let shift = 16 - Int(config.bitDepth)

        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            return CVReturnError(errorCode: Int(status), context: "CVPixelBufferLockBaseAddress")
        }

        // -- Y plane: shift-copy from AVFrame plane 0 to CVPixelBuffer plane 0 --
        let srcYPtr = UnsafeMutableRawPointer(frame.pointee.data.0!).assumingMemoryBound(to: UInt16.self)
        let srcYStride = Int(frame.pointee.linesize.0) / MemoryLayout<UInt16>.size
        let dstYPtr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / MemoryLayout<UInt16>.size
        hdr_shift_copy(
            srcYPtr,
            dstYPtr,
            Int32(srcWidth),
            Int32(srcYStride),
            Int32(dstYStride),
            Int32(srcHeight),
            Int32(shift)
        )

        // -- CbCr plane: shift and interleave from AVFrame planes 1,2 to CVPixelBuffer plane 1 --
        let srcCbStride: Int =
            withUnsafePointer(to: frame.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 2) { Int($0[1]) }
            } / MemoryLayout<UInt16>.size
        let srcCrStride: Int =
            withUnsafePointer(to: frame.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 3) { Int($0[2]) }
            } / MemoryLayout<UInt16>.size
        let srcCbPtr = UnsafeMutableRawPointer(frame.pointee.data.1!).assumingMemoryBound(to: UInt16.self)
        let srcCrPtr = UnsafeMutableRawPointer(frame.pointee.data.2!).assumingMemoryBound(to: UInt16.self)
        let dstCbCrPtr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let dstCbCrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / MemoryLayout<UInt16>.size
        hdr_interleave_and_shift(
            srcCbPtr,
            srcCrPtr,
            dstCbCrPtr,
            Int32(uvWidth),
            Int32(srcCbStride),
            Int32(srcCrStride),
            Int32(dstCbCrStride),
            Int32(uvHeight),
            Int32(shift)
        )
        #if false
            logger.debug(
                "Input  #\(Int(frame.pointee.pts/1000)) y=\(frame.pointee.data.0!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }), u=\(frame.pointee.data.1!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }), v=\(frame.pointee.data.2!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee })"
            )
            logger.debug(
                "Output #\(Int(frame.pointee.pts/1000)) y=\(dstYPtr[0]) Cb=\(dstCbCrPtr[0]) Cr=\(dstCbCrPtr[1])"
            )
        #endif

        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return nil
    }

    // Serialize AVMasteringDisplayMetadata to 24 bytes big-endian matching HEVC SEI D.2.28, or nil if empty.
    //   display_primaries[3][2] in G,B,R order (uint16, units of 0.00002)
    //   white_point[2] (uint16, units of 0.00002)
    //   max_display_mastering_luminance (uint32, units of 0.0001 cd/m²)
    //   min_display_mastering_luminance (uint32, units of 0.0001 cd/m²)
    private static func serializeMasteringDisplayMetadata(_ mdm: AVMasteringDisplayMetadata) -> Data? {
        guard mdm.has_primaries != 0 || mdm.has_luminance != 0 else { return nil }

        var bytes = Data(count: 24)
        bytes.withUnsafeMutableBytes { buf in
            let u16 = buf.baseAddress!.assumingMemoryBound(to: UInt16.self)

            // Primaries in G, B, R order per HEVC SEI D.2.28.
            // FFmpeg stores as R=0, G=1, B=2, so (idx+1)%3 maps output 0,1,2 to FFmpeg's G=1, B=2, R=0.
            for idx in 0..<3 {
                let i = (idx + 1) % 3
                let primaries = withUnsafePointer(to: mdm.display_primaries) {
                    $0.withMemoryRebound(to: AVRational.self, capacity: 6) { p in
                        (p[i * 2], p[i * 2 + 1])
                    }
                }
                u16[idx * 2] = UInt16(clamping: Int(av_q2d(primaries.0) * 50000.0 + 0.5)).bigEndian
                u16[idx * 2 + 1] = UInt16(clamping: Int(av_q2d(primaries.1) * 50000.0 + 0.5)).bigEndian
            }

            // White point
            u16[6] = UInt16(clamping: Int(av_q2d(mdm.white_point.0) * 50000.0 + 0.5)).bigEndian
            u16[7] = UInt16(clamping: Int(av_q2d(mdm.white_point.1) * 50000.0 + 0.5)).bigEndian

            // Luminance (units of 0.0001 cd/m²)
            let u32 = buf.baseAddress!.assumingMemoryBound(to: UInt32.self)
            u32[4] = UInt32(clamping: Int64(av_q2d(mdm.max_luminance) * 10000.0 + 0.5)).bigEndian
            u32[5] = UInt32(clamping: Int64(av_q2d(mdm.min_luminance) * 10000.0 + 0.5)).bigEndian
        }
        return bytes
    }

    // Serialize AVContentLightMetadata to 4 bytes big-endian matching HEVC SEI content light level info, or nil if empty.
    //   max_content_light_level (uint16)
    //   max_pic_average_light_level (uint16)
    private static func serializeContentLightLevel(_ cll: AVContentLightMetadata) -> Data? {
        guard cll.MaxCLL > 0 || cll.MaxFALL > 0 else { return nil }

        var bytes = Data(count: 4)
        bytes.withUnsafeMutableBytes { buf in
            let u16 = buf.baseAddress!.assumingMemoryBound(to: UInt16.self)
            u16[0] = UInt16(clamping: cll.MaxCLL).bigEndian
            u16[1] = UInt16(clamping: cll.MaxFALL).bigEndian
        }
        return bytes
    }

    // Serialize AVAmbientViewingEnvironment to 8 bytes big-endian matching Ambient Viewing Environment SEI payload, or nil if empty.
    //   ambient_illuminance (uint32, units of 0.0001 lux)
    //   ambient_light_x (uint16, units of 0.00002)
    //   ambient_light_y (uint16, units of 0.00002)
    private static func serializeAmbientViewingEnvironment(_ ave: AVAmbientViewingEnvironment) -> Data? {
        let illuminance = UInt32(clamping: Int64(av_q2d(ave.ambient_illuminance) * 10000.0 + 0.5))
        guard illuminance > 0 else { return nil }

        var bytes = Data(count: 8)
        bytes.withUnsafeMutableBytes { buf in
            let u32 = buf.baseAddress!.assumingMemoryBound(to: UInt32.self)
            u32[0] = illuminance.bigEndian
            let u16 = buf.baseAddress!.assumingMemoryBound(to: UInt16.self)
            u16[2] = UInt16(clamping: Int(av_q2d(ave.ambient_light_x) * 50000.0 + 0.5)).bigEndian
            u16[3] = UInt16(clamping: Int(av_q2d(ave.ambient_light_y) * 50000.0 + 0.5)).bigEndian
        }
        return bytes
    }
}
