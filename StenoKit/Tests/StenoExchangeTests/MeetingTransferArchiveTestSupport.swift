import AppleArchive
@preconcurrency import AVFAudio
import CryptoKit
import Darwin
import Foundation
import StenoDomain
import System
@testable import StenoExchange

let transferTestMeetingID = MeetingID(
    rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000031")!
)

enum TransferTestField {
    case flag(String)
    case uint(String, UInt64)
    case string(String, String)
    case blob(String, UInt64)
}

struct TransferTestArchiveEntry {
    let fields: [TransferTestField]
    let blobs: [Data]

    static func regular(
        path: String,
        data: Data,
        declaredSize: UInt64? = nil,
        extraFields: [TransferTestField] = []
    ) -> Self {
        Self(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", path),
                .uint("SIZ", declaredSize ?? UInt64(data.count)),
                .blob("DAT", declaredSize ?? UInt64(data.count)),
            ] + extraFields,
            blobs: [data]
        )
    }

    static func entry(
        type: ArchiveHeader.EntryType,
        path: String,
        data: Data = Data()
    ) -> Self {
        Self(
            fields: [
                .uint("TYP", UInt64(type.rawValue)),
                .string("PAT", path),
                .uint("SIZ", UInt64(data.count)),
                .blob("DAT", UInt64(data.count)),
            ],
            blobs: [data]
        )
    }
}

struct TransferTestPackageFixture {
    let content: MeetingTransferPackageContent
    let manifest: MeetingTransferManifest
    let manifestData: Data
    let payloadEntries: [(path: String, data: Data, mediaType: String)]

    var archiveEntries: [TransferTestArchiveEntry] {
        archiveEntries(manifestData: manifestData)
    }

    func archiveEntries(manifestData: Data) -> [TransferTestArchiveEntry] {
        [.regular(path: "manifest.json", data: manifestData)]
            + payloadEntries.map { .regular(path: $0.path, data: $0.data) }
    }
}

func makeTransferTextContent(
    notes: String? = "Plan\n[00:12:34] Beschluss",
    transcript: MeetingTransferTranscriptSnapshot? = makeTransferTranscript()
) throws -> MeetingTransferPackageContent {
    try MeetingTransferPackageContent(
        meeting: makeTransferMeeting(status: .processing),
        notes: notes,
        transcript: transcript,
        audio: []
    )
}

func makeTransferMeeting(
    status: Meeting.Status = .ready
) -> MeetingTransferMeetingDocument {
    try! MeetingTransferMeetingDocument(
        sourceMeetingID: transferTestMeetingID,
        title: "Planung",
        createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
        sourceStatus: status
    )
}

func makeTransferTranscript() -> MeetingTransferTranscriptSnapshot {
    try! MeetingTransferTranscriptSnapshot(
        localeIdentifier: "de-DE",
        localeOrigin: .explicit,
        speakers: [
            try! .init(id: "speaker-1", label: "Sprecher 1", kind: .generic),
        ],
        turns: [
            .init(
                speakerID: "speaker-1",
                start: 0,
                end: 1,
                segments: [
                    .init(
                        text: "Beschluss",
                        start: 0,
                        end: 1,
                        words: [.init(text: "Beschluss", start: 0, end: 1)]
                    ),
                ]
            ),
        ]
    )
}

func makeTransferPackageFixture(
    content: MeetingTransferPackageContent,
    audioSources: [String: URL] = [:]
) async throws -> TransferTestPackageFixture {
    var payloadEntries: [(path: String, data: Data, mediaType: String)] = [
        ("meeting.json", try content.meeting.encodedData(), "application/json"),
    ]
    if let notes = content.notes {
        payloadEntries.append(("notes.md", Data(notes.utf8), "text/markdown"))
    }
    if let transcript = content.transcript {
        payloadEntries.append(("transcript.json", try transcript.encodedData(), "application/json"))
    }
    for (offset, document) in content.audio.enumerated() {
        let number = offset + 1
        guard let source = audioSources[document.logicalTrackID] else {
            throw TransferTestError.missingAudioSource(document.logicalTrackID)
        }
        payloadEntries.append((
            "audio/track-\(number).caf",
            try Data(contentsOf: source),
            "audio/x-caf"
        ))
        payloadEntries.append((
            "audio/track-\(number).json",
            try document.encodedData(),
            "application/json"
        ))
    }

    let manifestEntries = payloadEntries.map {
        MeetingTransferManifest.Entry(
            path: $0.path,
            byteCount: Int64($0.data.count),
            mediaType: $0.mediaType,
            sha256: transferTestSHA256($0.data)
        )
    }
    let manifest = try MeetingTransferManifest(
        sourceMeetingID: content.meeting.sourceMeetingID,
        sourceRevisionID: nil,
        exportedAt: Date(timeIntervalSinceReferenceDate: 2_000),
        sourceAppVersion: "test",
        capabilities: content.capabilities,
        localeIdentifier: content.sourceLocale?.localeIdentifier,
        localeOrigin: content.sourceLocale?.origin ?? .absent,
        entries: manifestEntries,
        contentDigest: try MeetingTransferDigest.contentDigest(for: manifestEntries)
    )
    return TransferTestPackageFixture(
        content: content,
        manifest: manifest,
        manifestData: try manifest.encodedData(),
        payloadEntries: payloadEntries
    )
}

