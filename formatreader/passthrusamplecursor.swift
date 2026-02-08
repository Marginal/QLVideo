//
//  passthrusamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to sampleLocation to provide the byte locations of packets in the media file.
//  Used to supply audio data for formats that CoreAudio understands.
//

import MediaExtension

class PassthruSampleCursor: SampleCursor {

    override func copy(with zone: NSZone? = nil) -> Any {
        return PassthruSampleCursor(copying: self)
    }

    func sampleLocation() throws -> MESampleLocation {
        if let pkt = demuxer.get(stream: self.streamIndex, handle: self.handle) {
            let location = AVSampleCursorStorageRange(offset: pkt.pointee.pos, length: Int64(pkt.pointee.size))
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) sampleLocation = 0x\(UInt64(location.offset), format:.hex), 0x\(UInt64(location.length), format:.hex)"
                )
            }
            return MESampleLocation(byteSource: format!.byteSource, sampleLocation: location)
        } else {
            if TRACE_SAMPLE_CURSOR { logger.error("\(self.debugDescription, privacy: .public) sampleLocation") }
            throw MEError(.endOfStream)
        }
    }
}
