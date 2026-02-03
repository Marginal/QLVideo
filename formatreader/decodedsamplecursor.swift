//
//  decodedsamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide packets of audio data converted to PCM.
//  Used to supply audio data for formats that CoreAudio doesn't understand.
//

import MediaExtension

class DecodedSampleCursor: SampleCursor {

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
        let endPresentationTimeStamp = endSampleCursor?.presentationTimeStamp ?? CMTime.indefinite
        guard let current = format!.packetQueue!.get(stream: index, qi: qi) else {
            logger.error(
                "DecodedSampleCursor \(self.instance) stream \(self.index) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public) no packet"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }

        let sampleFormat = AVSampleFormat(track!.stream.codecpar.pointee.format)
        var sampleSize = Int(av_get_bytes_per_sample(sampleFormat)) * Int(track!.stream.codecpar.pointee.ch_layout.nb_channels)
        var duration = CMTime(value: current.pointee.duration, timeBase: self.timeBase)
        var estimatedPackets = 0
        var capacity = 0

        var nextPkt: UnsafeMutablePointer<AVPacket>? = current
        var buffer: UnsafeMutablePointer<UInt8>? = nil
        nexti = qi
        lastDelivered = 0
        let frame = av_frame_alloc()!

        // decode packets and add the decoded data to the blockBuffer
        repeat {
            // we only exect to be asked to provide data in the range of packets that we've previously reported as
            // existing, so treat any errors in retreiving and decoding as unexpected and unrecoverable
            var ret = avcodec_send_packet(track!.dec_ctx, nextPkt)
            if ret < 0 {
                let error = AVERROR(errorCode: ret, context: "avcodec_send_packet")
                logger.error(
                    "DecodedSampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: nextPkt!.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return completionHandler(nil, error)
            }

            ret = avcodec_receive_frame(track!.dec_ctx, frame)
            if ret == -EAGAIN {
                nexti += 1
                nextPkt = format!.packetQueue!.get(stream: index, qi: nexti)!
                continue
            } else if ret < 0 {
                let error = AVERROR(errorCode: ret, context: "avcodec_receive_frame")
                logger.error(
                    "DecodedSampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: nextPkt!.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return completionHandler(nil, error)
            }

            let offset = lastDelivered * sampleSize
            let reqdBytes = Int(frame.pointee.nb_samples) * sampleSize  // for this frame's data
            if buffer == nil {
                if duration.value == 0 { duration = CMTime(value: frame.pointee.duration, timeBase: self.timeBase) }
                estimatedPackets =
                    endPresentationTimeStamp.isNumeric && duration.isNumeric && duration.value != 0
                    ? Int(1 + (endPresentationTimeStamp.value - self.presentationTimeStamp.value) / duration.value)  // assumes common timeBase
                    : 1
                capacity = reqdBytes * estimatedPackets
                buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            } else if capacity < offset + reqdBytes {
                logger.warning(
                    "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: nextPkt!.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): Resizing output buffer from \(capacity) to \(capacity + sampleSize * Int(frame.pointee.nb_samples))"
                )
                let newCapacity = capacity + reqdBytes
                let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
                if let buffer = buffer {
                    newBuffer.update(from: buffer, count: capacity)
                    buffer.deallocate()
                }
                buffer = newBuffer
                capacity = newCapacity
            }

            var outPtr: UnsafeMutablePointer<UInt8>? = buffer?.advanced(by: offset)
            if track!.swr_ctx != nil {
                // CoreMedia doesn't like planar PCM (error "SSP::Render: CopySlice returned 1") so convert to packed/interleaved
                // http://www.openradar.me/45068930
                let inPtrs: UnsafePointer<UnsafePointer<UInt8>?>? = frame.pointee.extended_data?.withMemoryRebound(
                    to: UnsafePointer<UInt8>?.self,
                    capacity: Int(track!.stream.codecpar.pointee.ch_layout.nb_channels)
                ) { return UnsafePointer($0) }
                ret = swr_convert(
                    track!.swr_ctx,
                    &outPtr,
                    Int32((capacity - offset) / sampleSize),
                    inPtrs,
                    Int32(frame.pointee.nb_samples)
                )
                if ret < 0 {
                    let error = AVERROR(errorCode: ret, context: "swr_convert")
                    logger.error(
                        "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: nextPkt!.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return completionHandler(nil, error)
                }
                assert(
                    ret == frame.pointee.nb_samples,
                    "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: nextPkt!.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples to \(endPresentationTimeStamp): Expected \(frame.pointee.nb_samples), received \(ret) samples"
                )
                lastDelivered += Int(ret)
            } else {
                assert(
                    av_sample_fmt_is_planar(sampleFormat) == 0 && reqdBytes == frame.pointee.linesize.0,
                    "DecodedSampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: nextPkt!.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples to \(endPresentationTimeStamp): Sample format or size mismatch"
                )
                outPtr!.update(from: frame.pointee.data.0!, count: reqdBytes)
                lastDelivered += Int(frame.pointee.nb_samples)
            }

            av_frame_unref(frame)
            nexti += 1
            nextPkt = format!.packetQueue!.get(stream: index, qi: nexti)!
        } while nextPkt != nil && endPresentationTimeStamp.isNumeric
            && CMTime(value: nextPkt!.pointee.pts, timeBase: self.timeBase) <= endPresentationTimeStamp

        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "DecodedSampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public) estimatedPackets:\(estimatedPackets) actualPackets:\(self.nexti-self.qi) sampleCount:\(self.lastDelivered)"
            )
        }

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
                "DecodedSampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: current.pointee.duration, timeBase: timeBase),
            presentationTimeStamp: CMTime(value: current.pointee.pts, timeBase: timeBase),
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track!.formatDescription,
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
                "DecodedSampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        return completionHandler(sampleBuffer, nil)
    }

}
