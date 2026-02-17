//
//  packetdemuxer.swift
//  QLVideo
//
//  Provide per-stream buffers of AVPackets to be consumed by MESampleCursor.
//
//  FFmpeg expects packets to be demuxed and decoded in a linear order, and goes to some effort to enable that.
//  However AVFoundation skips around creating MESampleCursors before and after the packet being decoded. Further,
//  we don't know which streams AVFoundation wants to consume.
//  Observations:
//  * Some streams can be much sparser than others e.g. half as many video packets than audio in a 30fps AAC file.
//  * Audio packets are typically much smaller than video packets, so we can afford to keep more of them buffered.
//  * Video streams are consumed serially so SampleCursor moves by 2-3 packets at a time
//  * Audio streams are typically consumed two seconds at a time in loadSampleBufferContainingSamples (=86 AAC packets)
//    but can be as high as 17s and ~1500! packets for variable duration streams like Vorbis, so audio SampleCursor
//    jumps a lot while video SampleCursor lags.
//

import AVFoundation
import CoreMedia
import Foundation

#if DEBUG
    let TRACE_PACKET_DEMUXER = true
#else
    let TRACE_PACKET_DEMUXER = false
#endif

let QLThumbnailTime = CMTime(value: 10_000_000, timescale: 1_000_000)  // QuickLook generates its thumbnail at 10s
let kSettingsSnapshotTime = "SnapshotTime"  // Seek offset for thumbnails and single Previews [s].

private final class PacketRing {
    private var storage: [UnsafeMutablePointer<AVPacket>?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    private var headLogicalIndex = 0
    let capacity: Int
    let timeBase: AVRational

    init(capacity: Int, timeBase: AVRational) {
        self.capacity = capacity
        self.timeBase = timeBase
        self.storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }
    var minLogicalIndex: Int {
        assert(count > 0)
        return headLogicalIndex
    }
    var maxLogicalIndex: Int {
        assert(count > 0)
        return headLogicalIndex + count - 1
    }

    func reset() {
        var idx = head
        for _ in 0..<count {
            av_packet_free(&storage[idx])
            storage[idx] = nil
            idx = (idx + 1) % capacity
        }
        head = 0
        tail = 0
        count = 0
        headLogicalIndex = 0
    }

    func append(packet: UnsafeMutablePointer<AVPacket>) -> UnsafeMutablePointer<AVPacket>? {
        var evicted: UnsafeMutablePointer<AVPacket>? = nil
        if isFull {
            evicted = storage[head]
            storage[head] = nil
            head = (head + 1) % capacity
            headLogicalIndex += 1
            count -= 1
        }
        storage[tail] = packet
        tail = (tail + 1) % capacity
        count += 1
        return evicted
    }

    func get(logicalIndex: Int) -> UnsafeMutablePointer<AVPacket>? {
        guard !isEmpty, logicalIndex >= minLogicalIndex, logicalIndex <= maxLogicalIndex else { return nil }
        let offset = logicalIndex - headLogicalIndex
        let idx = (head + offset) % capacity
        return storage[idx]
    }

    func nearest(to target: CMTime) -> Int? {
        var below: Int? = nil
        var above: Int? = nil
        for idx in 0..<count {
            let pkt = storage[(head + idx) % capacity]!
            let tsVal = pkt.pointee.pts
            if tsVal == AV_NOPTS_VALUE { continue }
            let ts = CMTime(value: tsVal, timeBase: timeBase)
            if ts == target {
                return headLogicalIndex + idx
            } else if ts < target {
                below = idx
            } else if ts > target {
                above = idx
                break
            }
        }
        guard let below, let above = above else { return nil }
        let belowPkt = storage[(head + below) % capacity]!
        let abovePkt = storage[(head + above) % capacity]!
        let belowTs = CMTime(value: belowPkt.pointee.pts, timeBase: timeBase)
        let aboveTs = CMTime(value: abovePkt.pointee.pts, timeBase: timeBase)
        return target.seconds - belowTs.seconds <= aboveTs.seconds - target.seconds
            ? headLogicalIndex + below : headLogicalIndex + above
    }
}

struct PacketHandle {
    let generation: Int
    let index: Int
    let isLast: Bool
}

final class PacketDemuxer {
    private static let videoCapacity = 1024
    private static let audioCapacity = videoCapacity * 3  // Audio buffers thrice video
    private static let videoReadAhead = 120  // 2 seconds of video at 60fps
    private static let audioReadAhead = 196  // should be more than enough for at least 2 seconds of audio in typical codecs
    private let fmtCtx: UnsafeMutablePointer<AVFormatContext>
    private var pktFixup: Int64 = 0
    private var snapshotTime = CMTimeValue(10 * AV_TIME_BASE)  // Snapshot time in AV_TIME_BASE units
    private var buffers: [PacketRing]
    private var bsfCtxs: [UnsafeMutablePointer<AVBSFContext>?]
    private var generation: Int = 0
    private var targetLogical: [Int]
    private var readAhead: [Int]
    private var stopping = false
    private var halted = false  // true after EOF or read/seek error until next successful seek
    private var rememberedSeekPTS: CMTime? = nil
    private var lastPkt: [UnsafeMutablePointer<AVPacket>?]  // MediaExtension wants us to report the last packet for each stream

