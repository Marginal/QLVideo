//
//  packetqueue.swift
//  QLVideo
//
//  Created by Jonathan Harris on 05/12/2025.
//

//
// Provide a queue of AVPackets to be consumed by MESampleCursor.
//
// Haven't yet figured out AVFoundation's typical access patterns, so this is just a naieve implementation that slurps in the whole file!
//

import AVFoundation
import Foundation

#if DEBUG
    let TRACE_PACKET_QUEUE: Bool = true
#else
    let TRACE_PACKET_QUEUE: Bool = false
#endif

private class PacketQueueItem<AVPacket>: Equatable {
    var pkt: UnsafeMutablePointer<AVPacket>
    var next: PacketQueueItem?

    init(pkt: UnsafeMutablePointer<AVPacket>) {
        self.pkt = pkt
    }

    static func == (a: PacketQueueItem<AVPacket>, b: PacketQueueItem<AVPacket>) -> Bool {
        return a.pkt == b.pkt
    }
}

class PacketQueue: @unchecked Sendable {
    //private var head: PacketQueueItem<AVPacket>?
    //private var tail: PacketQueueItem<AVPacket>?
    let fmt_ctx: UnsafeMutablePointer<AVFormatContext>
    var pkt_fixup: Int64 = 0
    let dispatch = DispatchQueue(label: "uk.org.marginal.qlvideo.formatreader.packetqueue")
    let mutex = DispatchSemaphore(value: 1)  // protects head & tail
    let run = DispatchSemaphore(value: 0)
    var error: Error? = nil
    var eof = false
    var stopping = false

    var queue: [[UnsafeMutablePointer<AVPacket>]]  // naive implementation

    init(_ fmt_ctx: UnsafeMutablePointer<AVFormatContext>) {
        self.fmt_ctx = fmt_ctx

        if String(cString: fmt_ctx.pointee.iformat.pointee.name).contains("matroska") {
            // matroska_parse_frame() appears to have a bug where it sets AVPacket->pos to the
            // enclosing EBML element ID preceding the packet data
            pkt_fixup = 4
        }
        queue = Array(repeating: [], count: Int(fmt_ctx.pointee.nb_streams))

        //dispatch.async { [self] in
        while true {
            if stopping {
                logger.debug("PacketQueue stopping")
                break
            }
            // Read one video frame, or
            // one variable-sized audio frame, or
            // multiple fixed-size audio frames (e.g. PCM) for all channels or for one channel if planar?
            // https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html#ga4fdb3084415a82e3810de6ee60e46a61
            var pkt = av_packet_alloc()
            let ret = av_read_frame(fmt_ctx, pkt)
            if ret != 0 {
                av_packet_free(&pkt)
                if ret == AVERROR_EOF {
                    eof = true
                    logger.debug("PacketQueue reached EOF")
                    break
                } else {
                    error = AVERROR(errorCode: ret, context: "av_read_frame", file: nil)
                    logger.error(
                        "PacketQueue error reading from file: \(ret) \(self.error!.localizedDescription, privacy: .public)"
                    )
                    break
                }
            } else {
                if !SAMPLE_CURSOR_USE_LOADSAMPLE {
                    pkt!.pointee.pos += pkt_fixup
                }
                if TRACE_PACKET_QUEUE {
                    let pkt = pkt!.pointee
                    let stream = fmt_ctx.pointee.streams[Int(pkt.stream_index)]!.pointee
                    logger.debug(
                        "PacketQueue queue: stream \(pkt.stream_index) dts:\(pkt.dts) pts:\(pkt.pts) duration:\(pkt.duration == AV_NOPTS_VALUE ? -1 : pkt.duration) time_base:\(stream.time_base.num)/\(stream.time_base.den) pos:0x\(pkt.pos >= 0 ? UInt64(pkt.pos) : 0, format:.hex) size:0x\(UInt(pkt.size), format:.hex) flags:\(pkt.flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(pkt.flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)\(pkt.flags & AV_PKT_FLAG_CORRUPT != 0 ? "C" : "_", privacy: .public)"
                    )
                }
                append(pkt!)
            }
            /*
                            // Pause until the queue is not full
                            while true {
                                mutex.wait()
                                if eof {  // || (head != nil && tail != nil && timestamp(tail!.pkt) - timestamp(head!.pkt) > 1 * AV_TIME_BASE) {
                                    mutex.signal()
                                    run.wait()  // wait for someone to seek or consume items before generating more
                                } else {
                                    mutex.signal()
                                    break
                                }
                            }
                        //}
            */
        }

        // Fix up invalid leading DTSs to be negative
        for q in queue {
            if q[0].pointee.dts == AV_NOPTS_VALUE && q[0].pointee.duration != AV_NOPTS_VALUE {
                for i in 0..<q.count {
                    var dts = q[i].pointee.dts
                    if dts != AV_NOPTS_VALUE {
                        for j in (0..<i).reversed() {
                            dts -= q[j].pointee.duration
                            q[j].pointee.dts = dts
                        }
                        break
                    }
                }
            }
        }
    }

