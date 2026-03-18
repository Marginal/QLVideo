//
//  MetalToneMapper.swift
//  QLVideo
//
//  Metal-based HDR tone mapping and colorspace conversion to BGRA8, avoiding CPU zscale.
//  Designed to be used for HDR10 / HLG streams decoded via FFmpeg (not VideoToolbox).
//
//  Input: AVFrame (typically 10/12-bit YUV420/422 in BT.2020 PQ/HLG).
//  Output: BGRA8 into a Metal-backed CVPixelBuffer (e.g. IOSurface-backed as allocated in videodecoder.swift).
//

import CoreVideo
import Foundation
import Metal
import MetalKit

// Matches Metal struct in hdr_tonemap.metal
private struct HDRParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var scenePeak: Float
    var colorTransfer: UInt32
    var colorRange: UInt32
}

class MetalToneMapper {
    struct HDRMetadata {
        var masteringMaxLuminance: Float = 1000.0
        var masteringMinLuminance: Float = 0.001
        var maxCLL: Float = 1000.0
        var maxFALL: Float = 400.0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var streamDefaults = HDRMetadata()

    // Returns true if this frame can be processed
    class func supported(for frame: UnsafePointer<AVFrame>) -> Bool {
        // Only support yuv420p10 input for now
        guard frame.pointee.format == AV_PIX_FMT_YUV420P10LE.rawValue else { return false }

        let trc = frame.pointee.color_trc
        if trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67 { return true }  // PQ or HLG

        let hasHdrSideData: Bool = [
            AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,
            AV_FRAME_DATA_CONTENT_LIGHT_LEVEL,
            AV_FRAME_DATA_DOVI_METADATA,
            AV_FRAME_DATA_DYNAMIC_HDR_PLUS,
            AV_FRAME_DATA_DYNAMIC_HDR_VIVID,
        ].contains { av_frame_get_side_data(frame, $0) != nil }

        return hasHdrSideData
    }

    init?(from params: UnsafePointer<AVCodecParameters>) {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.queue = queue
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
            guard let kernel = library.makeFunction(name: "hdrTonemapYUV420P10ToBGRA8") else { return nil }
            pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            return nil
        }

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        if let mdmSideData = av_packet_side_data_get(
            params.pointee.coded_side_data,
            params.pointee.nb_coded_side_data,
            AV_PKT_DATA_MASTERING_DISPLAY_METADATA
        ) {
            let mdmPtr = UnsafeRawPointer(mdmSideData.pointee.data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
            if mdmPtr.pointee.has_luminance != 0 {
                streamDefaults.masteringMaxLuminance = Float(av_q2d(mdmPtr.pointee.max_luminance))
                streamDefaults.masteringMinLuminance = Float(av_q2d(mdmPtr.pointee.min_luminance))
            }
        }
        if let cllSideData = av_packet_side_data_get(
            params.pointee.coded_side_data,
            params.pointee.nb_coded_side_data,
            AV_PKT_DATA_CONTENT_LIGHT_LEVEL
        ) {
            let cllPtr = UnsafeRawPointer(cllSideData.pointee.data).assumingMemoryBound(to: AVContentLightMetadata.self)
            if cllPtr.pointee.MaxCLL > 0 { streamDefaults.maxCLL = Float(cllPtr.pointee.MaxCLL) }
            if cllPtr.pointee.MaxFALL > 0 { streamDefaults.maxFALL = Float(cllPtr.pointee.MaxFALL) }
        }
    }

    // Main entry point: tone map and write into destination BGRA8 pixelBuffer.
    func process(frame: UnsafePointer<AVFrame>, pixelBuffer: CVPixelBuffer) -> Error? {
        guard let textureCache else { return AVERROR(errorCode: AVERROR_UNKNOWN, context: "metal texture cache") }
        // Expect 3-plane 4:2:0 YUV420P10 (10-bit in 16-bit container)
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return AVERROR(errorCode: AVERROR_UNKNOWN, context: "dest pixelBuffer not BGRA")
        }

        let srcWidth = Int(frame.pointee.width)
        let srcHeight = Int(frame.pointee.height)

        // Create Metal textures for Y, U, V planes from AVFrame data
        guard let yTex = makePlaneTexture(width: srcWidth, height: srcHeight, plane: 0, frame: frame),
            let uTex = makePlaneTexture(width: srcWidth / 2, height: srcHeight / 2, plane: 1, frame: frame),
            let vTex = makePlaneTexture(width: srcWidth / 2, height: srcHeight / 2, plane: 2, frame: frame)
        else {
            return AVERROR(errorCode: AVERROR_UNKNOWN, context: "create plane textures")
        }

        // Output texture from the destination pixel buffer (BGRA8)
        let dstWidth = CVPixelBufferGetWidth(pixelBuffer)
        let dstHeight = CVPixelBufferGetHeight(pixelBuffer)
        var outTexRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            dstWidth,
            dstHeight,
            0,
            &outTexRef
        )
        guard status == kCVReturnSuccess, let outTex = CVMetalTextureGetTexture(outTexRef!) else {
            return AVERROR(errorCode: AVERROR_UNKNOWN, context: "failed output texture")
        }

        let metadata = extractHDRMetadata(frame: frame)
        var params = HDRParams(
            srcWidth: UInt32(srcWidth),
            srcHeight: UInt32(srcHeight),
            dstWidth: UInt32(dstWidth),
            dstHeight: UInt32(dstHeight),
            scenePeak: chooseScenePeak(from: metadata, colorTransfer: frame.pointee.color_trc),
            colorTransfer: UInt32(frame.pointee.color_trc.rawValue),
            colorRange: UInt32(frame.pointee.color_range.rawValue)
        )