    private let stateLock = NSLock()
    private let demuxGroup = DispatchGroup()
    private let demuxQueue = DispatchQueue(label: "uk.org.marginal.qlvideo.formatreader", qos: .default)
    private let demuxSem = DispatchSemaphore(value: 0)  // wake demuxLoop when paused
    private let packetSem = DispatchSemaphore(value: 0)  // notify consumers a packet arrived

    init(format: FormatReader) throws {
        self.fmtCtx = format.fmt_ctx!
        if let defaults = format.defaults, defaults.integer(forKey: kSettingsSnapshotTime) > 0 {
            // Note that since this extension is running under app sandbox this will only succeed once notarized or in app store
            // https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox#Share-files-between-related-apps-with-app-group-containers
            let time = CMTimeValue(defaults.integer(forKey: kSettingsSnapshotTime))
            logger.log("PacketDemuxer using snapshot time of \(time)s")
            snapshotTime = CMTimeValue(time) * CMTimeValue(AV_TIME_BASE)
        }
        buffers = (0..<Int(format.fmt_ctx!.pointee.nb_streams)).map { idx in
            let stream = format.fmt_ctx!.pointee.streams[idx]!
            let capacity: Int
            if stream.pointee.discard != AVDISCARD_ALL {
                switch stream.pointee.codecpar.pointee.codec_type {
                case AVMEDIA_TYPE_VIDEO: capacity = PacketDemuxer.videoCapacity
                case AVMEDIA_TYPE_AUDIO: capacity = PacketDemuxer.audioCapacity
                default: capacity = 0  // we currently don't handle other kinds of stream
                }
            } else {
                capacity = 0
            }
            return PacketRing(capacity: capacity, timeBase: stream.pointee.time_base)
        }
        bsfCtxs = (0..<Int(format.fmt_ctx!.pointee.nb_streams)).map { idx in
            let stream = format.fmt_ctx!.pointee.streams[idx]!
            if stream.pointee.discard != AVDISCARD_ALL
                && (stream.pointee.codecpar.pointee.codec_tag == 0x4449_5658  // 'DIVX'
                    || stream.pointee.codecpar.pointee.codec_tag == 0x5856_4944  // 'XVID'
                    || stream.pointee.codecpar.pointee.codec_tag == 0x4458_3530),  // 'DX50'
                let bsf = av_bsf_get_by_name("mpeg4_unpack_bframes")  // Regularize DivX streams
            {
                var ctx: UnsafeMutablePointer<AVBSFContext>?
                if av_bsf_alloc(bsf, &ctx) == 0 {
                    avcodec_parameters_copy(ctx!.pointee.par_in, stream.pointee.codecpar)
                    ctx!.pointee.time_base_in = stream.pointee.time_base
                    let ret = av_bsf_init(ctx!)
                    if ret == 0 {
                        if TRACE_PACKET_DEMUXER {
                            logger.debug("PacketDemuxer init: enabled mpeg4_unpack_bframes for stream \(idx)")
                        }
                        return ctx
                    } else {
                        let error = AVERROR(errorCode: ret, context: "av_bsf_init")
                        logger.error(
                            "PacketDemuxer init: Unable to set up mpeg4_unpack_bframes for stream \(idx): \(error.localizedDescription, privacy:.public)"
                        )
                        av_bsf_free(&ctx)
                    }
                }
            }
            return nil
        }
        readAhead = (0..<Int(format.fmt_ctx!.pointee.nb_streams)).map { idx in
            let stream = format.fmt_ctx!.pointee.streams[idx]!
            if stream.pointee.discard != AVDISCARD_ALL {
                switch stream.pointee.codecpar.pointee.codec_type {
                case AVMEDIA_TYPE_VIDEO: return PacketDemuxer.videoReadAhead
                case AVMEDIA_TYPE_AUDIO: return PacketDemuxer.audioReadAhead
                default: return 0
                }
            } else {
                return 0
            }
        }
        targetLogical = readAhead  // Swift arrays are value types, so this creates a copy
        lastPkt = [UnsafeMutablePointer<AVPacket>?](repeating: nil, count: Int(fmtCtx.pointee.nb_streams))
        if String(cString: fmtCtx.pointee.iformat.pointee.name).contains("matroska") { pktFixup = 4 }
        if TRACE_PACKET_DEMUXER {
            logger.debug("PacketDemuxer init streams: \(self.fmtCtx.pointee.nb_streams) pktFixup: \(self.pktFixup)")
        }
        try findLastPackets()
        startDemuxLoop()
    }

