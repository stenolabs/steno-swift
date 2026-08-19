import Foundation

public struct WebMOpusAudio: Equatable, Sendable {
    public let magicCookie: Data
    public let sampleRate: Double
    public let channelCount: UInt32
    public let packets: [Data]

    public init(
        magicCookie: Data,
        sampleRate: Double,
        channelCount: UInt32,
        packets: [Data]
    ) {
        self.magicCookie = magicCookie
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.packets = packets
    }
}

public enum WebMLacing: String, Equatable, Sendable {
    case none
    case xiph
    case fixedSize
    case ebml
}

public enum WebMOpusReaderError: Error, Equatable, Sendable {
    case emptyInput
    case invalidEBMLHeader
    case unsupportedDocumentType(String)
    case missingSegment
    case malformedElement(String)
    case missingOpusTrack
    case multipleOpusTracks
    case invalidOpusHead
    case unsupportedLacing(WebMLacing)
}

public enum WebMOpusReader {
    public static func read(from url: URL) throws -> WebMOpusAudio {
        try read(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func read(_ data: Data) throws -> WebMOpusAudio {
        guard !data.isEmpty else { throw WebMOpusReaderError.emptyInput }
        var cursor = EBMLCursor(data: data)

        let header = try cursor.readElementHeader()
        guard header.id == ElementID.ebml.rawValue,
              let headerEnd = header.contentEnd else {
            throw WebMOpusReaderError.invalidEBMLHeader
        }
        try readEBMLHeader(cursor: &cursor, end: headerEnd)

        let segment = try cursor.readElementHeader()
        guard segment.id == ElementID.segment.rawValue else {
            throw WebMOpusReaderError.missingSegment
        }
        let segmentEnd = segment.contentEnd ?? data.count
        var tracks: [Track] = []
        var blocks: [Block] = []
        try readSegment(
            cursor: &cursor,
            end: segmentEnd,
            tracks: &tracks,
            blocks: &blocks
        )

        let opusTracks = tracks.filter { $0.type == 2 && $0.codecID == "A_OPUS" }
        guard !opusTracks.isEmpty else {
            throw WebMOpusReaderError.missingOpusTrack
        }
        guard opusTracks.count == 1 else {
            throw WebMOpusReaderError.multipleOpusTracks
        }
        let track = opusTracks[0]
        guard let trackNumber = track.number,
              let magicCookie = track.codecPrivate,
              let sampleRate = track.sampleRate,
              sampleRate.isFinite,
              sampleRate > 0,
              let channelCount = track.channelCount,
              channelCount > 0 else {
            throw WebMOpusReaderError.malformedElement("Incomplete A_OPUS track")
        }
        guard magicCookie.count >= 19,
              magicCookie.starts(with: Data("OpusHead".utf8)),
              magicCookie[8] == 1,
              magicCookie[9] == UInt8(exactly: channelCount) else {
            throw WebMOpusReaderError.invalidOpusHead
        }

        let selectedBlocks = blocks.filter { $0.trackNumber == trackNumber }
        if let laced = selectedBlocks.first(where: { $0.lacing != .none }) {
            throw WebMOpusReaderError.unsupportedLacing(laced.lacing)
        }
        return WebMOpusAudio(
            magicCookie: magicCookie,
            sampleRate: sampleRate,
            channelCount: channelCount,
            packets: selectedBlocks.map(\.payload)
        )
    }
}

private extension WebMOpusReader {
    static func readEBMLHeader(cursor: inout EBMLCursor, end: Int) throws {
        var documentType: String?
        while cursor.offset < end {
            let element = try cursor.readElementHeader(limit: end)
            guard let contentEnd = element.contentEnd else {
                throw WebMOpusReaderError.invalidEBMLHeader
            }
            if element.id == ElementID.documentType.rawValue {
                documentType = try cursor.readString(until: contentEnd)
            } else {
                cursor.offset = contentEnd
            }
        }
        guard cursor.offset == end, let documentType else {
            throw WebMOpusReaderError.invalidEBMLHeader
        }
        guard documentType == "webm" else {
            throw WebMOpusReaderError.unsupportedDocumentType(documentType)
        }
    }

    static func readSegment(
        cursor: inout EBMLCursor,
        end: Int,
        tracks: inout [Track],
        blocks: inout [Block]
    ) throws {
        while cursor.offset < end {
            let element = try cursor.readElementHeader(limit: end)
            switch element.id {
            case ElementID.tracks.rawValue:
                guard let contentEnd = element.contentEnd else {
                    throw WebMOpusReaderError.malformedElement("Tracks has unknown size")
                }
                try readTracks(cursor: &cursor, end: contentEnd, tracks: &tracks)
            case ElementID.cluster.rawValue:
                try readCluster(
                    cursor: &cursor,
                    end: element.contentEnd ?? end,
                    hasUnknownSize: element.contentEnd == nil,
                    blocks: &blocks
                )
            default:
                try cursor.skip(element, name: "segment child")
            }
        }
    }

    static func readTracks(
        cursor: inout EBMLCursor,
        end: Int,
        tracks: inout [Track]
    ) throws {
        while cursor.offset < end {
            let element = try cursor.readElementHeader(limit: end)
            if element.id == ElementID.trackEntry.rawValue {
                guard let contentEnd = element.contentEnd else {
                    throw WebMOpusReaderError.malformedElement("TrackEntry has unknown size")
                }
                tracks.append(try readTrack(cursor: &cursor, end: contentEnd))
            } else {
                try cursor.skip(element, name: "Tracks child")
            }
        }
    }

    static func readTrack(cursor: inout EBMLCursor, end: Int) throws -> Track {
        var track = Track()
        while cursor.offset < end {
            let element = try cursor.readElementHeader(limit: end)
            guard let contentEnd = element.contentEnd else {
                throw WebMOpusReaderError.malformedElement("Track child has unknown size")
            }
            switch element.id {
            case ElementID.trackNumber.rawValue:
                track.number = try cursor.readUnsignedInteger(until: contentEnd)
            case ElementID.trackType.rawValue:
                track.type = try cursor.readUnsignedInteger(until: contentEnd)
            case ElementID.codecID.rawValue:
                track.codecID = try cursor.readString(until: contentEnd)
            case ElementID.codecPrivate.rawValue:
                track.codecPrivate = try cursor.readData(until: contentEnd)
            case ElementID.audio.rawValue:
                try readAudio(cursor: &cursor, end: contentEnd, track: &track)
            default:
                cursor.offset = contentEnd
            }
        }
        return track
    }

    static func readAudio(
        cursor: inout EBMLCursor,
        end: Int,
        track: inout Track
    ) throws {
        while cursor.offset < end {
            let element = try cursor.readElementHeader(limit: end)
            guard let contentEnd = element.contentEnd else {
                throw WebMOpusReaderError.malformedElement("Audio child has unknown size")
            }
            switch element.id {
            case ElementID.samplingFrequency.rawValue:
                track.sampleRate = try cursor.readFloat(until: contentEnd)
            case ElementID.channels.rawValue:
                let channels = try cursor.readUnsignedInteger(until: contentEnd)
                guard let channelCount = UInt32(exactly: channels) else {
                    throw WebMOpusReaderError.malformedElement("Invalid channel count")
                }
                track.channelCount = channelCount
            default:
                cursor.offset = contentEnd
            }
        }
    }

    static func readCluster(
        cursor: inout EBMLCursor,
        end: Int,
        hasUnknownSize: Bool,
        blocks: inout [Block]
    ) throws {
        var hasTimecode = false
        while cursor.offset < end {
            let elementStart = cursor.offset
            let element = try cursor.readElementHeader(limit: end)
            if hasUnknownSize && isSegmentLevelElement(element.id) {
                cursor.offset = elementStart
                break
            }
            switch element.id {
            case ElementID.clusterTimecode.rawValue:
                guard let contentEnd = element.contentEnd else {
                    throw WebMOpusReaderError.malformedElement("Cluster Timecode has unknown size")
                }
                _ = try cursor.readUnsignedInteger(until: contentEnd)
                hasTimecode = true
            case ElementID.simpleBlock.rawValue:
                blocks.append(try readBlock(cursor: &cursor, element: element))
            case ElementID.blockGroup.rawValue:
                try readBlockGroup(cursor: &cursor, element: element, blocks: &blocks)
            default:
                try cursor.skip(element, name: "Cluster child")
            }
        }
        guard hasTimecode else {
            throw WebMOpusReaderError.malformedElement("Cluster has no Timecode")
        }
    }

    static func readBlockGroup(
        cursor: inout EBMLCursor,
        element: EBMLElementHeader,
        blocks: inout [Block]
    ) throws {
        guard let end = element.contentEnd else {
            throw WebMOpusReaderError.malformedElement("BlockGroup has unknown size")
        }
        while cursor.offset < end {
            let child = try cursor.readElementHeader(limit: end)
            if child.id == ElementID.block.rawValue {
                blocks.append(try readBlock(cursor: &cursor, element: child))
            } else {
                try cursor.skip(child, name: "BlockGroup child")
            }
        }
    }

    static func readBlock(
        cursor: inout EBMLCursor,
        element: EBMLElementHeader
    ) throws -> Block {
        guard let end = element.contentEnd else {
            throw WebMOpusReaderError.malformedElement("Block has unknown size")
        }
        let trackNumber = try cursor.readVariableIntegerValue(limit: end)
        guard end - cursor.offset >= 3 else {
            throw WebMOpusReaderError.malformedElement("Block header is truncated")
        }
        cursor.offset += 2
        let flags = try cursor.readByte(limit: end)
        let lacing: WebMLacing = switch (flags & 0x06) >> 1 {
        case 0: .none
        case 1: .xiph
        case 2: .fixedSize
        default: .ebml
        }
        return Block(
            trackNumber: trackNumber,
            lacing: lacing,
            payload: try cursor.readData(until: end)
        )
    }

    static func isSegmentLevelElement(_ id: UInt64) -> Bool {
        switch id {
        case 0x114D9B74, 0x1549A966, 0x1654AE6B, 0x1F43B675,
             0x1C53BB6B, 0x1941A469, 0x1043A770, 0x1254C367:
            true
        default:
            false
        }
    }
}

private struct Track {
    var number: UInt64?
    var type: UInt64?
    var codecID: String?
    var codecPrivate: Data?
    var sampleRate: Double?
    var channelCount: UInt32?
}

private struct Block {
    let trackNumber: UInt64
    let lacing: WebMLacing
    let payload: Data
}

private enum ElementID: UInt64 {
    case ebml = 0x1A45DFA3
    case documentType = 0x4282
    case segment = 0x18538067
    case tracks = 0x1654AE6B
    case trackEntry = 0xAE
    case trackNumber = 0xD7
    case trackType = 0x83
    case codecID = 0x86
    case codecPrivate = 0x63A2
    case audio = 0xE1
    case samplingFrequency = 0xB5
    case channels = 0x9F
    case cluster = 0x1F43B675
    case clusterTimecode = 0xE7
    case simpleBlock = 0xA3
    case blockGroup = 0xA0
    case block = 0xA1
}

private struct EBMLElementHeader {
    let id: UInt64
    let contentEnd: Int?
}

private struct EBMLCursor {
    let data: Data
    var offset = 0

    mutating func readElementHeader(limit: Int? = nil) throws -> EBMLElementHeader {
        let boundary = limit ?? data.count
        guard offset <= boundary, boundary <= data.count else {
            throw WebMOpusReaderError.malformedElement("Invalid parent boundary")
        }
        let id = try readID(limit: boundary)
        let size = try readSize(limit: boundary)
        let contentEnd: Int?
        if let size {
            guard size <= UInt64(boundary - offset),
                  let byteCount = Int(exactly: size) else {
                throw WebMOpusReaderError.malformedElement("Element exceeds its parent")
            }
            contentEnd = offset + byteCount
        } else {
            contentEnd = nil
        }
        return EBMLElementHeader(id: id, contentEnd: contentEnd)
    }

    mutating func skip(_ element: EBMLElementHeader, name: String) throws {
        guard let contentEnd = element.contentEnd else {
            throw WebMOpusReaderError.malformedElement("Unknown-size \(name)")
        }
        offset = contentEnd
    }

    mutating func readData(until end: Int) throws -> Data {
        guard offset <= end, end <= data.count else {
            throw WebMOpusReaderError.malformedElement("Invalid data range")
        }
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    mutating func readString(until end: Int) throws -> String {
        let bytes = try readData(until: end)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw WebMOpusReaderError.malformedElement("String is not UTF-8")
        }
        return value
    }

    mutating func readUnsignedInteger(until end: Int) throws -> UInt64 {
        let count = end - offset
        guard (1...8).contains(count) else {
            throw WebMOpusReaderError.malformedElement("Invalid unsigned integer size")
        }
        var value: UInt64 = 0
        while offset < end {
            value = (value << 8) | UInt64(try readByte(limit: end))
        }
        return value
    }

    mutating func readFloat(until end: Int) throws -> Double {
        let count = end - offset
        switch count {
        case 4:
            let bits = UInt32(try readUnsignedInteger(until: end))
            return Double(Float(bitPattern: bits))
        case 8:
            return Double(bitPattern: try readUnsignedInteger(until: end))
        default:
            throw WebMOpusReaderError.malformedElement("Invalid floating-point size")
        }
    }

    mutating func readVariableIntegerValue(limit: Int) throws -> UInt64 {
        let first = try readByte(limit: limit)
        guard first != 0 else {
            throw WebMOpusReaderError.malformedElement("Invalid variable integer")
        }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, offset + length - 1 <= limit else {
            throw WebMOpusReaderError.malformedElement("Truncated variable integer")
        }
        var value = UInt64(first & (0xFF >> length))
        for _ in 1..<length {
            value = (value << 8) | UInt64(try readByte(limit: limit))
        }
        return value
    }

    mutating func readByte(limit: Int) throws -> UInt8 {
        guard offset < limit, offset < data.count else {
            throw WebMOpusReaderError.malformedElement("Unexpected end of data")
        }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readID(limit: Int) throws -> UInt64 {
        let first = try readByte(limit: limit)
        guard first != 0 else {
            throw WebMOpusReaderError.malformedElement("Invalid element ID")
        }
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, offset + length - 1 <= limit else {
            throw WebMOpusReaderError.malformedElement("Truncated element ID")
        }
        var value = UInt64(first)
        for _ in 1..<length {
            value = (value << 8) | UInt64(try readByte(limit: limit))
        }
        return value
    }

    private mutating func readSize(limit: Int) throws -> UInt64? {
        let first = try readByte(limit: limit)
        guard first != 0 else {
            throw WebMOpusReaderError.malformedElement("Invalid element size")
        }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, offset + length - 1 <= limit else {
            throw WebMOpusReaderError.malformedElement("Truncated element size")
        }
        let mask = UInt8(0xFF >> length)
        var value = UInt64(first & mask)
        var isUnknown = (first & mask) == mask
        for _ in 1..<length {
            let byte = try readByte(limit: limit)
            value = (value << 8) | UInt64(byte)
            isUnknown = isUnknown && byte == 0xFF
        }
        return isUnknown ? nil : value
    }
}
