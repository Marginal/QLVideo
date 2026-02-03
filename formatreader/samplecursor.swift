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
    var logicalIndex = -1  // packet buffer logical index
    var timeBase = AVRational()

    // used by stepInDecodeOrderByCount
    var lastDelivered = 0
    var nextIndex = -1

    nonisolated(unsafe) static var instanceCount = 0
    var instance = 0

    init(format: FormatReader, track: TrackReader, index: Int, atPresentationTimeStamp presentationTimeStamp: CMTime) throws {
        super.init()
        self.format = format
        self.track = track
        self.streamIndex = index
        self.timeBase = track.stream.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1

        // Creating a SampleCursor means that CoreMedia will want packets. So start demuxing.
        if format.packetQueue == nil {
            format.packetQueue = PacketQueue(format.fmt_ctx!)
        }
        self.logicalIndex = try format.packetQueue!.seek(stream: streamIndex, presentationTimeStamp: presentationTimeStamp)

        if TRACE_SAMPLE_CURSOR {
            if let pkt = format.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(index) init at presentationTimeStamp:\(presentationTimeStamp, privacy: .public) -> dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            } else {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(index) init at presentationTimeStamp:\(presentationTimeStamp) -> no packet"
                )
            }
        }
    }

    init(copying: SampleCursor) {
        super.init()
        self.format = copying.format
        self.track = copying.track
        self.streamIndex = copying.streamIndex
        self.timeBase = copying.track!.stream.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1
        self.logicalIndex = copying.logicalIndex
        self.lastDelivered = copying.lastDelivered
        self.nextIndex = copying.nextIndex
        if TRACE_SAMPLE_CURSOR {
            if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
                logger.debug(
                    "SampleCursor \(copying.instance) stream \(copying.streamIndex) copy -> \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            } else {
                logger.debug(
                    "SampleCursor \(copying.instance) stream \(copying.streamIndex) copy -> \(self.instance) stream \(self.streamIndex) at no packet"
                )
            }
        }
    }

    deinit {
        if TRACE_SAMPLE_CURSOR {
            if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at decodeTimeStamp \(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) deinit"
                )
            } else {
                logger.debug("SampleCursor \(self.instance) stream \(self.streamIndex) at no packet deinit")
            }
        }
    }

    func copy(with zone: NSZone? = nil) -> Any {
        return SampleCursor(copying: self)
    }

    // MARK: pkt sample info

    var presentationTimeStamp: CMTime {
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
            let time = CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)  // docs suggest can be invalid for B frames
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) presentationTimeStamp = \(time, privacy: .public)"
                )
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.streamIndex) presentationTimeStamp = no packet")
            }
            return .invalid
        }
    }

    var decodeTimeStamp: CMTime {
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
            let time = CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) decodeTimeStamp = \(time, privacy: .public)"
                )
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.streamIndex) decodeTimeStamp = no packet")
            }
            return .invalid
        }
    }

    var currentSampleDuration: CMTime {
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/currentsampleduration
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
            let time = CMTime(value: pkt.pointee.duration, timeBase: self.timeBase)
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) pktSampleDuration = \(time, privacy: .public)"
                )
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.streamIndex) pktSampleDuration = unknown")
            }
            return .invalid
        }
    }

    var currentSampleFormatDescription: CMFormatDescription? {
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) pktSampleFormatDescription = \(self.track!.formatDescription!.mediaSubType, privacy: .public)"
                )
            }
            return track!.formatDescription
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) pktSampleFormatDescription = no packet"
                )
            }
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
        guard let pkt = format!.packetQueue!.get(stream: streamIndex, logicalIndex: logicalIndex) else {
            logger.error(
                "SampleCursor \(self.instance) stream \(self.streamIndex) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public) no packet"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }
        assert(
            pkt.pointee.side_data_elems == 0,
            "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)), pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples to \(endPresentationTimeStamp): Unhandled side data"
        )  // TODO: Handle side_data
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
            )
        }

        // Arrange for CoreMedia to free the packet data when no longer needed.
        // See CMBlockBufferCustomBlockSource in CMBlockBuffer.h for why we're constructing this on the fly
        var blockSource = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            FreeBlock: {
                var buffer: UnsafeMutablePointer<AVBufferRef>? = $0!.assumingMemoryBound(to: AVBufferRef.self)
                // if TRACE_SAMPLE_CURSOR { logger.debug("AudioSampleCursor free") }
                let _ = $1  // doomedMemoryBlock unused - av_buffer_unref() or av_packet_free() will free it
                let _ = $2  // sizeInBytes unused
                //av_buffer_unref(&buffer)
            },
            refCon: pkt.pointee.buf,
        )
        av_buffer_ref(pkt.pointee.buf)  // Ref the compressed data
        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pkt.pointee.data,
            blockLength: Int(pkt.pointee.size),
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
                "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
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
            sampleCount: track!.stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO ? 1 : 0,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
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
        if let old = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: logicalIndex) {
            if stepCount == lastDelivered {
                // Being asked to step by the number of audio samples we last delivered in loadSampleBufferContainingSamples
                logicalIndex = nextIndex
                steppedBy = lastDelivered
                nextIndex = -1
                lastDelivered = 0
            } else {
                let oldlogicalIndex = logicalIndex
                logicalIndex = format!.packetQueue!.step(stream: streamIndex, from: logicalIndex, by: Int(stepCount))
                steppedBy = logicalIndex - oldlogicalIndex
            }
            if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: logicalIndex) {
                if TRACE_SAMPLE_CURSOR {
                    logger.debug(
                        "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: old.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: old.pointee.pts, timeBase: self.timeBase), privacy: .public) stepInDecodeOrder by \(stepCount) -> dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                    )
                }
                return completionHandler(Int64(steppedBy), nil)
            } else {
                if TRACE_SAMPLE_CURSOR {
                    logger.debug(
                        "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: old.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: old.pointee.pts, timeBase: self.timeBase), privacy: .public) stepInDecodeOrder by \(stepCount) -> no packet"
                    )
                }
                // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepindecodeorder(bycount:)
                // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
                // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
                return completionHandler(0, nil)
            }
        } else {
            logger.debug("SampleCursor \(self.instance) stream \(self.streamIndex) stepInDecodeOrder at no packet")
            return completionHandler(0, MEError(.endOfStream))
        }
    }

    // Step by number of frames (not by packets or timestamp)
    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        let oldlogicalIndex = logicalIndex
        logicalIndex = format!.packetQueue!.step(stream: streamIndex, from: logicalIndex, by: Int(stepCount))
        if TRACE_SAMPLE_CURSOR {
            let old = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: oldlogicalIndex)!
            let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex)!
            logger.error(
                "SampleCursor \(self.instance) stream \(self.streamIndex) at dts:\(CMTime(value: old.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: old.pointee.pts, timeBase: self.timeBase), privacy: .public) stepInPresentationOrder by \(stepCount) -> dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public)"
            )
        }
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepinpresentationorder(bycount:)
        // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
        // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
        return completionHandler(Int64(logicalIndex - oldlogicalIndex), nil)
    }

    // step by timestamp

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void)
    {
        if let pkt = format!.packetQueue!.get(stream: streamIndex, logicalIndex: logicalIndex) {
            var pinned: Bool
            if !deltaDecodeTime.isNumeric || deltaDecodeTime.timescale != timeBase.den {
                logger.error(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) stepByDecodeTime by \(deltaDecodeTime) invalid"
                )
                return completionHandler(.zero, false, MEError(.invalidParameter))
            }
            let decodeTimeStamp = CMTime(value: pkt.pointee.dts, timeBase: timeBase) + deltaDecodeTime
            do {
                (logicalIndex, pinned) = try format!.packetQueue!.seek(stream: streamIndex, decodeTimeStamp: decodeTimeStamp)
            } catch {
                return completionHandler(.invalid, false, error)
            }
            let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex)!
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) stepByDecodeTime by \(deltaDecodeTime, privacy: .public) -> dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) pinned:\(pinned)"
                )
            }
            return completionHandler(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), pinned, nil)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) stepByDecodeTime by \(deltaDecodeTime, privacy: .public) no packet"
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
                "SampleCursor \(self.instance) stream \(self.streamIndex) stepByPresentationTime by \(deltaPresentationTime, privacy: .public)"
            )
        }
        return completionHandler(.invalid, false, MEError(.unsupportedFeature))
    }

    // MARK: GOP

    var syncInfo: AVSampleCursorSyncInfo {
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
            let info = AVSampleCursorSyncInfo(
                sampleIsFullSync: ObjCBool((pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0),
                sampleIsPartialSync: false,  // I don't know what this means
                sampleIsDroppable: ObjCBool((pkt.pointee.flags & (AV_PKT_FLAG_DISCARD | AV_PKT_FLAG_DISPOSABLE)) != 0)
            )
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at decodeTimeStamp \(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) syncInfo sampleIsFullSync:\(info.sampleIsFullSync, privacy: .public) sampleIsDroppable:\(info.sampleIsDroppable, privacy: .public)"
                )
            }
            return info
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error("SampleCursor \(self.instance) stream \(self.streamIndex) syncInfo no packet")
            }
            return AVSampleCursorSyncInfo(sampleIsFullSync: false, sampleIsPartialSync: false, sampleIsDroppable: true)
        }
    }

    var dependencyInfo: AVSampleCursorDependencyInfo {
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex) {
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
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at decodeTimeStamp \(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) dependencyInfo sampleHasDependentSamples:\(info.sampleHasDependentSamples, privacy: .public) sampleDependsOnOthers:\(info.sampleDependsOnOthers, privacy: .public)"
                )
            }
            return info
        } else {
            let info = AVSampleCursorDependencyInfo()
            if TRACE_SAMPLE_CURSOR {
                logger.error("SampleCursor \(self.instance) stream \(self.streamIndex) dependencyInfo no packet")
            }
            return info
        }
    }

    // whether any sample earlier in decode order than the current sample can have a later presentation time than the current sample of the specified cursor
    func samplesWithEarlierDTSsMayHaveLaterPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex),
            let other = cursor.format!.packetQueue!.get(stream: cursor.streamIndex, logicalIndex: cursor.logicalIndex)
        {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at decodeTimeStamp \(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) samplesWithEarlierDTSsMayHaveLaterPTSs than SampleCursor \(cursor.instance) at presentationTimeStamp \(CMTime(value: other.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            }
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "SampleCursor \(cursor.instance) stream \(self.streamIndex) samplesWithEarlierDTSsMayHaveLaterPTSs no packet"
                )
            }
        }
        return false
    }

    // whether any sample later in decode order than the current sample can have an earllier presentation time than the current sample of the specified cursor
    func samplesWithLaterDTSsMayHaveEarlierPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if let pkt = format!.packetQueue!.get(stream: self.streamIndex, logicalIndex: self.logicalIndex),
            let other = cursor.format!.packetQueue!.get(stream: cursor.streamIndex, logicalIndex: cursor.logicalIndex)
        {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.streamIndex) at decodeTimeStamp \(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than SampleCursor \(cursor.instance) at presentationTimeStamp \(CMTime(value: other.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            }
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "SampleCursor \(cursor.instance) stream \(self.streamIndex) samplesWithLaterDTSsMayHaveEarlierPTSs no packet"
                )
            }
        }
        return false
    }
}
