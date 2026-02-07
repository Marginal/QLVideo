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
//  * Audio streams are consumed 86 packets at a time in loadSampleBufferContainingSamples (why 86?) so audio SampleCursor
//    moves by 86 packets and video SampleCursor lags.
//

import AVFoundation
import CoreMedia
import Foundation

#if DEBUG
    let TRACE_PACKET_DEMUXER = true
#else
    let TRACE_PACKET_DEMUXER = false
#endif

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

    func nearest(to target: CMTime, usePTS: Bool) -> Int? {
        var below: Int? = nil
        var above: Int? = nil
        for idx in 0..<count {
            let pkt = storage[(head + idx) % capacity]!
            let tsVal = usePTS ? pkt.pointee.pts : pkt.pointee.dts
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
        let belowTs = CMTime(value: usePTS ? belowPkt.pointee.pts : belowPkt.pointee.dts, timeBase: timeBase)
        let aboveTs = CMTime(value: usePTS ? abovePkt.pointee.pts : abovePkt.pointee.dts, timeBase: timeBase)
        return target.seconds - belowTs.seconds <= aboveTs.seconds - target.seconds
            ? headLogicalIndex + below : headLogicalIndex + above
    }
}

struct PacketHandle {
    let generation: Int
    let index: Int
}

final class PacketDemuxer {
    private enum Mode { case filling, target }
    private static let capacity = 1024  // Max number of packets to buffer per stream
    private static let readAhead = 192  // Enough to cover typical audio read bursts

    private let fmtCtx: UnsafeMutablePointer<AVFormatContext>
    private var pktFixup: Int64 = 0

    private var buffers: [PacketRing]
    private var generation: Int = 0
    private var mode: Mode = .filling
    private var targetLogical: [Int]
    private var stopping = false
    private var halted = false  // true after EOF or read/seek error until next successful seek
    private var rememberedSeekPTS: CMTime? = nil
    private var rememberedSeekDTS: CMTime? = nil
    private var lastPkt: [UnsafeMutablePointer<AVPacket>?]  // MediaExtension wants us to report the last packet for each stream

    private let stateLock = NSLock()
    private let demuxQueue = DispatchQueue(label: "uk.org.marginal.qlvideo.formatreader", qos: .default)
    private let demuxSem = DispatchSemaphore(value: 0)  // wake demuxLoop when paused
    private let packetSem = DispatchSemaphore(value: 0)  // notify consumers a packet arrived

    init(fmtCtx: UnsafeMutablePointer<AVFormatContext>) throws {
        self.fmtCtx = fmtCtx
        buffers = (0..<Int(fmtCtx.pointee.nb_streams)).map { idx in
            let stream = fmtCtx.pointee.streams[idx]!.pointee
            let capacity =
                stream.discard.rawValue & AVDISCARD_ALL.rawValue != 0
                ? 0 : (stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO ? PacketDemuxer.capacity : PacketDemuxer.capacity)
            return PacketRing(capacity: capacity, timeBase: fmtCtx.pointee.streams[idx]!.pointee.time_base)
        }
        targetLogical = Array(repeating: 0, count: Int(fmtCtx.pointee.nb_streams))
        lastPkt = [UnsafeMutablePointer<AVPacket>?](repeating: nil, count: Int(fmtCtx.pointee.nb_streams))
        if String(cString: fmtCtx.pointee.iformat.pointee.name).contains("matroska") { pktFixup = 4 }
        if TRACE_PACKET_DEMUXER {
            logger.debug("PacketDemuxer init streams: \(fmtCtx.pointee.nb_streams) pktFixup: \(self.pktFixup)")
        }
        try findLastPackets()
        startDemuxLoop()
    }