    deinit {
        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer deinit") }
        stop()
        demuxGroup.wait()
        stateLock.lock()
        for i in 0..<buffers.count { buffers[i].reset() }
        for i in 0..<lastPkt.count { av_packet_free(&lastPkt[i]) }
        for i in 0..<bsfCtxs.count { av_bsf_free(&bsfCtxs[i]) }
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        demuxSem.signal()
    }

    func get(stream: Int, handle: PacketHandle) -> UnsafeMutablePointer<AVPacket>? {
        if handle.isLast {
            return lastPkt[stream]
        } else {
            guard handle.generation == generation else {
                // AVFoundation tries to step from an old video SampleCursor after a seek
                // Fortunately doesn't seem a problem for the SampleCursor to return an Error
                if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer get stream \(stream) idx \(handle.index) stale") }
                return nil
            }
            stateLock.lock()
            defer { stateLock.unlock() }
            if let pkt = buffers[stream].get(logicalIndex: handle.index) {
                return pkt
            } else if self.buffers[stream].isEmpty {
                logger.error("PacketDemuxer get stream \(stream) idx \(handle.index) buffer empty")
                return nil
            } else {
                logger.error(
                    "PacketDemuxer get stream \(stream) idx \(handle.index) evicted valid:\(self.buffers[stream].minLogicalIndex)-\(self.buffers[stream].maxLogicalIndex) target:\(self.targetLogical[stream])"
                )
                return nil
            }
        }
    }

