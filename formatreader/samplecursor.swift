//
//  samplecursor.swift
//  QLVideo
//
//  Created by Jonathan Harris on 02/12/2025.
//

import MediaExtension

#if DEBUG
    let TRACE_SAMPLE_CURSOR: Bool = true
#else
    let TRACE_SAMPLE_CURSOR: Bool = false
#endif

// See AVSampleCursor for the consumer's API by analogy

class SampleCursor: NSObject, MESampleCursor, NSCopying {

    var format: FormatReader? = nil
    var track: TrackReader? = nil
    var streamIndex = -1  // FFmpeg stream index
    var handle = PacketHandle(generation: 0, index: -1, isLast: false)
    var timeBase = AVRational()
    var demuxer: PacketDemuxer { format!.demuxer! }

    // used by stepInDecodeOrderByCount
    var lastDelivered = 0
    var nextHandle: PacketHandle? = nil

    nonisolated(unsafe) static var instanceCount = 0
    var instance = 0

    init(format: FormatReader, track: TrackReader, index: Int, atPresentationTimeStamp presentationTimeStamp: CMTime) throws {
        super.init()
        self.format = format
        self.track = track
        self.streamIndex = index
        self.timeBase = track.stream.pointee.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1

        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "SampleCursor \(self.instance) stream \(index) init at presentationTimeStamp:\(presentationTimeStamp, privacy: .public)"
            )
        }
        // Creating a SampleCursor means that CoreMedia will want packets. So start demuxing.
        if format.demuxer == nil {
            format.demuxer = try PacketDemuxer(format: format)
        }
        self.handle = try demuxer.seek(stream: streamIndex, presentationTimeStamp: presentationTimeStamp)
    }

    init(copying: SampleCursor) {
        super.init()
        self.format = copying.format
        self.track = copying.track
        self.streamIndex = copying.streamIndex
        self.timeBase = copying.track!.stream.pointee.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1
        self.handle = copying.handle
        self.lastDelivered = copying.lastDelivered
        self.nextHandle = copying.nextHandle
        if TRACE_SAMPLE_CURSOR { logger.debug("\(copying.debugDescription, privacy: .public) copy -> \(self.instance)") }
    }

    deinit {
        if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) deinit") }
    }

    func copy(with zone: NSZone? = nil) -> Any {
        return SampleCursor(copying: self)
    }

    override var debugDescription: String {
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            return
                "SampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.handle.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase))"
        } else {
            return "SampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.handle.index) [no packet]"
        }
    }

    // MARK: pkt sample info

    var presentationTimeStamp: CMTime {
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            let time = CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)  // docs suggest can be invalid for B frames
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) presentationTimeStamp = \(time, privacy: .public)")
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) presentationTimeStamp") }
            return .invalid
        }
    }

    var decodeTimeStamp: CMTime {
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            let time = CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) decodeTimeStamp = \(time, privacy: .public)")
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) decodeTimeStamp") }
            return .invalid
        }
    }

    var currentSampleDuration: CMTime {
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/currentsampleduration
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            let time = CMTime(value: pkt.pointee.duration, timeBase: self.timeBase)
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) currentSampleDuration = \(time, privacy: .public)")
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) currentSampleDuration") }
            return .invalid
        }
    }

    var currentSampleFormatDescription: CMFormatDescription? {
        if demuxer.get(stream: self.streamIndex, handle: self.handle) != nil {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) currentSampleFormatDescription = \(self.track!.formatDescription!.mediaSubType, privacy: .public)"
                )
            }
            return track!.formatDescription
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) currentSampleFormatDescription") }
            return nil
        }
    }

    // MARK: Retrieving samples

    // https://developer.apple.com/documentation/mediaextension/mesamplecursor
    // Core Media's preferred way of accessing sample data is to be provided with an offset and length into
    // the file via sampleLocation() and chunkDetails(), and reading it directly. But FFmpeg doesn't expose this info.
    // FFmpeg works by reading data from the file until it has a valid packet for one of the streams.
    func loadSampleBufferContainingSamples(
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
        assert(
            pkt.pointee.side_data_elems == 0,
            "\(self.debugDescription) loadSampleBufferContainingSamples to \(endPresentationTimeStamp): Unhandled side data"
        )  // TODO: Handle side_data
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
            formatDescription: track!.formatDescription,  // TODO: attach any side_data as an extension
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
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)! as NSArray
        let attachment = attachments.firstObject as! NSMutableDictionary
        attachment[kCMSampleAttachmentKey_DependsOnOthers] =
            ((pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0) ? kCFBooleanFalse : kCFBooleanTrue
        attachment[kCMSampleAttachmentKey_DoNotDisplay] =
            ((pkt.pointee.flags & AV_PKT_FLAG_DISCARD) != 0) ? kCFBooleanTrue : kCFBooleanFalse

        return completionHandler(sampleBuffer, nil)
    }

    // MARK: navigation

    // Step by number of frames (not by packets or timestamp)
    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        var steppedBy: Int
        if demuxer.get(stream: self.streamIndex, handle: handle) != nil {
            if stepCount == lastDelivered, let next = nextHandle, next.generation == handle.generation {
                // Being asked to step by the number of audio samples we last delivered in loadSampleBufferContainingSamples
                if TRACE_SAMPLE_CURSOR {
                    logger.debug("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount) = lastDelivered")
                }
                handle = next
                steppedBy = lastDelivered
                nextHandle = nil
                lastDelivered = 0
            } else {
                if TRACE_SAMPLE_CURSOR {
                    logger.debug("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount)")
                }
                let oldIndex = handle.index
                handle = demuxer.step(stream: streamIndex, from: handle, by: Int(stepCount))
                steppedBy = handle.index - oldIndex
            }
            if demuxer.get(stream: self.streamIndex, handle: self.handle) != nil {
                return completionHandler(Int64(steppedBy), nil)
            } else {
                // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepindecodeorder(bycount:)
                // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
                // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
                return completionHandler(0, nil)
            }
        } else {
            logger.warning("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount)")
            return completionHandler(0, MEError(.endOfStream))
        }
    }

    // Step by number of frames (not by packets or timestamp)
    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("\(self.debugDescription, privacy: .public) stepInPresentationOrder by \(stepCount)")
        }
        let oldlogicalIndex = handle.index
        handle = demuxer.step(stream: streamIndex, from: handle, by: Int(stepCount))
        if handle.index == -1 { return completionHandler(0, MEError(.endOfStream)) }

        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepinpresentationorder(bycount:)
        // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
        // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
        return completionHandler(Int64(handle.index - oldlogicalIndex), nil)
    }

    // step by timestamp

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void)
    {
        if let pkt = demuxer.get(stream: streamIndex, handle: handle) {
            if !deltaDecodeTime.isNumeric || deltaDecodeTime.timescale != timeBase.den {
                logger.error(
                    "\(self.debugDescription, privacy: .public) stepByDecodeTime by \(deltaDecodeTime, privacy: .public) invalid"
                )
                return completionHandler(.invalid, false, MEError(.invalidParameter))
            }
            let decodeTimeStamp = CMTime(value: pkt.pointee.dts, timeBase: timeBase) + deltaDecodeTime
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) stepByDecodeTime by \(deltaDecodeTime, privacy: .public)"
                )
            }
            do {
                handle = try demuxer.seek(stream: streamIndex, decodeTimeStamp: decodeTimeStamp)
            } catch {
                return completionHandler(.invalid, false, error)
            }
            let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle)!
            return completionHandler(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), handle.isLast, nil)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "\(self.debugDescription, privacy: .public) stepByDecodeTime by \(deltaDecodeTime, privacy: .public)"
                )
            }
            return completionHandler(.invalid, false, MEError(.invalidParameter))
        }
    }

    func stepByPresentationTime(
        _ deltaPresentationTime: CMTime,
        completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.error(
                "\(self.debugDescription, privacy: .public) stepByPresentationTime by \(deltaPresentationTime, privacy: .public) not implemented"
            )
        }
        return completionHandler(.invalid, false, MEError(.unsupportedFeature))
    }

    // MARK: GOP

    var syncInfo: AVSampleCursorSyncInfo {
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            let info = AVSampleCursorSyncInfo(
                sampleIsFullSync: ObjCBool((pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0),
                sampleIsPartialSync: false,  // I don't know what this means
                sampleIsDroppable: ObjCBool((pkt.pointee.flags & (AV_PKT_FLAG_DISCARD | AV_PKT_FLAG_DISPOSABLE)) != 0)
            )
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) syncInfo sampleIsFullSync:\(info.sampleIsFullSync, privacy: .public) sampleIsDroppable:\(info.sampleIsDroppable, privacy: .public)"
                )
            }
            return info
        } else {
            if TRACE_SAMPLE_CURSOR { logger.error("\(self.debugDescription, privacy: .public) syncInfo") }
            return AVSampleCursorSyncInfo(sampleIsFullSync: false, sampleIsPartialSync: false, sampleIsDroppable: true)
        }
    }

    var dependencyInfo: AVSampleCursorDependencyInfo {
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            let info = AVSampleCursorDependencyInfo(
                sampleIndicatesWhetherItHasDependentSamples: false,
                sampleHasDependentSamples: false,
                sampleIndicatesWhetherItDependsOnOthers: true,
                sampleDependsOnOthers: ObjCBool((pkt.pointee.flags & AV_PKT_FLAG_KEY) == 0),
                sampleIndicatesWhetherItHasRedundantCoding: true,
                sampleHasRedundantCoding: false
            )
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) dependencyInfo sampleHasDependentSamples:\(info.sampleHasDependentSamples, privacy: .public) sampleDependsOnOthers:\(info.sampleDependsOnOthers, privacy: .public)"
                )
            }
            return info
        } else {
            let info = AVSampleCursorDependencyInfo()
            if TRACE_SAMPLE_CURSOR { logger.error("\(self.debugDescription, privacy: .public) dependencyInfo") }
            return info
        }
    }

    // whether any sample earlier in decode order than the current sample can have a later presentation time than the current sample of the specified cursor
    func samplesWithEarlierDTSsMayHaveLaterPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) samplesWithEarlierDTSsMayHaveLaterPTSs than SampleCursor \(cursor.debugDescription, privacy: .public)"
            )
        }
        return false
    }

    // whether any sample later in decode order than the current sample can have an earllier presentation time than the current sample of the specified cursor
    func samplesWithLaterDTSsMayHaveEarlierPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than SampleCursor \(cursor.debugDescription, privacy: .public)"
            )
        }
        return false
    }
}
