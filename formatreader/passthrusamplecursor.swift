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
        if let current = format!.packetQueue!.get(stream: self.index, qi: self.qi) {
            let location = AVSampleCursorStorageRange(offset: current.pointee.pos, length: Int64(current.pointee.size))
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "PassthruSampleCursor \(self.instance) stream \(self.index) at dts:\(CMTime(value: current.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: current.pointee.pts, timeBase: self.timeBase), privacy: .public) sampleLocation = 0x\(UInt64(location.offset), format:.hex), 0x\(UInt64(location.length), format:.hex)"
                )
            }
            return MESampleLocation(byteSource: format!.byteSource, sampleLocation: location)
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error("PassthruSampleCursor \(self.instance) stream \(self.index) sampleLocation at no packet")
            }
            throw MEError(.endOfStream)
        }
    }
}
