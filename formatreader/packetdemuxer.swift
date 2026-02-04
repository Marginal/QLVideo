//
//  packetdemuxer.swift
//  QLVideo
//
//  Provide per-stream buffers of AVPackets to be consumed by MESampleCursor.
//
//  FFmpeg expects packets to be demuxed and decoded in a linear order, and goes to some effort to enable that.
//  However AVFoundation skips around creating MESampleCursors before and after the packet being decoded. Further,
//  we don't know which streams AVFoundation wants to consume.
//  Strategy: Try to read-ahead up to 100 packets from the last MESampleCursor created, and keep some older packets around.
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

    func appendNoEvict(packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard !isFull else { return false }
        storage[tail] = packet
        tail = (tail + 1) % capacity
        count += 1
        return true
    }

    func appendEvictingOldest(packet: UnsafeMutablePointer<AVPacket>) -> UnsafeMutablePointer<AVPacket>? {
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
        guard !isEmpty, logicalIndex >= minLogicalIndex, logicalIndex <= maxLogicalIndex else {
            return nil
        }
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

final class PacketDemuxer {
    private enum Mode { case filling, target }

    private let fmtCtx: UnsafeMutablePointer<AVFormatContext>
    private let capacity: Int
    private var pktFixup: Int64 = 0

    private var buffers: [PacketRing]
    private var mode: Mode = .filling
    private var targetLogical: [Int]
    private var stopping = false
    private var halted = false  // true after EOF or read/seek error until next successful seek
    private var rememberedSeekPTS: CMTime? = nil
    private var rememberedSeekDTS: CMTime? = nil
    private var lastPkt: [UnsafeMutablePointer<AVPacket>?]  // MediaExtension wants us to report the last packet for each stream

    private let stateLock = NSLock()
    private let demuxQueue = DispatchQueue(label: "uk.org.marginal.qlvideo.formatreader", qos: .default)
    private let wakeSem = DispatchSemaphore(value: 0)

    init(fmtCtx: UnsafeMutablePointer<AVFormatContext>, capacity: Int = 128) throws {
        self.fmtCtx = fmtCtx
        self.capacity = capacity
        buffers = (0..<Int(fmtCtx.pointee.nb_streams)).map { idx in
            PacketRing(capacity: capacity, timeBase: fmtCtx.pointee.streams[idx]!.pointee.time_base)
        }
        targetLogical = Array(repeating: Int.max, count: Int(fmtCtx.pointee.nb_streams))
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
        wakeSem.signal()
    }

    func get(stream: Int, logicalIndex: Int) -> UnsafeMutablePointer<AVPacket>? {
        if logicalIndex == Int.max {
            return lastPkt[stream]
        } else {
            stateLock.lock()
            defer { stateLock.unlock() }
            return buffers[stream].get(logicalIndex: logicalIndex)
        }
    }

    func step(stream: Int, from: Int, by: Int) -> Int {
        if from == Int.max { return from }  // Special handling for end-of-stream
        let requested = from + by
        while true {
            stateLock.lock()
            if halted {
                let maxIdx = buffers[stream].isEmpty ? from : buffers[stream].maxLogicalIndex
                if TRACE_PACKET_DEMUXER {
                    logger.debug("PacketDemuxer stream \(stream) step from:\(from) by:\(by) halted -> \(min(requested, maxIdx))")
                }
                stateLock.unlock()
                return min(requested, maxIdx)
            }
            if let entry = buffers[stream].get(logicalIndex: requested) {
                if TRACE_PACKET_DEMUXER {
                    logger.debug("PacketDemuxer stream \(stream) step from:\(from) by:\(by) -> \(requested)")
                }
                targetLogical[stream] = requested + 100
                mode = .target
                wakeSem.signal()
                stateLock.unlock()
                return requested
            }
            logger.warning(
                "PacketDemuxer stream \(stream) step from:\(from) by:\(by) underrun, max=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].maxLogicalIndex)"
            )
            targetLogical[stream] = requested + 100
            mode = .target
            let demuxMayBePaused = buffers.contains { $0.isFull }
            if demuxMayBePaused { wakeSem.signal() }
            stateLock.unlock()
            wakeSem.wait()
        }  // loop until available
    }

    func seek(stream: Int, presentationTimeStamp: CMTime) throws -> Int {
        return try seekInternal(stream: stream, time: presentationTimeStamp, usePTS: true)
    }

    func seek(stream: Int, decodeTimeStamp: CMTime) throws -> Int {
        return try seekInternal(stream: stream, time: decodeTimeStamp, usePTS: false)
    }

    // MARK: internals

    private func seekInternal(stream: Int, time: CMTime, usePTS: Bool) throws -> Int {
        let remembered = usePTS ? rememberedSeekPTS : rememberedSeekDTS
        if time.isPositiveInfinity {
            return Int.max  // special handling for last packet in stream
        } else if let remembered, remembered == time {
            if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer stream \(stream) seek \(time) -> 0 [remembered]") }
            if buffers[stream].isEmpty {
                stateLock.lock()
                waitForPacketZeroLocked(stream: stream)
                stateLock.unlock()
                return 0
            } else if buffers[stream].minLogicalIndex == 0 {
                return 0
            } else {
                logger.warning(
                    "PacketDemuxer stream \(stream) seek \(time) remembered but first packet is \(self.buffers[stream].minLogicalIndex)"
                )
            }
        }
        if let hit = buffers[stream].nearest(to: time, usePTS: usePTS) {
            if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer stream \(stream) seek \(time) -> \(hit)") }
            return hit
        }

        stateLock.lock()
        flushLocked()
        targetLogical = Array(repeating: Int.max, count: targetLogical.count)
        if usePTS {
            rememberedSeekPTS = time
            rememberedSeekDTS = nil
        } else {
            rememberedSeekDTS = time
            rememberedSeekPTS = nil
        }
        var ret: Int32
        if time != .zero && time.timescale == buffers[stream].timeBase.den {
            // asked to seek in this stream's timebase
            ret = avformat_seek_file(fmtCtx, Int32(stream), Int64.min, time.value, Int64.max, 0)
        } else {
            // seek using AV_TIME_BASE units
            let src = AVRational(num: 1, den: Int32(time.timescale))
            let AV_TIME_BASE_Q = AVRational(num: 1, den: Int32(AV_TIME_BASE))
            let target = av_rescale_q(time.value, src, AV_TIME_BASE_Q)
            ret = avformat_seek_file(fmtCtx, -1, Int64.min, target, Int64.max, 0)
        }
        if ret < 0 {
            let error = AVERROR(errorCode: ret, context: "avformat_seek_file")
            logger.error("PacketDemuxer seek stream=\(stream) time=\(time): \(String(describing:error), privacy:.public)")
            stateLock.unlock()
            throw error
        }
        if TRACE_PACKET_DEMUXER {
            logger.debug("PacketDemuxer stream \(stream) seek \(time) -> 0 [seek_file]")
        }
        avformat_flush(fmtCtx)
        stateLock.unlock()
        wakeSem.signal()
        // Wait for the first packet to arrive after seek
        stateLock.lock()
        waitForPacketZeroLocked(stream: stream)
        stateLock.unlock()
        return 0
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
            }
            if shouldPauseLocked() {
                stateLock.unlock()
                wakeSem.wait()
                continue
            }
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
                    logger.error("PacketDemuxer demuxLoop: \(String(describing:error), privacy:.public)")
                }
                wakeSem.signal()
                stateLock.unlock()
                continue
            }
            guard let packet = pkt else { continue }
            packet.pointee.pos += pktFixup
            enqueue(packet)
        }
    }

    private func shouldPauseLocked() -> Bool {
        if halted { return true }
        switch mode {
        case .filling:
            return buffers.contains { $0.isFull }
        case .target:
            // Switch to filling mode if any buffer has reached its target
            for i in 0..<buffers.count {
                if !buffers[i].isEmpty && buffers[i].maxLogicalIndex >= targetLogical[i] {
                    mode = .filling
                    return buffers.contains { $0.isFull }
                }
            }
            return false
        }
    }

    private func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) {
        stateLock.lock()
        let stream = Int(packet.pointee.stream_index)
        var evicted: UnsafeMutablePointer<AVPacket>?
        switch mode {
        case .filling:
            let inserted = buffers[stream].appendNoEvict(packet: packet)
            evicted = nil
            if !inserted {
                stateLock.unlock()
                wakeSem.signal()
                return
            }
        case .target:
            evicted = buffers[stream].appendEvictingOldest(packet: packet)
        }
        if TRACE_PACKET_DEMUXER {
            let pts = packet.pointee.pts
            let dts = packet.pointee.dts
            let dur = packet.pointee.duration
            let pos = packet.pointee.pos
            let size = packet.pointee.size
            let flags = packet.pointee.flags
            logger.debug(
                "PacketDemuxer queue: stream \(stream) idx:\(self.buffers[stream].maxLogicalIndex) dts:\(dts) pts:\(pts) duration:\(dur == AV_NOPTS_VALUE ? -1 : dur) time_base:\(self.buffers[stream].timeBase.num)/\(self.buffers[stream].timeBase.den) pos:0x\(pos >= 0 ? UInt64(pos) : 0, format:.hex) size:0x\(UInt(size), format:.hex) flags:\(flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)\(flags & AV_PKT_FLAG_CORRUPT != 0 ? "C" : "_", privacy: .public)"
            )
        }
        av_packet_free(&evicted)
        wakeSem.signal()
        stateLock.unlock()
    }

    private func flushLocked() {
        for i in 0..<buffers.count { buffers[i].reset() }
        halted = false
        mode = .filling
        targetLogical = Array(repeating: Int.max, count: targetLogical.count)
    }

    private func waitForPacketZeroLocked(stream: Int) {
        while true {
            if stopping { return }
            if halted { return }
            if !buffers[stream].isEmpty { return }
            stateLock.unlock()
            wakeSem.wait()
            stateLock.lock()
        }
    }

    // MediaExtension will call us for the last packet for each stream; find this now so it doesn't mess up our demuxing
    private func findLastPackets() throws {
        var ret = avformat_seek_file(fmtCtx, -1, 0, Int64.max, Int64.max, 0)
        if ret < 0 {
            // Can't seek to end. Not fatal for now.
            let error = AVERROR(errorCode: ret, context: "avformat_seek_file(max)")
            logger.error("PacketDemuxer init: Failed to get last packets \(String(describing: error), privacy: .public)")
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
                    logger.error("PacketDemuxer init: Failed to get last packets \(String(describing: error), privacy: .public)")
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
