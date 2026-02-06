//
//  formatreader.swift
//  QLVideo
//

import Foundation
import MediaExtension

class FormatReader: NSObject, MEFormatReader {

    // From metadata tags - see avformat.h
    // https://wiki.multimedia.cx/index.php/FFmpeg_Metadata
    // https://nonstrict.eu/blog/2023/working-with-custom-metadata-in-mp4-files/
    // https://exiftool.org/TagNames/QuickTime.html
    // https://id3.org/id3v2.4.0-frames
    static let identifiers: [String: AVMetadataIdentifier] = [
        "album": .commonIdentifierAlbumName,
        "artist": .commonIdentifierArtist,
        "author": .commonIdentifierAuthor,
        "comment": .quickTimeMetadataComment,
        "composer": .quickTimeMetadataComposer,
        "copyright": .commonIdentifierCopyrights,
        "creation_time": .commonIdentifierCreationDate,
        "date": .commonIdentifierCreationDate,
        "description": .commonIdentifierDescription,
        "encoded_by": .quickTimeMetadataEncodedBy,
        "encoder": .quickTimeMetadataSoftware,
        "genre": .quickTimeMetadataGenre,
        "grouping": .iTunesMetadataGrouping,
        "keywords": .quickTimeMetadataKeywords,
        "language": .commonIdentifierLanguage,  // TODO: convert?
        "location": .commonIdentifierLocation,
        "performer": .quickTimeMetadataPerformer,
        "publisher": .commonIdentifierPublisher,
        "service_name": .commonIdentifierSource,  // e.g. TV channel
        "service_provider": .commonIdentifierSource,  // e.g. TV station
        //"show":                // e.g. TV show
        "synopsis": .quickTimeMetadataInformation,
        "title": .commonIdentifierTitle,
        "track": .quickTimeUserDataTrack,
    ]

    @objc let byteSource: MEByteSource
    @objc var avio_filepos: Int64 = 0
    var avio_ctx: UnsafeMutablePointer<AVIOContext>? = nil
    var fmt_ctx: UnsafeMutablePointer<AVFormatContext>? = nil
    var demuxer: PacketDemuxer? = nil

    init(primaryByteSource: MEByteSource) {
        byteSource = primaryByteSource
        super.init()
    }

    deinit {
        logger.debug("FormatReader deinit")
        if let demuxer { demuxer.stop() }
        if fmt_ctx != nil { avformat_close_input(&fmt_ctx) }
        if let avio_ctx {
            avio_ctx.pointee.opaque = nil  // otherwise avio_close() tries to free it
            avio_close(avio_ctx)  // also frees the underlying buffer
        }
    }

    class func av_fourcc2str(_ fourcc: UInt32) -> String {
        var buf = [CChar](repeating: 0, count: Int(AV_FOURCC_MAX_STRING_SIZE))
        return String(cString: av_fourcc_make_string(&buf, fourcc))
    }

    class func avcodec_name(_ codec_id: AVCodecID) -> String {
        guard let cd = avcodec_descriptor_get(codec_id) else { return "unknown" }
        return String(cString: cd.pointee.long_name ?? cd.pointee.name)
    }

    func loadFileInfo(completionHandler: @escaping @Sendable (MEFileInfo?, (any Error)?) -> Void) {
        // We can't read using MEByteSource.fileName, so set up an AVIOContext which uses MEByteSource.read
        // See "Opening a media file" https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html
        var buf: UnsafeMutableRawPointer? = nil
        posix_memalign(&buf, 16384, 16384)  // 1 ARM page. Will be freed by avio_close()
        avio_ctx = avio_alloc_context(
            buf,
            16384,
            0,  // not writable
            Unmanaged.passUnretained(self).toOpaque(),
            MEByteSource_read_packet,
            nil,
            MEByteSource_seek
        )
        fmt_ctx = avformat_alloc_context()
        fmt_ctx!.pointee.pb = avio_ctx
        var ret = avformat_open_input(&fmt_ctx, byteSource.fileName, nil, nil)
        guard ret == 0 else {
            let err = AVERROR(errorCode: ret, context: "avformat_open_input", file: byteSource.fileName)
            #if DEBUG
                logger.error(
                    "FormatReader can't open \(self.byteSource.fileName, privacy:.public): \(err.localizedDescription, privacy:.public)"
                )
            #else
                logger.error(
                    "FormatReader can't open \(self.byteSource.fileName, privacy:.private(mask:.hash)): \(err.localizedDescription, privacy:.public)"
                )
            #endif
            return completionHandler(nil, err)
        }

        // Read ahead if necessary to populate info like framerate that otherwise might not be available
        // Not sure if this is actually required for the formats/codecs we're interested in
        ret = avformat_find_stream_info(fmt_ctx, nil)
        guard ret == 0 else {
            let err = AVERROR(errorCode: ret, context: "avformat_find_stream_info", file: byteSource.fileName)
            #if DEBUG
                logger.error(
                    "FormatReader can't read stream info from \(self.byteSource.fileName, privacy:.public): \(err.localizedDescription, privacy:.public)"
                )
            #else
                logger.error(
                    "FormatReader can't read stream info from \(self.byteSource.fileName, privacy:.private(mask:.hash)): \(err.localizedDescription, privacy:.public)"
                )
            #endif
            return completionHandler(nil, err)
        }

        let fileInfo = MEFileInfo()
        fileInfo.duration = CMTime(value: fmt_ctx!.pointee.duration, timescale: AV_TIME_BASE)
        fileInfo.fragmentsStatus = .couldNotContainFragments
        completionHandler(fileInfo, nil)
    }

