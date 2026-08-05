//
//  decodedsamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide packets of audio data converted to PCM.
//  Used to supply audio data for formats that CoreAudio doesn't understand.
//

import MediaExtension

class DecodedSampleCursor: SampleCursor {

    // used by stepInDecodeOrderByCount
    var lastDelivered = 0
    var nextHandle: PacketHandle? = nil

    override init(format: FormatReader, track: TrackReader, index: Int, atPresentationTimeStamp presentationTimeStamp: CMTime)
        throws
    {
        try super.init(format: format, track: track, index: index, atPresentationTimeStamp: presentationTimeStamp)
        self.lastDelivered = 0
        self.nextHandle = nil
    }

    init(copying: DecodedSampleCursor) {
        super.init(copying: copying)
        self.lastDelivered = copying.lastDelivered
        self.nextHandle = copying.nextHandle
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        return DecodedSampleCursor(copying: self)
    }

    // https://developer.apple.com/documentation/mediaextension/mesamplecursor
    // Core Media's preferred way of accessing sample data is to be provided with an offset and length into
    // the file via sampleLocation() and chunkDetails(), and reading it directly. But FFmpeg doesn't expose this info.
    // FFmpeg works by reading data from the file until it has a valid packet for one of the streams.
    override func loadSampleBufferContainingSamples(
        to endSampleCursor: (any MESampleCursor)?,
        completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void
    ) {
        guard let track = track as? AudioTrackReader,
            let endSampleCursor = endSampleCursor as? SampleCursor,
            let startPkt = demuxer?.get(stream: streamIndex, handle: handle),
            let endPkt = demuxer?.get(stream: streamIndex, handle: endSampleCursor.handle)
        else {
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public)"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public) packetCount=\(endSampleCursor.handle.index - self.handle.index + 1)"
            )
        }

        let sampleFormat = AVSampleFormat(track.stream.pointee.codecpar.pointee.format)
        var sampleSize =
        Int(av_get_bytes_per_sample(sampleFormat)) * Int(track.stream.pointee.codecpar.pointee.ch_layout.nb_channels)
        let sampleRate = track.stream.pointee.codecpar.pointee.sample_rate
        let duration =
            endPkt.pointee.pts != AV_NOPTS_VALUE && startPkt.pointee.pts != AV_NOPTS_VALUE
            ? AVRational(
                num: Int32(endPkt.pointee.pts - startPkt.pointee.pts + endPkt.pointee.duration)
                * track.stream.pointee.time_base.num,
                den: track.stream.pointee.time_base.den
            )
            : AVRational(
                num: Int32(endSampleCursor.handle.index - self.handle.index + 1)
                * Int32(startPkt.pointee.duration) * track.stream.pointee.time_base.num,
                den: track.stream.pointee.time_base.den
            )  // Workaround for invalid PTSs after a seek - e.g. Cook in RealMedia
        var sampleCount = Int(av_q2d(av_mul_q(duration, AVRational(num: sampleRate, den: 1))).rounded(.up))
        var frameSize = Int(track.stream.pointee.codecpar.pointee.frame_size)
        if frameSize == 0 { frameSize = 1024 }  // arbitrary but it's better to slightly over allocate to avoid realloc later
        let remainder = sampleCount % frameSize
        if remainder != 0 { sampleCount += frameSize - remainder }
        var capacity = sampleSize * sampleCount
        var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let frame = av_frame_alloc()!

        if discontinuity { avcodec_flush_buffers(track.dec_ctx) }
        lastDelivered = 0

        // decode packets and add the decoded data to the blockBuffer
        for idx in handle.index...endSampleCursor.handle.index {
            // we only expect to be asked to provide data in the range of packets that we've previously reported as
            // existing, so treat any errors in retreiving and decoding as unexpected and unrecoverable
            nextHandle = PacketHandle(generation: handle.generation, index: idx, isLast: false)
            guard let pkt = demuxer?.get(stream: streamIndex, handle: nextHandle!) else {
                logger.error(
                    "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(idx) [no packet] loadSampleBufferContainingSamples"
                )
                break
            }
            var ret = avcodec_send_packet(track.dec_ctx, pkt)
            if ret < 0 {
                let error = AVERROR(errorCode: ret, context: "avcodec_send_packet")
                logger.warning(
                    "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: \(error.errorDescription, privacy: .public)"
                )
                if ret == AVERROR_INVALIDDATA { continue }  // Hope AVFoundation can cope with missed data
                return completionHandler(nil, error)
            }

            while true {
                ret = avcodec_receive_frame(track.dec_ctx, frame)
                if ret == AVERROR_EAGAIN {
                    break
                } else if ret < 0 {
                    let error = AVERROR(errorCode: ret, context: "avcodec_receive_frame")
                    logger.error(
                        "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: \(error.errorDescription, privacy: .public)"
                    )
                    return completionHandler(nil, error)
                }

                let offset = lastDelivered * sampleSize
                let reqdBytes = Int(frame.pointee.nb_samples) * sampleSize  // for this frame's data
                if capacity < offset + reqdBytes {
                    logger.debug(
                        "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: Resizing output buffer from \(capacity) to \(capacity + sampleSize * Int(frame.pointee.nb_samples))"
                    )
                    let newCapacity = capacity + reqdBytes
                    let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
                    newBuffer.update(from: buffer, count: capacity)
                    buffer.deallocate()
                    buffer = newBuffer
                    capacity = newCapacity
                }

                var outPtr: UnsafeMutablePointer<UInt8>? = buffer.advanced(by: offset)
                if track.swr_ctx != nil {
                    // CoreMedia doesn't like planar PCM (error "SSP::Render: CopySlice returned 1") so convert to packed/interleaved
                    // http://www.openradar.me/45068930
                    let inPtrs: UnsafePointer<UnsafePointer<UInt8>?>? = frame.pointee.extended_data?.withMemoryRebound(
                        to: UnsafePointer<UInt8>?.self,
                        capacity: Int(track.stream.pointee.codecpar.pointee.ch_layout.nb_channels)
                    ) { return UnsafePointer($0) }
                    ret = swr_convert(
                        track.swr_ctx,
                        &outPtr,
                        Int32((capacity - offset) / sampleSize),
                        inPtrs,
                        Int32(frame.pointee.nb_samples)
                    )
                    if ret < 0 {
                        let error = AVERROR(errorCode: ret, context: "swr_convert")
                        logger.error(
                            "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: \(error.errorDescription, privacy: .public)"
                        )
                        return completionHandler(nil, error)
                    }
                    assert(
                        ret == frame.pointee.nb_samples,
                        "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples: Expected \(frame.pointee.nb_samples), received \(ret) samples"
                    )
                    lastDelivered += Int(ret)
                } else {
                    assert(
                        av_sample_fmt_is_planar(sampleFormat) == 0 && reqdBytes <= frame.pointee.linesize.0,
                        "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples: Sample format or size mismatch"
                    )
                    outPtr!.update(from: frame.pointee.data.0!, count: reqdBytes)
                    lastDelivered += Int(frame.pointee.nb_samples)
                }
                av_frame_unref(frame)
            }
        }
        nextHandle =
            endSampleCursor.handle.isLast
            ? nil
            : demuxer?.step(stream: streamIndex, from: endSampleCursor.handle, by: 1)

        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: buffer,
            blockLength: capacity,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: lastDelivered * sampleSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,  // not sure if this does anything useful
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),  // duration of one sample
            presentationTimeStamp: CMTime(value: startPkt.pointee.pts, timeBase: timeBase),
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track.formatDescription,
            sampleCount: lastDelivered,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        return completionHandler(sampleBuffer, nil)
    }

    // MARK: navigation

    // Step by number of frames (not by packets or timestamp)
    override func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {

        if stepCount == lastDelivered, let next = nextHandle, next.generation == handle.generation {
            // Being asked to step by the number of audio samples we last delivered in loadSampleBufferContainingSamples
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount) = lastDelivered")
            }
            let steppedBy = Int64(lastDelivered)
            handle = next
            nextHandle = nil
            lastDelivered = 0
            _ = demuxer?.get(stream: streamIndex, handle: handle, consumed: true)  // trim up to returned packet
            return completionHandler(steppedBy, nil)
        } else {
            return super.stepInDecodeOrder(by: stepCount, completionHandler: completionHandler)
        }
    }

}