func writeTransferRawArchive(
    _ entries: [TransferTestArchiveEntry],
    to url: URL,
    trailingBytes: Data = Data()
) throws {
    try writeTransferRawArchiveBytes(
        transferRawArchiveData(entries, trailingBytes: trailingBytes),
        to: url
    )
}

func transferRawArchiveData(
    _ entries: [TransferTestArchiveEntry],
    trailingBytes: Data = Data()
) -> Data {
    var archive = Data()
    for entry in entries {
        let header = ArchiveHeader()
        for field in entry.fields {
            switch field {
            case let .flag(key):
                header.append(.flag(key: ArchiveHeader.FieldKey(key)))
            case let .uint(key, value):
                header.append(.uint(key: ArchiveHeader.FieldKey(key), value: value))
            case let .string(key, value):
                header.append(.string(key: ArchiveHeader.FieldKey(key), value: value))
            case let .blob(key, size):
                header.append(.blob(key: ArchiveHeader.FieldKey(key), size: size))
            }
        }
        header.withAAEncodedData { archive.append(contentsOf: $0) }
        for blob in entry.blobs {
            archive.append(blob)
        }
    }
    archive.append(trailingBytes)
    return archive
}

func writeTransferRawArchiveBytes(_ archive: Data, to url: URL) throws {
    try archive.write(to: url)
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

func mutateTransferFileInPlace(at url: URL) throws {
    let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { _ = Darwin.close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_size > 0 else {
        throw POSIXError(.EIO)
    }
    let offset = status.st_size - 1
    var byte: UInt8 = 0
    guard pread(descriptor, &byte, 1, offset) == 1 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    byte ^= 0x01
    guard pwrite(descriptor, &byte, 1, offset) == 1, fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

func writeTransferBytes(_ data: Data, to fileDescriptor: Int32) throws {
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let count = Darwin.write(
                fileDescriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }
}

func writeTransferCompressedArchive(rawURL: URL, to outputURL: URL) throws {
    let raw = try Data(contentsOf: rawURL)
    guard let output = ArchiveByteStream.fileStream(
        path: FilePath(outputURL.path),
        mode: .writeOnly,
        options: [.create, .exclusiveCreate],
        permissions: [.ownerReadWrite]
    ), let compressor = ArchiveByteStream.compressionStream(
        using: .lzfse,
        writingTo: output
    ) else {
        throw TransferTestError.couldNotCreateArchiveStream
    }
    do {
        try raw.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = try compressor.write(from: UnsafeRawBufferPointer(rebasing: bytes[offset...]))
                guard written > 0 else { throw TransferTestError.shortWrite }
                offset += written
            }
        }
        try compressor.close()
        try output.close()
    } catch {
        compressor.cancel()
        output.cancel()
        throw error
    }
}

func readTransferArchiveHeaders(at url: URL) throws -> [[(String, String)]] {
    guard let bytes = ArchiveByteStream.fileStream(
        path: FilePath(url.path),
        mode: .readOnly,
        options: [],
        permissions: []
    ), let archive = ArchiveStream.decodeStream(readingFrom: bytes) else {
        throw TransferTestError.couldNotCreateArchiveStream
    }
    defer {
        try? archive.close()
        try? bytes.close()
    }
    var result: [[(String, String)]] = []
    while let header = try archive.readHeader() {
        result.append(header.map { ($0.key.description, $0.type.description) })
        for field in header {
            guard case let .blob(key, size, _) = field else { continue }
            var remaining = size
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while remaining > 0 {
                let count = Int(min(UInt64(buffer.count), remaining))
                try buffer.withUnsafeMutableBytes {
                    try archive.readBlob(
                        key: key,
                        into: UnsafeMutableRawBufferPointer(rebasing: $0[..<count])
                    )
                }
                remaining -= UInt64(count)
            }
        }
    }
    return result
}

func makeTransferCAF(
    at url: URL,
    sampleRate: Double = 8_000,
    channelCount: AVAudioChannelCount = 1,
    frameCount: AVAudioFrameCount = 80
) throws {
    guard let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channelCount
    ) else {
        throw TransferTestError.invalidAudioFormat
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard frameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TransferTestError.invalidAudioFormat
        }
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(channelCount) {
                for frame in 0..<Int(frameCount) {
                    channels[channel][frame] = Float(frame % 8) / 16
                }
            }
        }
        try file.write(from: buffer)
    }
}

func makeTransferAudioDocument(
    logicalTrackID: String,
    kind: MediaAsset.Kind,
    sourceURL: URL,
    sampleRate: Double = 8_000,
    channelCount: Int = 1,
    duration: TimeInterval = 0.01
) async throws -> MeetingTransferAudioDocument {
    let data = try Data(contentsOf: sourceURL)
    return try MeetingTransferAudioDocument(
        logicalTrackID: logicalTrackID,
        kind: kind,
        byteCount: Int64(data.count),
        sha256: transferTestSHA256(data),
        sampleRate: sampleRate,
        channelCount: channelCount,
        duration: duration
    )
}

func transferTestSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func transferTestJSON(
    from data: Data,
    modifying body: (inout [String: Any]) throws -> Void
) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TransferTestError.invalidJSON
    }
    try body(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func makeTransferTestRoot(under base: URL, name: String) -> URL {
    base.appendingPathComponent(name, isDirectory: true)
}

func transferDirectoryContents(_ url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
}

enum TransferTestError: Error {
    case missingAudioSource(String)
    case couldNotCreateArchiveStream
    case shortWrite
    case invalidAudioFormat
    case invalidJSON
}
