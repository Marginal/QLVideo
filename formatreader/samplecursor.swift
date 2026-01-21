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

// Selected FFmpeg constants that we need but that Swift bridging can't figure out
let AV_NOPTS_VALUE: Int64 = Int64.min

extension CMTime: @retroactive CustomStringConvertible {

    // Convert AVPacket timestamps into CMTime
    init(value: Int64, timeBase: AVRational) {
        self.init()
        if value == AV_NOPTS_VALUE || timeBase.den == 0 {
            self = CMTime.invalid
            self.timescale = timeBase.den
        } else {
            self = CMTime(value: value * Int64(timeBase.num), timescale: timeBase.den)
        }
    }

    // For logging
    public var description: String {
        if !self.isValid {
            return "invalid"
        } else if self.isNegativeInfinity {
            return "-inf"
        } else if self.isPositiveInfinity {
            return "+inf"
        } else if self.isIndefinite {
            return "indefinite"
        } else {
            return "\(self.value)/\(self.timescale)"
        }
    }
}

// See AVSampleCursor for the consumer's API by analogy

class SampleCursor: NSObject, MESampleCursor, NSCopying {

    var format: FormatReader? = nil
    var track: TrackReader? = nil
    var index: Int = -1  // FFmpeg stream index
    var timeBase = AVRational()

    // var current: UnsafeMutablePointer<AVPacket>? = nil  // packet at cursor
    var qi = -1  // naive implementation
    var error: Error?

    // used by stepInDecodeOrderByCount
    var lastDelivered: Int = 0
    var nexti = -1

    nonisolated(unsafe) static var instanceCount = 0
    var instance = 0