    func step(stream: Int, from handle: PacketHandle, by: Int) -> PacketHandle {
        if handle.isLast { return handle }  // Special handling for end-of-stream
        if handle.generation != generation { return PacketHandle(generation: generation, index: -1, isLast: false) }
        let requested = handle.index + by
        while true {
            stateLock.lock()
            if halted {
                let maxIdx = buffers[stream].isEmpty ? handle.index : buffers[stream].maxLogicalIndex
                if TRACE_PACKET_DEMUXER {
                    logger.debug(
                        "PacketDemuxer stream=\(stream) step from:\(handle.index) by:\(by) -> \(min(requested, maxIdx)) (halted)"
                    )
                }
                stateLock.unlock()
                return PacketHandle(generation: generation, index: min(requested, maxIdx), isLast: requested >= maxIdx)
            } else if buffers[stream].get(logicalIndex: requested) != nil {
                if TRACE_PACKET_DEMUXER {
                    logger.debug("PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) -> \(requested)")
                }
                targetLogical[stream] = max(targetLogical[stream], requested + readAhead[stream])
                demuxSem.signal()  // ensure demuxLoop runs if it was paused
                stateLock.unlock()
                return PacketHandle(generation: generation, index: requested, isLast: false)
            } else if requested < buffers[stream].minLogicalIndex {
                logger.warning(
                    "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) overrun, min=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].minLogicalIndex)"
                )
                stateLock.unlock()
                return handle
            } else {
                if TRACE_PACKET_DEMUXER {
                    logger.debug(
                        "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) underrun, max=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].maxLogicalIndex)"
                    )
                }
                targetLogical[stream] = max(targetLogical[stream], requested + readAhead[stream])
                demuxSem.signal()  // ensure demuxLoop runs if it was paused
                stateLock.unlock()
                packetSem.wait()
            }
        }  // loop until available
    }

    func seek(stream: Int, presentationTimeStamp: CMTime) throws -> PacketHandle {
        if presentationTimeStamp.isPositiveInfinity
            // Fix for QuickTime player which asks for a later SampleCursor after asking for one at +inf
            || lastPkt[stream] == nil
            || presentationTimeStamp >= CMTime(value: lastPkt[stream]!.pointee.pts, timeBase: buffers[stream].timeBase)
        {
            return PacketHandle(generation: generation, index: Int.max, isLast: true)
        }
        if let remembered = rememberedSeekPTS, remembered == presentationTimeStamp {
            if TRACE_PACKET_DEMUXER {
                logger.debug("PacketDemuxer stream \(stream) seek \(presentationTimeStamp, privacy: .public) -> 0 [remembered]")
            }
            if buffers[stream].isEmpty {
                stateLock.lock()
                waitForPacketZeroLocked(stream: stream)
                stateLock.unlock()
                return PacketHandle(generation: generation, index: 0, isLast: false)
            } else if buffers[stream].minLogicalIndex == 0 {
                return PacketHandle(generation: generation, index: 0, isLast: false)
            } else {
                logger.warning(
                    "PacketDemuxer stream \(stream) seek \(presentationTimeStamp, privacy: .public) remembered but first packet is \(self.buffers[stream].minLogicalIndex)"
                )
            }
        }
        if let hit = buffers[stream].nearest(to: presentationTimeStamp) {
            if TRACE_PACKET_DEMUXER {
                logger.debug("PacketDemuxer stream \(stream) seek \(presentationTimeStamp, privacy: .public) -> \(hit)")
            }
            return PacketHandle(generation: generation, index: hit, isLast: false)
        }

        // Miss: perform a discontinuous seek
        stateLock.lock()
        flushLocked()
        rememberedSeekPTS = presentationTimeStamp
        var ret: Int32
        var target = presentationTimeStamp
        if presentationTimeStamp.value == QLThumbnailTime.value && presentationTimeStamp.timescale == QLThumbnailTime.timescale {
            // If seeking to exactly QuickLook's thumbnail time, seek instead to the user's choice.
            let duration =
                fmtCtx.pointee.duration != 0
                ? fmtCtx.pointee.duration : (lastPkt[stream] != nil ? lastPkt[stream]!.pointee.pts : 0)
            let ts = duration != 0 && duration > 2 * snapshotTime ? snapshotTime : duration / 2
            target = CMTime(value: ts, timescale: AV_TIME_BASE)
            ret = avformat_seek_file(fmtCtx, -1, ts, ts, Int64.max, 0)
        } else if presentationTimeStamp.timescale == buffers[stream].timeBase.den {
            // asked to seek in this stream's timebase
            ret = avformat_seek_file(fmtCtx, Int32(stream), Int64.min, presentationTimeStamp.value, Int64.max, 0)
        } else {
            // seek using AV_TIME_BASE units
            let src = AVRational(num: 1, den: Int32(presentationTimeStamp.timescale))
            let AV_TIME_BASE_Q = AVRational(num: 1, den: Int32(AV_TIME_BASE))
            let timestamp = av_rescale_q(presentationTimeStamp.value, src, AV_TIME_BASE_Q)
            target = CMTime(value: timestamp, timescale: AV_TIME_BASE)
            ret = avformat_seek_file(fmtCtx, -1, Int64.min, timestamp, Int64.max, 0)
        }
        if ret < 0 {
            let error = AVERROR(errorCode: ret, context: "avformat_seek_file")
            logger.error(
                "PacketDemuxer seek stream \(stream) time \(target, privacy: .public): \(error.localizedDescription, privacy:.public)"
            )
            stateLock.unlock()
            throw error
        }
        if TRACE_PACKET_DEMUXER {
            logger.debug("PacketDemuxer stream \(stream) seek \(target, privacy: .public) -> 0 [seek_file]")
        }
        avformat_flush(fmtCtx)
        stateLock.unlock()
        demuxSem.signal()  // kick demux loop to start filling
        stateLock.lock()
        waitForPacketZeroLocked(stream: stream)  // Wait for the first packet to arrive after seek
        stateLock.unlock()
        return PacketHandle(generation: generation, index: 0, isLast: false)
    }

