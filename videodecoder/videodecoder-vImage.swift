//
//  videodecoder-vImage.swift
//  QLVideo
//
//  Accelerated format conversion using vImage for supported formats (basically just yuv420p in practice)
//

import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

// Swift Error wrapper for CoreVideo CVReturn codes
struct vImageError: LocalizedError, CustomNSError {
    let status: vImage_Error
    let context: String?

    static var errorDomain: String { "vImageErrorDomain" }
    var errorCode: Int { Int(status) }
    var errorDescription: String? { "\(context ?? "") failed with vImage_Error \(status)" }
}

extension VideoDecoder {

    static let colorMatrices: [AVColorSpace: UnsafePointer<vImage_YpCbCrToARGBMatrix>] = [
        AVCOL_SPC_BT470BG: kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE170M: kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE240M: kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
        AVCOL_SPC_BT709: kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
    ]

    static let pixelRanges: [Bool: vImage_YpCbCrPixelRange] = [
        // Full range
        true: vImage_YpCbCrPixelRange(
            Yp_bias: 0,
            CbCr_bias: 128,
            YpRangeMax: 255,
            CbCrRangeMax: 255,
            YpMax: 255,
            YpMin: 0,
            CbCrMax: 255,
            CbCrMin: 0
        ),
        // Video range
        false: vImage_YpCbCrPixelRange(
            Yp_bias: 16,
            CbCr_bias: 128,
            YpRangeMax: 235,
            CbCrRangeMax: 240,
            YpMax: 235,
            YpMin: 16,
            CbCrMax: 240,
            CbCrMin: 16
        ),
    ]

    /* Supported common formats  */
    static let vImageTypes: [AVPixelFormat: vImageYpCbCrType] = [
        AV_PIX_FMT_YUV420P: kvImage420Yp8_Cb8_Cr8,  // 8‑bit 4:2:0 planar 'y420'
        AV_PIX_FMT_YUVJ420P: kvImage420Yp8_Cb8_Cr8,  // 8‑bit 4:2:0 planar 'f420' full range
        AV_PIX_FMT_NV12: kvImage420Yp8_CbCr8,  // 8‑bit 4:2:0 bi‑planar '420v' / '420f'
        AV_PIX_FMT_YUYV422: kvImage422CbYpCrYp8,  // 8‑bit 4:2:2 packed '2vuy'
        AV_PIX_FMT_YUVJ422P: kvImage422CbYpCrYp8,  // 8‑bit 4:2:2 packed '2vuf' full range
    ]

    // Convert supported formats to BGRA using vImage
    func vImageConvertToBGRA(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> vImageError? {

        guard let format = VideoDecoder.vImageTypes[AVPixelFormat(frame.format)] else {
            return vImageError(status: kvImageUnsupportedConversion, context: "vImageConvertToBGRA")
        }
        let srcWidth = Int(frame.width)
        let srcHeight = Int(frame.height)
        let dstWidth = Int(CVPixelBufferGetWidth(pixelBuffer))
        let dstHeight = Int(CVPixelBufferGetHeight(pixelBuffer))

        if srcWidth != dstWidth && format != kvImage420Yp8_Cb8_Cr8 {
            return vImageError(status: kvImageUnsupportedConversion, context: "vImageConvertToBGRA")  // Can only handle anamorphic if yuv420p
        }

        if conversionInfo == nil {
            var range = VideoDecoder.pixelRanges[frame.color_range == AVCOL_RANGE_JPEG]
            var matrix = VideoDecoder.colorMatrices[frame.colorspace]
            if matrix == nil {
                matrix = VideoDecoder.colorMatrices[dstWidth < 1280 && dstHeight < 720 ? AVCOL_SPC_BT470BG : AVCOL_SPC_BT709]
                if frame.colorspace != AVCOL_SPC_UNSPECIFIED {
                    let colorspace = frame.colorspace
                    logger.log(
                        "VideoDecoder unsupported colorspace \"\(String(cString: av_color_space_name(colorspace)), privacy: .public)\" for vImageConvert. Defaulting to \(dstWidth < 1280 && dstHeight < 720 ? "BT.601" : "BT.709", privacy: .public)"
                    )
                }
            }
            conversionInfo = vImage_YpCbCrToARGB()
            let ret = vImageConvert_YpCbCrToARGB_GenerateConversion(
                matrix!,
                &range!,
                &conversionInfo!,
                format,
                kvImageARGB8888,
                vImage_Flags(kvImageNoFlags)
            )
            guard ret == kvImageNoError else {
                let error = vImageError(status: ret, context: "vImageConvert_YpCbCrToARGB_GenerateConversion")
                return error
            }
            if srcWidth != dstWidth {
                let error = vImageAllocateScaleBuffers(
                    format: format,
                    srcWidth: srcWidth,
                    srcHeight: srcHeight,
                    dstWidth: dstWidth,
                    dstHeight: dstHeight
                )
                guard error == nil else { return error }
            }
            logger.debug("VideoDecoder using vImageConvert for format conversion")
        }

        // Wrap destination
        var dstBGRA = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self),
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )

