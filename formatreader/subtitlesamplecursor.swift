//
//  subtitlesamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide subtitle cues.
//

import MediaExtension

class SubtitleSampleCursor: SampleCursor {

    override func copy(with zone: NSZone? = nil) -> Any {
        return SubtitleSampleCursor(copying: self)
    }

    override func loadSampleBufferContainingSamples(
        to endSampleCursor: (any MESampleCursor)?,
        completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void
    ) {
        let endPresentationTimeStamp = endSampleCursor?.presentationTimeStamp ?? CMTime.indefinite
        guard let pkt = demuxer.get(stream: streamIndex, handle: handle) else {
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

        // Subtitle packets are preloaded and don't need allocating or freeing
        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pkt.pointee.data,
            blockLength: Int(pkt.pointee.size),
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
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
            sampleCount: 1,
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
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)! as NSArray
        let attachment = attachments.firstObject as! NSMutableDictionary
        attachment[kCMSampleAttachmentKey_NotSync] = kCFBooleanFalse  // all subtitle samples are sync
        attachment[kCMSampleAttachmentKey_DoNotDisplay] =
            ((pkt.pointee.flags & AV_PKT_FLAG_DISCARD) != 0) ? kCFBooleanTrue : kCFBooleanFalse
        attachment[kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding] =
            self.discontinuity ? kCFBooleanTrue : kCFBooleanFalse

        return completionHandler(sampleBuffer, nil)
    }
}