    init(format: FormatReader, track: TrackReader, index: Int, atPresentationTimeStamp presentationTimeStamp: CMTime) {
        super.init()
        self.format = format
        self.track = track
        self.index = index
        self.timeBase = track.stream.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1

        // Creating a SampleCursor means that CoreMedia will want packets. So start demuxing.
        if format.packetQueue == nil {
            format.packetQueue = PacketQueue(format.fmt_ctx!)
        }
        self.qi = format.packetQueue!.seek(stream: index, presentationTimeStamp: presentationTimeStamp)
        // (current, error) = format.packetQueue!.seek(stream: index, to: presentationTimeStamp)
        if TRACE_SAMPLE_CURSOR {
            if let current = format.packetQueue!.get(stream: self.index, qi: self.qi) {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(index) init at presentationTimeStamp:\(presentationTimeStamp, privacy: .public) -> dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public)"
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
        self.index = copying.index
        self.timeBase = copying.track!.stream.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1
        //if copying.current != nil { self.current = av_packet_clone(copying.current) }
        self.qi = copying.qi
        self.error = copying.error
        self.lastDelivered = copying.lastDelivered
        self.nexti = copying.nexti
        if TRACE_SAMPLE_CURSOR {
            if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
                logger.debug(
                    "SampleCursor \(copying.instance) stream \(copying.index) copy -> \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            } else {
                logger.debug(
                    "SampleCursor \(copying.instance) stream \(copying.index) copy -> \(self.instance) stream \(self.index) at no packet"
                )
            }
        }
    }

    deinit {
        if TRACE_SAMPLE_CURSOR {
            if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at decodeTimeStamp \(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) deinit"
                )
            } else {
                logger.debug("SampleCursor \(self.instance) stream \(self.index) at no packet deinit")
            }
        }
    }

    func copy(with zone: NSZone? = nil) -> Any {
        return SampleCursor(copying: self)
    }

    // MARK: current sample info

    var presentationTimeStamp: CMTime {
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            let time = CMTime(value: current.pointee.pts, timeBase: self.timeBase)  // docs suggest can be invalid for B frames
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) presentationTimeStamp = \(time, privacy: .public)"
                )
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.index) presentationTimeStamp = no packet")
            }
            return .invalid
        }
    }

    var decodeTimeStamp: CMTime {
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            let time = CMTime(value: current.pointee.dts, timeBase: self.timeBase)
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) decodeTimeStamp = \(time, privacy: .public)"
                )
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.index) decodeTimeStamp = no packet")
            }
            return .invalid
        }
    }

    var currentSampleDuration: CMTime {
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/currentsampleduration
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            let time = CMTime(value: current.pointee.duration, timeBase: self.timeBase)
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) currentSampleDuration = \(time, privacy: .public)"
                )
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.index) currentSampleDuration = unknown")
            }
            return .invalid
        }
    }

    var currentSampleFormatDescription: CMFormatDescription? {
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) currentSampleFormatDescription = \(self.track!.formatDescription!.mediaSubType, privacy: .public)"
                )
            }
            return track!.formatDescription
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("SampleCursor \(self.instance) stream \(self.index) currentSampleFormatDescription = no packet")
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
        guard let current = format!.packetQueue!.get(stream: index, qi: qi) else {
            logger.error(
                "SampleCursor \(self.instance) stream \(self.index) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public) no packet"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
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
            refCon: current.pointee.buf,
        )
        av_buffer_ref(current.pointee.buf)  // Ref the compressed data
        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: current.pointee.data,
            blockLength: Int(current.pointee.size),
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &blockSource,
            offsetToData: 0,
            dataLength: Int(current.pointee.size),
            flags: kCMBlockBufferAssureMemoryNowFlag,  // not sure if this does anything useful
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: current.pointee.duration, timeBase: timeBase),
            presentationTimeStamp: CMTime(value: current.pointee.pts, timeBase: timeBase),
            decodeTimeStamp: CMTime(value: current.pointee.dts, timeBase: timeBase)
        )
        let sampleFormat = AVSampleFormat(track!.stream.codecpar.pointee.format)
        var sampleSize = Int(av_get_bytes_per_sample(sampleFormat)) * Int(track!.stream.codecpar.pointee.ch_layout.nb_channels)
        let planar = Bool(av_sample_fmt_is_planar(sampleFormat) != 0)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track!.formatDescription,
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
                "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        return completionHandler(sampleBuffer, nil)
    }

    // MARK: navigation

    // Step by number of frames (not by timestamp)
    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        let oldqi = qi
        if stepCount == lastDelivered {
            // Being asked to step by the number of audio samples we last delivered in loadSampleBufferContainingSamples
            qi = nexti
            lastDelivered = 0
        } else {
            qi = format!.packetQueue!.step(stream: index, from: qi, by: Int(stepCount))
        }
        if TRACE_SAMPLE_CURSOR {
            let old = format!.packetQueue!.get(stream: self.index, qi: oldqi)!
            let current = format!.packetQueue!.get(stream: self.index, qi: qi)!
            logger.debug(
                "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: old.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: old.pointee.pts, timeBase: self.timeBase), privacy: .public) stepInDecodeOrder by \(stepCount) -> dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public)"
            )
        }
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepindecodeorder(bycount:)
        // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
        // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
        return completionHandler(Int64(qi - oldqi), nil)
    }

    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        let oldqi = qi
        qi = format!.packetQueue!.step(stream: index, from: qi, by: Int(stepCount))
        if TRACE_SAMPLE_CURSOR {
            let old = format!.packetQueue!.get(stream: self.index, qi: oldqi)!
            let current = format!.packetQueue!.get(stream: self.index, qi: self.qi)!
            logger.error(
                "SampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: old.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: old.pointee.pts, timeBase: self.timeBase), privacy: .public) stepInPresentationOrder by \(stepCount) -> dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public)"
            )
        }
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepinpresentationorder(bycount:)
        // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
        // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
        return completionHandler(Int64(qi - oldqi), nil)
    }

    // step by timestamp

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void)
    {
        if let current = format!.packetQueue!.get(stream: index, qi: qi) {
            var pinned: Bool
            if !deltaDecodeTime.isNumeric || deltaDecodeTime.timescale != timeBase.den {
                logger.error("SampleCursor \(self.instance) stream \(self.index) stepByDecodeTime by \(deltaDecodeTime) invalid")
                return completionHandler(.zero, false, MEError(.invalidParameter))
            }
            let decodeTimeStamp = CMTime(value: current.pointee.dts, timeBase: timeBase) + deltaDecodeTime
            (qi, pinned) = format!.packetQueue!.seek(stream: index, decodeTimeStamp: decodeTimeStamp)
            let current = format!.packetQueue!.get(stream: self.index, qi: self.qi)!
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) stepByDecodeTime by \(deltaDecodeTime, privacy: .public) -> dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) pinned:\(pinned)"
                )
            }
            return completionHandler(CMTime(value: current.pointee.dts, timeBase: self.timeBase), pinned, nil)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "SampleCursor \(self.instance) stream \(self.index) stepByDecodeTime by \(deltaDecodeTime, privacy: .public) no packet"
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
                "SampleCursor \(self.instance) stream \(self.index) stepByPresentationTime by \(deltaPresentationTime, privacy: .public)"
            )
        }
        return completionHandler(.invalid, false, MEError(.unsupportedFeature))
    }

    // MARK: GOP

    var syncInfo: AVSampleCursorSyncInfo {
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            let info = AVSampleCursorSyncInfo(
                sampleIsFullSync: ObjCBool((current.pointee.flags & AV_PKT_FLAG_KEY) != 0),
                sampleIsPartialSync: false,  // I don't know what this means
                sampleIsDroppable: ObjCBool((current.pointee.flags & (AV_PKT_FLAG_DISCARD | AV_PKT_FLAG_DISPOSABLE)) != 0)
            )
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at decodeTimeStamp \(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) syncInfo sampleIsFullSync:\(info.sampleIsFullSync, privacy: .public) sampleIsDroppable:\(info.sampleIsDroppable, privacy: .public)"
                )
            }
            return info
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error("SampleCursor \(self.instance) stream \(self.index) syncInfo no packet")
            }
            return AVSampleCursorSyncInfo(sampleIsFullSync: false, sampleIsPartialSync: false, sampleIsDroppable: true)
        }
    }

    var dependencyInfo: AVSampleCursorDependencyInfo {
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            let info = AVSampleCursorDependencyInfo(
                sampleIndicatesWhetherItHasDependentSamples: false,
                sampleHasDependentSamples: false,
                sampleIndicatesWhetherItDependsOnOthers: true,
                sampleDependsOnOthers: ObjCBool((current.pointee.flags & AV_PKT_FLAG_KEY) == 0),
                sampleIndicatesWhetherItHasRedundantCoding: true,
                sampleHasRedundantCoding: false
            )
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at decodeTimeStamp \(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) dependencyInfo sampleHasDependentSamples:\(info.sampleHasDependentSamples, privacy: .public) sampleDependsOnOthers:\(info.sampleDependsOnOthers, privacy: .public)"
                )
            }
            return info
        } else {
            let info = AVSampleCursorDependencyInfo()
            if TRACE_SAMPLE_CURSOR {
                logger.error("SampleCursor \(self.instance) stream \(self.index) dependencyInfo no packet")
            }
            return info
        }
    }

    // whether any sample earlier in decode order than the current sample can have a later presentation time than the current sample of the specified cursor
    func samplesWithEarlierDTSsMayHaveLaterPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi),
            let other = cursor.format!.packetQueue!.get(stream: cursor.index, qi: cursor.qi)
        {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at decodeTimeStamp \(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) samplesWithEarlierDTSsMayHaveLaterPTSs than SampleCursor \(cursor.instance) at presentationTimeStamp \(CMTime(value: other.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            }
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "SampleCursor \(cursor.instance) stream \(self.index) samplesWithEarlierDTSsMayHaveLaterPTSs no packet"
                )
            }
        }
        return false
    }

    // whether any sample later in decode order than the current sample can have an earllier presentation time than the current sample of the specified cursor
    func samplesWithLaterDTSsMayHaveEarlierPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi),
            let other = cursor.format!.packetQueue!.get(stream: cursor.index, qi: cursor.qi)
        {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "SampleCursor \(self.instance) stream \(self.index) at decodeTimeStamp \(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than SampleCursor \(cursor.instance) at presentationTimeStamp \(CMTime(value: other.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                )
            }
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "SampleCursor \(cursor.instance) stream \(self.index) samplesWithLaterDTSsMayHaveEarlierPTSs no packet"
                )
            }
        }
        return false
    }

}