    func seek(stream: Int, decodeTimeStamp: CMTime) throws -> PacketHandle {
        let target = decodeTimeStamp
        let timeBase = buffers[stream].timeBase

        stateLock.lock()
        // Ensure we have at least one packet to start from
        while buffers[stream].isEmpty && !stopping && !halted {
            targetLogical[stream] = max(targetLogical[stream], readAhead[stream])
            demuxSem.signal()
            stateLock.unlock()
            packetSem.wait()
            stateLock.lock()
        }
        if buffers[stream].isEmpty {
            stateLock.unlock()
            return PacketHandle(generation: generation, index: Int.max, isLast: true)
        }
        // Try to find a packet in the current buffer with dts >= target
        let currentGen = generation
        var candidate: Int? = nil
        for offset in 0..<buffers[stream].count {
            if let pkt = buffers[stream].get(logicalIndex: buffers[stream].minLogicalIndex + offset) {
                let dts = pkt.pointee.dts
                if dts == AV_NOPTS_VALUE { continue }
                let ts = CMTime(value: dts, timeBase: timeBase)
                if ts >= target {
                    candidate = buffers[stream].minLogicalIndex + offset
                    break
                }
            }
        }
        if let idx = candidate {
            stateLock.unlock()
            return PacketHandle(generation: currentGen, index: idx, isLast: false)
        }

        // Step forward until we find dts >= target or hit end
        var handle = PacketHandle(generation: currentGen, index: buffers[stream].maxLogicalIndex, isLast: false)
        stateLock.unlock()
        while true {
            handle = step(stream: stream, from: handle, by: 1)
            if handle.isLast || handle.index == -1 {
                return handle
            }
            let pkt = get(stream: stream, handle: handle)
            let ts = CMTime(value: pkt!.pointee.dts, timeBase: timeBase)
            if ts >= target { return handle }
        }
    }

    // MARK: internals

    private func startDemuxLoop() {
        demuxQueue.async { self.demuxLoop() }
    }

