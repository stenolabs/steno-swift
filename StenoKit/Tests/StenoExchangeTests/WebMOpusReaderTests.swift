import Foundation
import Testing
@testable import StenoExchange

@Suite("WebM Opus reader")
struct WebMOpusReaderTests {
    @Test("reads one Opus track and packets across MediaRecorder clusters")
    func readsMediaRecorderWebM() throws {
        let firstPacket = Data([0xF8, 0xFF, 0xFE])
        let secondPacket = Data([0x98, 0x00])
        let webM = makeWebM(
            segmentHasUnknownSize: true,
            clusters: [
                makeCluster(
                    timecode: 0,
                    blocks: [makeSimpleBlock(packet: firstPacket)],
                    hasUnknownSize: true,
                    includesUnknownElement: true
                ),
                makeCluster(
                    timecode: 20,
                    blocks: [makeBlockGroup(packet: secondPacket)],
                    hasUnknownSize: false,
                    includesUnknownElement: false
                ),
            ],
            includesUnknownElements: true
        )

        let audio = try WebMOpusReader.read(webM)

        #expect(audio.magicCookie == opusHead)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.channelCount == 2)
        #expect(audio.packets == [firstPacket, secondPacket])
    }

    @Test("reads a WebM file URL")
    func readsFileURL() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "synthetic.webm")
        let packet = Data([0xF8, 0xFF, 0xFE])
        try makeWebM(
            clusters: [makeCluster(
                timecode: 0,
                blocks: [makeSimpleBlock(packet: packet)],
                hasUnknownSize: false,
                includesUnknownElement: false
            )]
        ).write(to: url)

        let audio = try WebMOpusReader.read(from: url)

        #expect(audio.packets == [packet])
    }

    @Test("rejects an empty file with a named error")
    func rejectsEmptyFile() {
        #expect(throws: WebMOpusReaderError.emptyInput) {
            try WebMOpusReader.read(Data())
        }
    }

    @Test("rejects a file whose first element is not an EBML header")
    func rejectsInvalidHeader() {
        let segmentOnly = element([0x18, 0x53, 0x80, 0x67], payload: Data())

        #expect(throws: WebMOpusReaderError.invalidEBMLHeader) {
            try WebMOpusReader.read(segmentOnly)
        }
    }

    @Test("rejects a child element whose declared size crosses its parent")
    func rejectsElementCrossingParentBoundary() throws {
        let cluster = makeCluster(
            timecode: 0,
            blocks: [makeSimpleBlock(packet: Data([0xF8]))],
            hasUnknownSize: false,
            includesUnknownElement: false
        )
        var webM = makeWebM(clusters: [cluster])
        let trackEntryID = try #require(webM.indices.filter { webM[$0] == 0xAE }.dropFirst().first)
        let sizeIndex = webM.index(after: trackEntryID)
        webM[sizeIndex] += UInt8(cluster.count)

        #expect(throws: WebMOpusReaderError.malformedElement("Element exceeds its parent")) {
            try WebMOpusReader.read(webM)
        }
    }

    @Test("rejects a file without an Opus audio track")
    func rejectsMissingOpusTrack() {
        let webM = makeWebM(codecID: "A_VORBIS")

        #expect(throws: WebMOpusReaderError.missingOpusTrack) {
            try WebMOpusReader.read(webM)
        }
    }

    @Test("rejects more than one Opus audio track")
    func rejectsMultipleOpusTracks() {
        let webM = makeWebM(trackCount: 2)

        #expect(throws: WebMOpusReaderError.multipleOpusTracks) {
            try WebMOpusReader.read(webM)
        }
    }

    @Test(
        "rejects lacing explicitly instead of treating laced frames as one packet",
        arguments: [
            (UInt8(0x82), WebMLacing.xiph),
            (UInt8(0x84), WebMLacing.fixedSize),
            (UInt8(0x86), WebMLacing.ebml),
        ]
    )
    func rejectsLacing(flags: UInt8, expected: WebMLacing) {
        let webM = makeWebM(clusters: [makeCluster(
            timecode: 0,
            blocks: [makeSimpleBlock(packet: Data([0x00]), flags: flags)],
            hasUnknownSize: false,
            includesUnknownElement: false
        )])

        #expect(throws: WebMOpusReaderError.unsupportedLacing(expected)) {
            try WebMOpusReader.read(webM)
        }
    }
}

