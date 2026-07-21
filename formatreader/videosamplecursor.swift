//
//  videosamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide one packet of video data at a time.
//

import MediaExtension

class VideoSampleCursor: SampleCursor {

    override func copy(with zone: NSZone? = nil) -> Any {
        return VideoSampleCursor(copying: self)
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
        guard let pkt = demuxer?.get(stream: streamIndex, handle: handle, consumed: true) else {
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }

        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
            )
        }

        // Arrange for CoreMedia to free the packet data when no longer needed.
        // See CMBlockBufferCustomBlockSource in CMBlockBuffer.h for why we're constructing this on the fly
        let dataPkt = av_packet_clone(pkt)
        var blockSource = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            FreeBlock: {
                var pkt: UnsafeMutablePointer<AVPacket>? = $0!.assumingMemoryBound(to: AVPacket.self)
                // if TRACE_SAMPLE_CURSOR { logger.debug("AudioSampleCursor free") }
                let _ = $1  // doomedMemoryBlock unused - av_buffer_unref() or av_packet_free() will free it
                let _ = $2  // sizeInBytes unused
                av_packet_free(&pkt)
            },
            refCon: dataPkt,
        )
        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataPkt!.pointee.data,
            blockLength: Int(dataPkt!.pointee.size),
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &blockSource,
            offsetToData: 0,
            dataLength: Int(pkt.pointee.size),
            flags: kCMBlockBufferAssureMemoryNowFlag,  // not sure if this does anything useful
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: pkt.pointee.duration, timeBase: timeBase),
            presentationTimeStamp: CMTime(value: pkt.pointee.pts, timeBase: timeBase),
            decodeTimeStamp: CMTime(value: pkt.pointee.dts, timeBase: timeBase)
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track!.formatDescription,
            sampleCount: track!.stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO ? 1 : 0,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }
        CMSetAttachment(
            sampleBuffer!,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            value: self.discontinuity ? kCFBooleanTrue : kCFBooleanFalse,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)! as NSArray
        let attachment = attachments.firstObject as! NSMutableDictionary
        attachment[kCMSampleAttachmentKey_NotSync] =
            ((pkt.pointee.flags & AV_PKT_FLAG_KEY) == 0) ? kCFBooleanTrue : kCFBooleanFalse
        attachment[kCMSampleAttachmentKey_DoNotDisplay] =
            ((pkt.pointee.flags & AV_PKT_FLAG_DISCARD) != 0) ? kCFBooleanTrue : kCFBooleanFalse
        for i in 0..<Int(pkt.pointee.side_data_elems) {
            attachment["SideData\(i)" as CFString] = CFDataCreate(
                kCFAllocatorDefault,
                pkt.pointee.side_data[i].data,
                CFIndex(pkt.pointee.side_data[i].size)
            )
            attachment["SideData\(i)Type" as CFString] = CFNumberCreate(nil, .intType, &pkt.pointee.side_data[i].type)
        }

        return completionHandler(sampleBuffer, nil)
    }

}