    func loadMetadata(completionHandler: @escaping @Sendable ([AVMetadataItem]?, (any Error)?) -> Void) {
        var metadata: [AVMetadataItem] = []
        var prev: UnsafeMutablePointer<AVDictionaryEntry>? = nil
        while let tag = av_dict_get(fmt_ctx!.pointee.metadata, "", prev, AV_DICT_IGNORE_SUFFIX) {
            prev = tag
            let identifier = FormatReader.identifiers[String(cString: tag.pointee.key).lowercased()]
            let value = NSString(utf8String: tag.pointee.value)
            guard identifier != nil, value != nil, value!.length != 0 else {
                logger.debug(
                    "Unrecognised metadata key:\(String(cString:tag.pointee.key), privacy:.public) = \"\(value ?? "", privacy:.public)\""
                )
                continue
            }
            let item = AVMutableMetadataItem()
            item.dataType = String(kCMMetadataBaseDataType_UTF8)
            item.identifier = identifier
            item.value = value
            metadata.append(item)
        }

        // Find the best cover art stream.
        var artStream = -1
        var artPriority = 0
        for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
            guard let stream = fmt_ctx!.pointee.streams[i]?.pointee else { continue }
            let params = stream.codecpar.pointee
            if (params.codec_id == AV_CODEC_ID_PNG || params.codec_id == AV_CODEC_ID_MJPEG)
                // Depending on codec and ffmpeg version cover art may be represented as attachment or as additional video stream(s)
                && (params.codec_type == AVMEDIA_TYPE_ATTACHMENT
                    || (params.codec_type == AVMEDIA_TYPE_VIDEO
                        && ((stream.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS))
                            == AV_DISPOSITION_ATTACHED_PIC)))
            {
                // MKVs can contain multiple cover art - see https://www.matroska.org/technical/attachments.html
                let nameDict = av_dict_get(stream.metadata, "filename", nil, 0)
                let filename = nameDict != nil ? String(cString: nameDict!.pointee.value) : ""
                var priority = 1
                if filename.lowercased().hasPrefix("cover.") {
                    priority = 4
                } else if filename.lowercased().hasPrefix("cover_land.") {
                    priority = 3
                } else if filename.lowercased().hasPrefix("cover_small.") {
                    priority = 2
                }
                if artPriority < priority  // Prefer first if multiple with same priority
                {
                    artPriority = priority
                    artStream = i
                }
            }
        }
        if artStream >= 0 {
            let stream = fmt_ctx!.pointee.streams[artStream]!.pointee
            let params = stream.codecpar.pointee
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.dataType =
                (params.codec_id == AV_CODEC_ID_PNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
            item.identifier = .commonIdentifierArtwork
            if stream.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                item.value = NSData(bytes: stream.attached_pic.data, length: Int(stream.attached_pic.size))
            } else {  // attachment stream
                item.value = NSData(bytes: params.extradata, length: Int(params.extradata_size))
            }
            metadata.append(item)
            logger.debug(
                "Found \(String(describing: item), privacy: .public) covert art in stream \(artStream)"
            )
        }

        return completionHandler(metadata, nil)
    }

    func loadTrackReaders(completionHandler: @escaping @Sendable ([any METrackReader]?, (any Error)?) -> Void) {
        var readers: [METrackReader] = []
        var decoder: UnsafePointer<AVCodec>?
        let besties: Set = [
            Int(av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)),
            Int(av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)),
            Int(av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_SUBTITLE, -1, -1, &decoder, 0)),
        ]
        for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
            guard var stream = fmt_ctx!.pointee.streams[i]?.pointee else { continue }
            let params = stream.codecpar.pointee
            // Only add supported stream types
            switch params.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if stream.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS) == 0 {
                    let reader = VideoTrackReader(format: self, stream: stream, index: i, enabled: besties.contains(i))
                    readers.append(reader)
                }

            case AVMEDIA_TYPE_AUDIO:
                let reader = AudioTrackReader(format: self, stream: stream, index: i, enabled: besties.contains(i))
                readers.append(reader)

            //case AVMEDIA_TYPE_SUBTITLE:
            //    readers.append(SubtitleTrackReader(format: self, stream: stream, index: i, enabled: besties.contains(i)))

            //case AVMEDIA_TYPE_ATTACHMENT:
            //    let codec_id = stream.pointee.codecpar.pointee.codec_id
            //    if [AV_CODEC_ID_PNG, AV_CODEC_ID_MJPEG].contains(codec_id) {
            //        readers.append(ArtTrackReader(format: self, stream: stream, index: i, enabled: false))
            //    } else {
            //        let cd = avcodec_descriptor_get(codec_id)
            //        logger.warning(
            //            "Unhandled attachment of type \"\(String(cString:cd.codec_long_name ?? cd.codec_name!))\""
            //        )
            //    }

            default:
                stream.discard = AVDISCARD_ALL  // no point demuxing or seeking streams that we can't handle
                logger.info(
                    "Unhandled \(String(cString:av_get_media_type_string(params.codec_type)), privacy:.public) stream: \(FormatReader.avcodec_name(params.codec_id), privacy:.public)"
                )
            }
        }
        completionHandler(readers, nil)
    }
}