    private func demuxLoop() {
        demuxGroup.enter()
        defer { demuxGroup.leave() }
        while true {
            stateLock.lock()
            if stopping {
                stateLock.unlock()
                break
            } else if shouldPauseLocked() {
                stateLock.unlock()
                demuxSem.wait()
            } else {
                stateLock.unlock()
                var pkt = av_packet_alloc()
                let ret = av_read_frame(fmtCtx, pkt)
                if ret != 0 {
                    av_packet_free(&pkt)
                    stateLock.lock()
                    halted = true
                    if ret == AVERROR_EOF {
                        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer demuxLoop reached EOF") }
                    } else {
                        let error = AVERROR(errorCode: ret, context: "av_read_frame")
                        logger.error("PacketDemuxer demuxLoop: \(error.localizedDescription, privacy:.public)")
                    }
                    demuxSem.signal()
                    stateLock.unlock()
                    continue
                }
                guard let packet = pkt else { continue }
                if packet.pointee.size == 0 || Int(packet.pointee.stream_index) >= buffers.count
                    || buffers[Int(packet.pointee.stream_index)].capacity == 0
                {
                    // Skip empty packets as seen in e.g. Theora since AVFoundation doesn't like them
                    // (-12706 kCMBlockBufferEmptyBBufErr) and skip packets for streams we don't handle
                    av_packet_free(&pkt)
                } else if let filtered = applyBitstreamFilter(stream: Int(packet.pointee.stream_index), packet: packet) {
                    for pkt in filtered { enqueue(pkt) }
                } else {
                    packet.pointee.pos += pktFixup
                    enqueue(packet)
                }
            }
        }
    }

    private func shouldPauseLocked() -> Bool {
        if halted { return true }
        // Don't pause until all buffers have reached their targets
        for i in 0..<buffers.count {
            if targetLogical[i] != 0 && (buffers[i].isEmpty || buffers[i].maxLogicalIndex < targetLogical[i]) {
                if TRACE_PACKET_DEMUXER {
                    logger.debug(
                        "PacketDemuxer demuxLoop stream \(i) idx \(self.buffers[i].isEmpty ? 0 : self.buffers[i].maxLogicalIndex) < target \(self.targetLogical[i])"
                    )
                }
                return false
            }
        }
        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer demuxLoop pausing") }
        return true
    }

    private func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let stream = Int(packet.pointee.stream_index)
        let buffer = buffers[stream]
        assert(buffer.capacity > 0, "PacketDemuxer stream \(stream) unexpected packet in discarded stream")
        var evicted = buffers[stream].append(packet: packet)
        av_packet_free(&evicted)
        if TRACE_PACKET_DEMUXER {
            let pts = packet.pointee.pts
            let dts = packet.pointee.dts
            let dur = packet.pointee.duration
            let pos = packet.pointee.pos
            let size = packet.pointee.size
            let flags = packet.pointee.flags
            logger.debug(
                "PacketDemuxer queue stream \(stream) idx:\(buffer.maxLogicalIndex) dts:\(dts) pts:\(pts) duration:\(dur == AV_NOPTS_VALUE ? -1 : dur) time_base:\(buffer.timeBase.num)/\(buffer.timeBase.den) pos:0x\(pos >= 0 ? UInt64(pos) : 0, format:.hex) size:0x\(UInt(size), format:.hex) flags:\(flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)\(flags & AV_PKT_FLAG_CORRUPT != 0 ? "C" : "_", privacy: .public)"
            )
        }

        // AVFoundation doesn't like it if packets don't have a DTS.
        // This can be seen in Matroska files where the first few packets don't have DTSs but later packets do.
        if buffer.minLogicalIndex == 0, let first = buffer.get(logicalIndex: 0), first.pointee.dts == AV_NOPTS_VALUE {
            // Hack: We can fix up DTSs with negative values if we have valid durations/DTSs in later packets.
            if packet.pointee.dts != AV_NOPTS_VALUE {
                if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer stream \(stream) fixing up DTS values") }
                var dts = packet.pointee.dts
                for i in (0..<buffer.count - 1).reversed() {
                    if let pkt = buffer.get(logicalIndex: i) {
                        pkt.pointee.dts = dts - (packet.pointee.duration != AV_NOPTS_VALUE ? pkt.pointee.duration : 1)
                        dts = pkt.pointee.dts
                    }
                }
            } else {
                return  // Don't signal availability of a packet we hope is going to be fixed up later
            }
        }

