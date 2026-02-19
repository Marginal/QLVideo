//
//  videodecoder-zscale.swift
//
//  Format conversion using zscale filter, including for formats that require HDR tonemapping.
//

import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

struct ColorInfo {
    let primaries: AVColorPrimaries
    let transfer: AVColorTransferCharacteristic
    let matrix: AVColorSpace
}

// See https://www.ffmpeg.org/doxygen/trunk/filtering_video_8c-example.html

extension VideoDecoder {

    // Convert the decoded frame to GBRP float or 8bit depending on whether it's HDR or SDR, return the new frame
    func zscaleConvertToGBRP(frame: inout UnsafeMutablePointer<AVFrame>?, pixelBuffer: inout CVPixelBuffer) -> Error? {

        // Patch up the incoming frame
        let colorInfo = inferColors(frame: &frame!.pointee)
        frame!.pointee.color_primaries = colorInfo.primaries
        frame!.pointee.color_trc = colorInfo.transfer
        frame!.pointee.colorspace = colorInfo.matrix

        if filterGraph == nil {
            let error = zscaleSetup(frame: &frame!.pointee, pixelBuffer: &pixelBuffer)
            guard error == nil else { return error! }
        }

        /* push the decoded frame into the filtergraph */
        var ret = av_buffersrc_add_frame(src_ctx, frame)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "av_buffersrc_add_frame") }

        /* pull filtered frames from the filtergraph */
        var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        ret = av_buffersink_get_frame(sink_ctx, outFrame)
        guard ret == 0 else {
            av_frame_free(&outFrame)
            return AVERROR(errorCode: ret, context: "av_buffersink_get_frame")
        }
        var old: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&old)
        frame = outFrame

        return nil
    }

    private func zscaleSetup(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> Error? {

        let filterDesc = makeFilterChain(frame: &frame, pixelBuffer: &pixelBuffer)

        let bufferSrc = avfilter_get_by_name("buffer")
        let bufferSink = avfilter_get_by_name("buffersink")

        filterGraph = avfilter_graph_alloc()!

        /* buffer video source: the decoded frames from the decoder will be inserted here. */
        let srcArgs =
            "video_size=\(frame.width)x\(frame.height):pix_fmt=\(frame.format):colorspace=\(String(cString: av_color_space_name(frame.colorspace))):range=\(frame.color_range == AVCOL_RANGE_JPEG ? "pc" : "tv"):time_base=1/1000"  // time_base is required but irrelevant
        let sinkArgs = "pixel_formats=\(AV_PIX_FMT_GBRP.rawValue)"  // should use AV_PIX_FMT_GBRPF32LE for HDR to match tonemap output, but vImage conversion broken
        logger.debug(
            "VideDecoder using zscale with input \"\(srcArgs, privacy: .public)\", filter \"\(filterDesc, privacy: .public)\", output \"\(sinkArgs, privacy: .public)\""
        )

        var ret = avfilter_graph_create_filter(&src_ctx, bufferSrc, "in", srcArgs, nil, filterGraph)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_create_filter") }

        /* buffer video sink: to terminate the filter chain. */
        ret = avfilter_graph_create_filter(&sink_ctx, bufferSink, "out", sinkArgs, nil, filterGraph)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_create_filter") }

        /*
         * Set the endpoints for the filter graph. The filter_graph will
         * be linked to the graph described by filters_descr.
         */

        /*
         * The buffer source output must be connected to the input pad of
         * the first filter described by filters_descr; since the first
         * filter input label is not specified, it is set to "in" by
         * default.
         */
        var outputs = avfilter_inout_alloc()
        outputs!.pointee.name = strdup("in")
        outputs!.pointee.filter_ctx = src_ctx
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil

        /*
         * The buffer sink input must be connected to the output pad of
         * the last filter described by filters_descr; since the last
         * filter output label is not specified, it is set to "out" by
         * default.
         */
        var inputs = avfilter_inout_alloc()
        inputs!.pointee.name = strdup("out")
        inputs!.pointee.filter_ctx = sink_ctx
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        ret = avfilter_graph_parse_ptr(filterGraph, filterDesc.cString(using: .utf8), &inputs, &outputs, nil)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_parse_ptr") }

        ret = avfilter_graph_config(filterGraph, nil)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_config") }

        return nil
    }

    // zscale can't handle unspecifed info in the input AVFrame. Make educated guesses.
    private func inferColors(frame: inout AVFrame) -> ColorInfo {

        // Let presence of SMPTE 2086:2014 side data override anything else in the AVFrame
        if av_frame_get_side_data(&frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) != nil
            || av_frame_get_side_data(&frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) != nil
            || av_frame_get_side_data(&frame, AV_FRAME_DATA_DOVI_METADATA) != nil
        {
            return ColorInfo(
                primaries: AVCOL_PRI_BT2020,
                transfer: AVCOL_TRC_SMPTE2084,
                matrix: AVCOL_SPC_BT2020_NCL,
            )
        }

        // If all fields are specified then assume they're correct
        if frame.color_primaries != AVCOL_PRI_UNSPECIFIED
            && frame.color_trc != AVCOL_TRC_UNSPECIFIED
            && frame.colorspace != AVCOL_SPC_UNSPECIFIED
        {
            return ColorInfo(
                primaries: frame.color_primaries,
                transfer: frame.color_trc,
                matrix: frame.colorspace,
            )
        }

        // Explicit PQ or HLG
        if frame.color_trc == AVCOL_TRC_SMPTE2084 || frame.color_trc == AVCOL_TRC_ARIB_STD_B67 {
            return ColorInfo(
                primaries: frame.color_primaries != AVCOL_PRI_UNSPECIFIED ? frame.color_primaries : AVCOL_PRI_BT2020,
                transfer: frame.color_trc,
                matrix: frame.colorspace != AVCOL_SPC_UNSPECIFIED ? frame.colorspace : AVCOL_SPC_BT2020_NCL,
            )
        }

        // >8‑bit *with BT.2020 primaries* is probably HDR10.
        let pixDesc = av_pix_fmt_desc_get(AVPixelFormat(frame.format)).pointee
        let bitDepth = pixDesc.comp.0.depth  // not always accurate but works for supported formats
        if bitDepth > 8 && frame.color_primaries == AVCOL_PRI_BT2020 {
            return ColorInfo(
                primaries: AVCOL_PRI_BT2020,
                transfer: AVCOL_TRC_SMPTE2084,
                matrix: AVCOL_SPC_BT2020_NCL,
            )
        }

        // SDR. Assume values based on input format and whether HD or SD
        if frame.width >= 1280 || frame.height >= 720 || frame.color_range == AVCOL_RANGE_JPEG {
            return ColorInfo(
                primaries: AVCOL_PRI_BT709,
                transfer: AVCOL_TRC_BT709,
                matrix: AVCOL_SPC_BT709,
            )
        } else {
            return ColorInfo(
                primaries: AVCOL_PRI_SMPTE170M,
                transfer: AVCOL_TRC_BT709,  // This got retconned when HDR came out
                matrix: AVCOL_SPC_SMPTE170M,
            )
        }
    }

    private func makeFilterChain(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> String {

        // zscale accepts a smaller set of values than FFmpeg, and with different names than av_color_space_name() etc
        // https://ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Video/zscale.html

        let primariesMap: [AVColorPrimaries: String] = [
            AVCOL_PRI_BT709: "709",
            AVCOL_PRI_SMPTE170M: "170m",
            AVCOL_PRI_SMPTE240M: "240m",
            AVCOL_PRI_BT2020: "2020",
            AVCOL_PRI_BT470M: "709",  // SDR
        ]

        let transferMap: [AVColorTransferCharacteristic: String] = [
            AVCOL_TRC_BT709: "709",
            AVCOL_TRC_LINEAR: "linear",
            AVCOL_TRC_SMPTE2084: "smpte2084",  // PQ
            AVCOL_TRC_ARIB_STD_B67: "arib-std-b67",  // HLG
            AVCOL_TRC_BT2020_10: "2020_10",
            AVCOL_TRC_BT2020_12: "2020_12",
            AVCOL_TRC_IEC61966_2_1: "iec61966-2-1",  // sRGB
        ]

        let matrixmap: [AVColorSpace: String] = [
            AVCOL_SPC_BT709: "709",
            AVCOL_SPC_SMPTE170M: "170m",
            AVCOL_SPC_SMPTE240M: "240m",
            AVCOL_SPC_BT470BG: "470bg",
            AVCOL_SPC_BT2020_NCL: "2020_ncl",
            AVCOL_SPC_BT2020_CL: "2020_cl",
            AVCOL_SPC_FCC: "170m",  // Close enough
            AVCOL_SPC_ICTCP: "2020_ncl",  // Close enough
        ]

        // Specify color info in zscale syntax, use BT.709 for cases that zscale doesn't support
        let pin = primariesMap[frame.color_primaries] ?? "709"
        let tin = transferMap[frame.color_trc] ?? "709"
        let min = matrixmap[frame.colorspace] ?? "709"

        // pixelBuffer.width != frame.width for anamorphic
        let out_w = CVPixelBufferGetWidth(pixelBuffer)

        if frame.color_trc == AVCOL_TRC_SMPTE2084 || frame.color_trc == AVCOL_TRC_ARIB_STD_B67 {
            // HDR content
            return """
                zscale=w=\(out_w):h=\(frame.height):f=lanczos:pin=\(pin):tin=\(tin):min=\(min):primaries=709:transfer=linear:matrix=709:npl=100,
                tonemap=hable
                """
        } else if frame.color_primaries == AVCOL_PRI_BT709 && frame.color_trc == AVCOL_TRC_BT709
            && frame.colorspace == AVCOL_SPC_BT709
        {
            // SDR content that's already in (or we've assumed to be in) BT.709
            return "scale=w=\(out_w):h=\(frame.height):sws_flags=lanczos"
        } else {
            // SDR content - SD or HD
            return
                "zscale=w=\(out_w):h=\(frame.height):f=lanczos:pin=\(pin):tin=\(tin):min=\(min):primaries=709:transfer=709:matrix=709"
        }
    }
}