        #if false
            logger.debug(
                "HDRParams scenePeak=\(params.scenePeak) colorTransfer=\(params.colorTransfer) colorRange=\(params.colorRange) metadata=CLL:\(metadata.maxCLL)/FALL:\(metadata.maxFALL)/masterMax:\(metadata.masteringMaxLuminance)/masterMin:\(metadata.masteringMinLuminance)"
            )
            logger.debug(
                "Input  #\(Int(frame.pointee.pts/1000)) y=\(frame.pointee.data.0!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }), u=\(frame.pointee.data.1!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }), v=\(frame.pointee.data.2!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee })"
            )
        #endif

        guard let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return AVERROR(errorCode: AVERROR_UNKNOWN, context: "command buffer")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(yTex, index: 0)
        encoder.setTexture(uTex, index: 1)
        encoder.setTexture(vTex, index: 2)
        encoder.setTexture(outTex, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<HDRParams>.size, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: dstWidth, height: dstHeight, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #if false
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let data = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            logger.debug(
                "Output #\(Int(frame.pointee.pts/1000)) b=\(data[0]), g=\(data[1]), r=\(data[2]), a=\(data[3])"
            )
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        #endif

        return commandBuffer.error
    }

    private func chooseScenePeak(from metadata: HDRMetadata, colorTransfer: AVColorTransferCharacteristic) -> Float {
        if colorTransfer == AVCOL_TRC_ARIB_STD_B67 {
            if metadata.maxFALL > 1.0 {
                return max(metadata.maxFALL, 200.0)
            }
            if metadata.maxCLL > 1.0 {
                return min(max(metadata.maxCLL * 0.5, 200.0), 1000.0)
            }
            return 400.0
        }

        var scenePeak: Float = metadata.maxCLL > 1.0 ? metadata.maxCLL : 0.0
        if metadata.masteringMaxLuminance > 1.0 {
            scenePeak = scenePeak > 0.0 ? min(scenePeak, metadata.masteringMaxLuminance) : metadata.masteringMaxLuminance
        }
        if scenePeak <= 0.0 && metadata.maxFALL > 1.0 {
            scenePeak = max(metadata.maxFALL * 2.0, 200.0)
        }
        return scenePeak > 0.0 ? scenePeak : 1000.0
    }

    private func makePlaneTexture(width: Int, height: Int, plane: Int, frame: UnsafePointer<AVFrame>) -> MTLTexture? {
        guard let dataPtr = frame.pointee.extended_data?[plane] else { return nil }
        let bytesPerRow: Int32 = withUnsafePointer(to: frame.pointee.linesize) {
            $0.withMemoryRebound(to: Int32.self, capacity: plane + 1) { ptr in ptr[plane] }
        }
        let length = Int(bytesPerRow) * height
        guard let buffer = device.makeBuffer(bytesNoCopy: dataPtr, length: length, options: [], deallocator: nil) else {
            return nil
        }
        if buffer.storageMode == .managed { buffer.didModifyRange(0..<length) }  // Intel Macs
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = buffer.storageMode
        desc.usage = .shaderRead
        return buffer.makeTexture(descriptor: desc, offset: 0, bytesPerRow: Int(bytesPerRow))
    }

    // Override stream HDR metadata (MDM/CLL) with per-frame side data (MDM/CLL/HDR10+/Vivid)
    private func extractHDRMetadata(frame: UnsafePointer<AVFrame>) -> HDRMetadata {
        var meta = streamDefaults  // from the stream-level side data

        if let mdmSideData = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) {
            let mdmPtr = UnsafeRawPointer(mdmSideData.pointee.data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
            if mdmPtr.pointee.has_luminance != 0 {
                meta.masteringMaxLuminance = Float(av_q2d(mdmPtr.pointee.max_luminance))
                meta.masteringMinLuminance = Float(av_q2d(mdmPtr.pointee.min_luminance))
            }
        }

        if let cllSideData = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) {
            let cllPtr = UnsafeRawPointer(cllSideData.pointee.data).assumingMemoryBound(to: AVContentLightMetadata.self)
            if cllPtr.pointee.MaxCLL > 0 { meta.maxCLL = Float(cllPtr.pointee.MaxCLL) }
            if cllPtr.pointee.MaxFALL > 0 { meta.maxFALL = Float(cllPtr.pointee.MaxFALL) }
        }

        if let hdr10Plus = av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS) {
            let dynPtr = UnsafeRawPointer(hdr10Plus.pointee.data).assumingMemoryBound(to: AVDynamicHDRPlus.self)
            let tmax = Float(av_q2d(dynPtr.pointee.targeted_system_display_maximum_luminance))
            if tmax > 0 { meta.maxCLL = tmax }
        }

        if let vivid = av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_VIVID) {
            let vivPtr = UnsafeRawPointer(vivid.pointee.data).assumingMemoryBound(to: AVDynamicHDRVivid.self)
            if vivPtr.pointee.num_windows > 0 {
                let param = vivPtr.pointee.params.0  // first window only
                if param.tone_mapping_param_num > 0 {
                    let tm = param.tm_params.0  // first tone-mapping param
                    let tmax = Float(av_q2d(tm.targeted_system_display_maximum_luminance))
                    if tmax > 0 { meta.maxCLL = tmax }
                }
            }
        }

        return meta
    }

}