        var ret: vImage_Error
        switch format {
        case kvImage420Yp8_Cb8_Cr8:  // AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P
            var srcY = vImage_Buffer(
                data: frame.data.0,
                height: vImagePixelCount(srcHeight),
                width: vImagePixelCount(srcWidth),
                rowBytes: Int(frame.linesize.0)
            )
            var srcCb = vImage_Buffer(
                data: frame.data.1,
                height: vImagePixelCount(srcHeight / 2),
                width: vImagePixelCount(srcWidth / 2),
                rowBytes: Int(frame.linesize.1)
            )
            var srcCr = vImage_Buffer(
                data: frame.data.2,
                height: vImagePixelCount(srcHeight / 2),
                width: vImagePixelCount(srcWidth / 2),
                rowBytes: Int(frame.linesize.2)
            )
            if srcWidth != dstWidth {
                vImageScale_Planar8(&srcY, &scaleYBuffer!, scaleYTemp, vImage_Flags(kvImageEdgeExtend))
                vImageScale_Planar8(&srcCb, &scaleCbBuffer!, scaleCbTemp, vImage_Flags(kvImageEdgeExtend))
                vImageScale_Planar8(&srcCr, &scaleCrBuffer!, scaleCrTemp, vImage_Flags(kvImageEdgeExtend))
                srcY = scaleYBuffer!
                srcCb = scaleCbBuffer!
                srcCr = scaleCrBuffer!
            }
            ret = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
                &srcY,
                &srcCb,
                &srcCr,
                &dstBGRA,
                &conversionInfo!,
                [3, 2, 1, 0],  // ARGB -> BGRA
                0xff,  // alpha
                vImage_Flags(kvImageNoFlags)
            )
        case kvImage420Yp8_CbCr8:  // AV_PIX_FMT_NV12
            var srcY = vImage_Buffer(
                data: frame.data.0,
                height: vImagePixelCount(srcHeight),
                width: vImagePixelCount(srcWidth),
                rowBytes: Int(frame.linesize.0)
            )
            var srcCbCr = vImage_Buffer(
                data: frame.data.1,  // interleaved CbCr
                height: vImagePixelCount(srcHeight / 2),
                width: vImagePixelCount(srcWidth / 2),
                rowBytes: Int(frame.linesize.1)
            )
            ret = vImageConvert_420Yp8_CbCr8ToARGB8888(
                &srcY,
                &srcCbCr,
                &dstBGRA,
                &conversionInfo!,
                [3, 2, 1, 0],  // ARGB -> BGRA,
                0xff,  // alpha
                vImage_Flags(kvImageNoFlags)
            )
        case kvImage422CbYpCrYp8:  // AV_PIX_FMT_YUYV422, AV_PIX_FMT_YUVJ422P
            var srcPacked = vImage_Buffer(
                data: frame.data.0,
                height: vImagePixelCount(srcHeight),
                width: vImagePixelCount(srcWidth),
                rowBytes: Int(frame.linesize.0)
            )
            ret = vImageConvert_422CbYpCrYp8ToARGB8888(
                &srcPacked,
                &dstBGRA,
                &conversionInfo!,
                [3, 2, 1, 0],  // ARGB -> BGRA,
                0xff,  // alpha
                vImage_Flags(kvImageNoFlags)
            )
        default:
            ret = kvImageUnsupportedConversion  // Shouldn't get here
        }
        guard ret == kvImageNoError else {
            let error = vImageError(status: ret, context: "vImageConvert")
            return error
        }
        return nil
    }

    // Reusable scaling buffers & temp storage for vImage scaling
    private func vImageAllocateScaleBuffers(
        format: vImageYpCbCrType,
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int
    ) -> vImageError? {
        guard dstWidth != srcWidth else {
            return vImageError(status: kvImageInternalError, context: "vImageAllocateScaleBuffers: no scaling needed")
        }
        guard
            scaleYBuffer == nil && scaleCbBuffer == nil && scaleCrBuffer == nil && scaleYTemp == nil && scaleCbTemp == nil
                && scaleCrTemp == nil
        else {
            return vImageError(status: kvImageInternalError, context: "vImageAllocateScaleBuffers: no scaling needed")
        }

        // Y plane buffers (8 bpp)
        let (yAlign, yRowBytes) = try! vImage_Buffer.preferredAlignmentAndRowBytes(
            width: dstWidth,
            height: dstHeight,
            bitsPerPixel: 8
        )
        scaleYBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: yRowBytes * dstHeight, alignment: yAlign),
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: yRowBytes
        )

        // Cb/Cr planes (8 bpp, half resolution)
        let cWidth = max(1, dstWidth / 2)
        let cHeight = max(1, dstHeight / 2)
        let (cAlign, cRowBytes) = try! vImage_Buffer.preferredAlignmentAndRowBytes(
            width: cWidth,
            height: cHeight,
            bitsPerPixel: 8
        )
        scaleCbBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: cRowBytes * cHeight, alignment: cAlign),
            height: vImagePixelCount(cHeight),
            width: vImagePixelCount(cWidth),
            rowBytes: cRowBytes
        )
        scaleCrBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: cRowBytes * cHeight, alignment: cAlign),
            height: vImagePixelCount(cHeight),
            width: vImagePixelCount(cWidth),
            rowBytes: cRowBytes
        )

        // temp buffers sized per plane
        var sz = vImageScale_Planar8(&scaleYBuffer!, &scaleYBuffer!, nil, vImage_Flags(kvImageGetTempBufferSize))
        guard sz > 0 else { return vImageError(status: sz, context: "vImageScale_Planar8") }
        scaleYTemp = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: yAlign)
        sz = vImageScale_Planar8(&scaleCbBuffer!, &scaleCbBuffer!, nil, vImage_Flags(kvImageGetTempBufferSize))
        guard sz > 0 else { return vImageError(status: sz, context: "vImageScale_Planar8") }
        scaleCbTemp = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: cAlign)
        sz = vImageScale_Planar8(&scaleCrBuffer!, &scaleCrBuffer!, nil, vImage_Flags(kvImageGetTempBufferSize))
        guard sz > 0 else { return vImageError(status: sz, context: "vImageScale_Planar8") }
        scaleCrTemp = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: cAlign)
        return nil
    }

    func vImageFreeScaleBuffers() {
        if let y = scaleYBuffer?.data { y.deallocate() }
        if let cb = scaleCbBuffer?.data { cb.deallocate() }
        if let cr = scaleCrBuffer?.data { cr.deallocate() }
        if let scaleYTemp { scaleYTemp.deallocate() }
        if let scaleCbTemp { scaleCbTemp.deallocate() }
        if let scaleCrTemp { scaleCrTemp.deallocate() }
        scaleYBuffer = nil
        scaleCbBuffer = nil
        scaleCrBuffer = nil
        scaleYTemp = nil
        scaleCbTemp = nil
        scaleCrTemp = nil
    }

    // Copy supported formats to BGRA using vImage (no conversion)
    func vImageCopyToBGRA(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> Error? {
        let width = Int(frame.width)
        let height = Int(frame.height)

        var srcG = vImage_Buffer(
            data: frame.data.0,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: Int(frame.linesize.0)
        )
        var srcB = vImage_Buffer(
            data: frame.data.1,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: Int(frame.linesize.1)
        )
        var srcR = vImage_Buffer(
            data: frame.data.2,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: Int(frame.linesize.2)
        )
        var dst = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )

        var ret: vImage_Error = kvImageNoError
        switch frame.format {
        case AV_PIX_FMT_GBRPF32LE.rawValue:
            // HDR path: float planar to BGRA
            var maxFloat: Float = 1
            var minFloat: Float = 0
            ret = vImageConvert_PlanarFToBGRX8888(&srcB, &srcG, &srcR, 0xff, &dst, &maxFloat, &minFloat, 0)
        case AV_PIX_FMT_GBRP.rawValue:
            // SDR path: 8-bit planar to BGRA
            ret = vImageConvert_Planar8ToBGRX8888(&srcB, &srcG, &srcR, 0xff, &dst, 0)
        default:
            ret = kvImageUnsupportedConversion  // Shouldn't get here
        }
        guard ret == kvImageNoError else {
            let error = vImageError(status: ret, context: "vImageConvert")
            return error
        }
        return nil
    }
}