private let opusHead = Data([
    0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,
    0x01, 0x02, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00,
    0x00, 0x00, 0x00,
])

private func makeWebM(
    codecID: String = "A_OPUS",
    trackCount: Int = 1,
    segmentHasUnknownSize: Bool = false,
    clusters: [Data] = [],
    includesUnknownElements: Bool = false
) -> Data {
    let ebmlHeader = element(
        [0x1A, 0x45, 0xDF, 0xA3],
        payload: element([0x42, 0x82], payload: Data("webm".utf8))
            + element([0x42, 0x87], payload: Data([0x04]))
            + (includesUnknownElements ? element([0xEC], payload: Data([0xAA])) : Data())
    )
    let audio = element(
        [0xE1],
        payload: element([0xB5], payload: float64(48_000))
            + element([0x9F], payload: Data([0x02]))
    )
    let trackEntries = (1...trackCount).reduce(into: Data()) { result, number in
        result += element(
            [0xAE],
            payload: element([0xD7], payload: Data([UInt8(number)]))
                + element([0x83], payload: Data([0x02]))
                + element([0x86], payload: Data(codecID.utf8))
                + element([0x63, 0xA2], payload: opusHead)
                + audio
        )
    }
    let tracks = element([0x16, 0x54, 0xAE, 0x6B], payload: trackEntries)
    let unknown = includesUnknownElements
        ? element([0x11, 0x4D, 0x9B, 0x74], payload: Data([0x01, 0x02]))
        : Data()
    let segmentPayload = unknown + tracks + clusters.reduce(Data(), +)
    let segment = segmentHasUnknownSize
        ? Data([0x18, 0x53, 0x80, 0x67]) + unknownSize(length: 8) + segmentPayload
        : element([0x18, 0x53, 0x80, 0x67], payload: segmentPayload)
    return ebmlHeader + segment
}

private func makeCluster(
    timecode: UInt8,
    blocks: [Data],
    hasUnknownSize: Bool,
    includesUnknownElement: Bool
) -> Data {
    let payload = element([0xE7], payload: Data([timecode]))
        + (includesUnknownElement ? element([0xA4], payload: Data([0x01])) : Data())
        + blocks.reduce(Data(), +)
    if hasUnknownSize {
        return Data([0x1F, 0x43, 0xB6, 0x75]) + unknownSize(length: 8) + payload
    }
    return element([0x1F, 0x43, 0xB6, 0x75], payload: payload)
}

private func makeSimpleBlock(packet: Data, flags: UInt8 = 0x80) -> Data {
    element([0xA3], payload: Data([0x81, 0x00, 0x00, flags]) + packet)
}

private func makeBlockGroup(packet: Data, flags: UInt8 = 0x00) -> Data {
    element(
        [0xA0],
        payload: element([0xA1], payload: Data([0x81, 0x00, 0x00, flags]) + packet)
    )
}

private func element(_ id: [UInt8], payload: Data) -> Data {
    Data(id) + variableInteger(UInt64(payload.count)) + payload
}

private func variableInteger(_ value: UInt64) -> Data {
    precondition(value < 127)
    return Data([0x80 | UInt8(value)])
}

private func unknownSize(length: Int) -> Data {
    precondition((1...8).contains(length))
    return Data([UInt8(1 << (8 - length))]) + Data(repeating: 0xFF, count: length - 1)
}

private func float64(_ value: Double) -> Data {
    var bits = value.bitPattern.bigEndian
    return withUnsafeBytes(of: &bits) { Data($0) }
}