    func stop() {
        stopping = true
        run.signal()
    }

    /*
    // timestamp in AV_TIME_BASE units (i.e. µs)
    func timestamp(_ pkt: UnsafeMutablePointer<AVPacket>) -> Int64 {
        let timestamp = pkt.pointee.pts != AV_NOPTS_VALUE ? pkt.pointee.pts : pkt.pointee.dts
        if timestamp == AV_NOPTS_VALUE {
            return AV_NOPTS_VALUE
        } else {
            return fmt_ctx.pointee.start_time
                + Int64(Double(timestamp) * av_q2d(fmt_ctx.pointee.streams[Int(pkt.pointee.stream_index)]!.pointee.time_base))
        }
    }
     */

    private func append(_ pkt: UnsafeMutablePointer<AVPacket>) {
        let idx = Int(pkt.pointee.stream_index)
        queue[idx].append(pkt)
    }

    func get(stream: Int, qi: Int) -> UnsafeMutablePointer<AVPacket>? {
        return qi >= queue[stream].count ? nil : queue[stream][qi]
    }

    func step(stream: Int, from: Int, by: Int) -> Int {
        return min(max(from + by, 0), queue[stream].count - 1)
    }

    func seek(stream: Int, presentationTimeStamp: CMTime) -> Int {
        if CMTimeCompare(presentationTimeStamp, .zero) == 0 {
            // common case
            return 0
        } else if CMTimeCompare(presentationTimeStamp, .positiveInfinity) == 0 {
            // called to find the DTS, PTS and duration of the last packet
            return queue[stream].count - 1
        } else {
            let timeBase = fmt_ctx.pointee.streams[stream]!.pointee.time_base
            let pts = Int64(presentationTimeStamp.seconds * av_q2d(av_inv_q(timeBase)))  // in stream timeBase units
            // The new sample cursor points to the last sample with a presentation time stamp (PTS) less than or equal to presentationTimeStamp
            for i in (0..<queue[stream].count).reversed() {
                if queue[stream][i].pointee.flags & AV_PKT_FLAG_KEY != 0 && queue[stream][i].pointee.pts <= pts {
                    return i  // Simplify decoding by only seeking to keyframes
                }
            }
        }
        return 0  // "if there are no such samples, the first sample in PTS order"
    }

    func seek(stream: Int, decodeTimeStamp: CMTime) -> (Int, Bool) {
        // Assumes common timebase denominator
        let timeBase = fmt_ctx.pointee.streams[stream]!.pointee.time_base
        let dts = Int32(decodeTimeStamp.value) * timeBase.num  // in stream timeBase units
        if dts < queue[stream][0].pointee.dts {
            return (0, true)
        } else if dts > queue[stream].last!.pointee.dts {
            return (queue[stream].count - 1, true)
        } else {
            for i in (0..<queue[stream].count).reversed() {
                if queue[stream][i].pointee.dts <= dts {
                    return (i, false)
                }
            }
            return (0, true)
        }
    }

    /*
    private func append(_ pkt: UnsafeMutablePointer<AVPacket>) -> PacketQueueItem<AVPacket> {
        let item = PacketQueueItem(pkt: pkt)
        mutex.wait()
        if head == nil {
            head = item
        } else {
            tail!.next = item
        }
        tail = item
        mutex.signal()
        return item
    }

    // return next packet, sleeping if necessary
    func pop(stream: Int) -> (UnsafeMutablePointer<AVPacket>?, Error?) {
        while true {
            mutex.wait()
            if let error {
                mutex.signal()
                return (nil, error)
            } else if let item = head {
                if head == tail { tail = nil }
                head = item.next
                mutex.signal()
                run.signal()  // request more packets
                return (item.pkt, nil)
            } else if eof {
                mutex.signal()
                return (nil, nil)
            }
            mutex.signal()
            run.signal()  // request more packets
            Thread.sleep(forTimeInterval: 0.1)  // wait for some packets to be demuxed
        }
    }
     */
}