        packetSem.signal()  // signal to consumers that a packet arrived
    }

    private func flushLocked() {
        for i in 0..<buffers.count { buffers[i].reset() }
        generation &+= 1
        halted = false
        for i in 0..<targetLogical.count { targetLogical[i] = readAhead[i] }
        for i in 0..<bsfCtxs.count { if let bsf = bsfCtxs[i] { av_bsf_flush(bsf) } }
    }

    private func waitForPacketZeroLocked(stream: Int) {
        while true {
            if stopping { return }
            if halted { return }
            if !buffers[stream].isEmpty { return }
            stateLock.unlock()
            packetSem.wait()
            stateLock.lock()
        }
    }

    // MediaExtension will call us for the last packet for each stream; find this now so it doesn't mess up our demuxing
    private func findLastPackets() throws {
        var ret = avformat_seek_file(fmtCtx, -1, 0, Int64.max, Int64.max, 0)
        if ret < 0 {
            // Can't seek to end. Not fatal for now.
            let error = AVERROR(errorCode: ret, context: "avformat_seek_file(max)")
            logger.error("PacketDemuxer init: Failed to get last packets \(error.localizedDescription, privacy: .public)")
        } else {
            repeat {
                var pkt = av_packet_alloc()
                let ret = av_read_frame(fmtCtx, pkt)
                if ret == AVERROR_EOF {
                    av_packet_free(&pkt)
                    break
                } else if ret != 0 {
                    av_packet_free(&pkt)
                    let error = AVERROR(errorCode: ret, context: "av_read_frame")
                    logger.error("PacketDemuxer init: Failed to get last packets \(error.localizedDescription, privacy: .public)")
                    break
                } else if pkt!.pointee.stream_index >= buffers.count {
                    logger.warning("PacketDemuxer init: Packet with invalid stream \(pkt!.pointee.stream_index)")
                    av_packet_free(&pkt)
                } else {
                    let idx = Int(pkt!.pointee.stream_index)
                    if lastPkt[idx] != nil { av_packet_free(&lastPkt[idx]) }
                    lastPkt[idx] = pkt
                }
            } while true
        }
        // Reset to start
        ret = avformat_seek_file(fmtCtx, -1, Int64.min, Int64.min, 0, 0)
        guard ret >= 0 else {
            throw AVERROR(errorCode: ret, context: "avformat_seek_file(min)")  // If we can't seek to start we can't demux
        }
    }

    private func applyBitstreamFilter(stream: Int, packet: UnsafeMutablePointer<AVPacket>) -> [UnsafeMutablePointer<AVPacket>]? {
        guard let bsf = bsfCtxs[stream] else { return nil }
        var ret = av_bsf_send_packet(bsf, packet)  // consumes packet if successful
        if ret < 0 {
            if TRACE_PACKET_DEMUXER {
                let err = AVERROR(errorCode: ret, context: "av_bsf_send_packet")
                logger.error("PacketDemuxer bsf send stream \(stream): \(err.localizedDescription, privacy:.public)")
            }
            return nil
        }
        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        while true {
            var outPkt = av_packet_alloc()
            ret = av_bsf_receive_packet(bsf, outPkt)
            if ret == 0 {
                outputs.append(outPkt!)
            } else {
                av_packet_free(&outPkt)
                if TRACE_PACKET_DEMUXER && ret != AVERROR_EOF && ret != AVERROR_EAGAIN {
                    let err = AVERROR(errorCode: ret, context: "av_bsf_receive_packet")
                    logger.error("PacketDemuxer bsf recv stream \(stream): \(err.localizedDescription, privacy:.public)")
                }
                break
            }
        }
        return outputs
    }

}