    deinit {
        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer deinit") }
        stop()
    }

    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        demuxSem.signal()
    }

    func get(stream: Int, handle: PacketHandle) -> UnsafeMutablePointer<AVPacket>? {
        if handle.index == Int.max {
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
        if handle.index == Int.max { return handle }  // Special handling for end-of-stream
        if handle.generation != generation { return PacketHandle(generation: generation, index: -1) }
        let requested = handle.index + by
        while true {
            stateLock.lock()
            if halted {
                let maxIdx = buffers[stream].isEmpty ? handle.index : buffers[stream].maxLogicalIndex
                if TRACE_PACKET_DEMUXER {
                    logger.debug("PacketDemuxer step stream=\(stream) halted returning \(min(requested, maxIdx))")
                }
                stateLock.unlock()
                return PacketHandle(generation: generation, index: min(requested, maxIdx))
            } else if buffers[stream].get(logicalIndex: requested) != nil {
                if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer step stream \(stream) -> \(requested)") }
                targetLogical[stream] = requested + PacketDemuxer.readAhead
                mode = .target
                demuxSem.signal()  // ensure demuxLoop runs if it was paused
                stateLock.unlock()
                return PacketHandle(generation: generation, index: requested)
            } else if requested < buffers[stream].minLogicalIndex {
                logger.warning(
                    "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) evicted, min=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].minLogicalIndex)"
                )
                stateLock.unlock()
                return handle
            } else {
                logger.warning(
                    "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) underrun, max=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].maxLogicalIndex)"
                )
                targetLogical[stream] = requested + PacketDemuxer.readAhead
                mode = .target
                demuxSem.signal()  // ensure demuxLoop runs if it was paused
                stateLock.unlock()
                packetSem.wait()
            }
        }  // loop until available
    }

    func seek(stream: Int, presentationTimeStamp: CMTime) throws -> PacketHandle {
        return try seekInternal(stream: stream, time: presentationTimeStamp, usePTS: true)
    }

    func seek(stream: Int, decodeTimeStamp: CMTime) throws -> PacketHandle {
        return try seekInternal(stream: stream, time: decodeTimeStamp, usePTS: false)
    }

    // MARK: internals

    private func seekInternal(stream: Int, time: CMTime, usePTS: Bool) throws -> PacketHandle {
        let remembered = usePTS ? rememberedSeekPTS : rememberedSeekDTS
        if time.isPositiveInfinity {
            return PacketHandle(generation: generation, index: Int.max)  // special handling for last packet in stream
        } else if let remembered, remembered == time {
            if TRACE_PACKET_DEMUXER {
                logger.debug("PacketDemuxer stream \(stream) seek \(time, privacy: .public) -> 0 [remembered]")
            }
            if buffers[stream].isEmpty {
                stateLock.lock()
                waitForPacketZeroLocked(stream: stream)
                stateLock.unlock()
                return PacketHandle(generation: generation, index: 0)
            } else if buffers[stream].minLogicalIndex == 0 {
                return PacketHandle(generation: generation, index: 0)
            } else {
                logger.warning(
                    "PacketDemuxer stream \(stream) seek \(time, privacy: .public) remembered but first packet is \(self.buffers[stream].minLogicalIndex)"
                )
            }
        }
        if let hit = buffers[stream].nearest(to: time, usePTS: usePTS) {
            if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer stream \(stream) seek \(time, privacy: .public) -> \(hit)") }
            return PacketHandle(generation: generation, index: hit)
        }

        // Miss
        stateLock.lock()
        flushLocked()
        if usePTS {
            rememberedSeekPTS = time
            rememberedSeekDTS = nil
        } else {
            rememberedSeekDTS = time
            rememberedSeekPTS = nil
        }
        var ret: Int32
        var target = time
        if time != .zero && time.timescale == buffers[stream].timeBase.den {
            // asked to seek in this stream's timebase
            ret = avformat_seek_file(fmtCtx, Int32(stream), Int64.min, time.value, Int64.max, 0)
        } else {
            // seek using AV_TIME_BASE units
            let src = AVRational(num: 1, den: Int32(time.timescale))
            let AV_TIME_BASE_Q = AVRational(num: 1, den: Int32(AV_TIME_BASE))
            let timestamp = av_rescale_q(time.value, src, AV_TIME_BASE_Q)
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
        return PacketHandle(generation: generation, index: 0)
    }

    private func startDemuxLoop() {
        demuxQueue.async { self.demuxLoop() }
    }

    private func demuxLoop() {
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
                packet.pointee.pos += pktFixup
                enqueue(packet)
            }
        }
    }

    private func shouldPauseLocked() -> Bool {
        if halted { return true }
        if mode == .target {
            // Don't pause until all buffers have reached their target
            for i in 0..<buffers.count {
                if targetLogical[i] != 0 && (buffers[i].isEmpty || buffers[i].maxLogicalIndex < targetLogical[i]) {
                    if TRACE_PACKET_DEMUXER {
                        logger.debug(
                            "PacketDemuxer demuxLoop stream \(i) target \(self.buffers[i].maxLogicalIndex) < \(self.targetLogical[i])"
                        )
                    }
                    return false
                }
            }
            mode = .filling
        }
        // Pause if we have some packets buffered.
        // Don't want to be more aggressive in case sparse streams cause needed packets to be evicted from other streams
        for i in 0..<buffers.count {
            if buffers[i].count >= PacketDemuxer.readAhead {
                if TRACE_PACKET_DEMUXER {
                    logger.debug("PacketDemuxer demuxLoop \(i) pausing \(self.buffers[i].count) >= \(PacketDemuxer.readAhead)")
                }
                return true
            }
        }
        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer demuxLoop filling") }
        return false
    }

    private func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let stream = Int(packet.pointee.stream_index)
        let buffer = buffers[stream]
        assert(buffer.capacity > 0, "PacketDemuxer stream \(stream) unexpected packet in discarded stream")
        var evicted = buffers[stream].append(packet: packet)
        assert(mode == .target || evicted == nil, "PacketDemuxer stream \(stream) unexpectedly evicted packet in filling mode")
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
        mode = .filling
        targetLogical = Array(repeating: 0, count: targetLogical.count)
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
}
