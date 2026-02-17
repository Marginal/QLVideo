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

    // Avoid concurrency issues with kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 etc by specifying explicitly
    static let colorMatrices: [AVColorSpace: vImage_YpCbCrToARGBMatrix] = [
        AVCOL_SPC_BT470BG: vImage_YpCbCrToARGBMatrix(Yp: 1.0, Cr_R: 1.402, Cr_G: -0.714136, Cb_G: -0.344136, Cb_B: 1.772),  // kvImage_YpCbCrToARGBMatrix_ITU_R_601_4
        AVCOL_SPC_SMPTE170M: vImage_YpCbCrToARGBMatrix(Yp: 1.0, Cr_R: 1.402, Cr_G: -0.714136, Cb_G: -0.344136, Cb_B: 1.772),  // kvImage_YpCbCrToARGBMatrix_ITU_R_601_4
        AVCOL_SPC_SMPTE240M: vImage_YpCbCrToARGBMatrix(Yp: 1.0, Cr_R: 1.5748, Cr_G: -0.187324, Cb_G: -0.468124, Cb_B: 1.8556),  // using BT.709
        AVCOL_SPC_BT709: vImage_YpCbCrToARGBMatrix(Yp: 1.0, Cr_R: 1.5748, Cr_G: -0.187324, Cb_G: -0.468124, Cb_B: 1.8556),  // kvImage_YpCbCrToARGBMatrix_ITU_R_709_2
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

    func vImageConvertToARGB(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> Error? {

        let format = VideoDecoder.vImageTypes[AVPixelFormat(frame.format)]!
        let width = Int(frame.width)
        let height = Int(frame.height)

        if conversionInfo == nil {
            var range = VideoDecoder.pixelRanges[frame.color_range == AVCOL_RANGE_JPEG]
            var matrix = VideoDecoder.colorMatrices[frame.colorspace]
            if matrix == nil {
                matrix = VideoDecoder.colorMatrices[width < 1280 && height < 720 ? AVCOL_SPC_BT470BG : AVCOL_SPC_BT709]
                let colorspace = frame.colorspace
                logger.log(
                    "VideoDecoder unsupported colorspace \"\(String(cString: av_color_space_name(colorspace)), privacy: .public)\" for vImageConvert. Defaulting to \(width < 1280 && height < 720 ? "BT.601" : "BT.709", privacy: .public)"
                )
            }
            conversionInfo = vImage_YpCbCrToARGB()
            let ret = vImageConvert_YpCbCrToARGB_GenerateConversion(
                &matrix!,
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
            logger.debug("VideoDecoder using vImageConvert for format conversion")
        }

        // Wrap destination
        var dstBGRA = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )

        var ret: vImage_Error
        switch format {
        case kvImage420Yp8_Cb8_Cr8:  // AV_PIX_FMT_YUV420P
            var srcY = vImage_Buffer(
                data: frame.data.0,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: Int(frame.linesize.0)
            )
            var srcCb = vImage_Buffer(
                data: frame.data.1,
                height: vImagePixelCount(height / 2),
                width: vImagePixelCount(width / 2),
                rowBytes: Int(frame.linesize.1)
            )
            var srcCr = vImage_Buffer(
                data: frame.data.2,
                height: vImagePixelCount(height / 2),
                width: vImagePixelCount(width / 2),
                rowBytes: Int(frame.linesize.2)
            )
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
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: Int(frame.linesize.0)
            )
            var srcCbCr = vImage_Buffer(
                data: frame.data.1,  // interleaved CbCr
                height: vImagePixelCount(height / 2),
                width: vImagePixelCount(width / 2),
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
        case kvImage422CbYpCrYp8:  // AV_PIX_FMT_YUYV422
            var srcPacked = vImage_Buffer(
                data: frame.data.0,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
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
}
