import Foundation

enum Fixture {
    static func url(_ name: String, extension fileExtension: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            throw FixtureError.missing("\(name).\(fileExtension)")
        }
        return url
    }

    static func text(_ name: String, extension fileExtension: String) throws -> String {
        try String(contentsOf: url(name, extension: fileExtension), encoding: .utf8)
    }

    enum FixtureError: Error {
        case missing(String)
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoExchangeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeFixture(
    _ resource: String,
    extension fileExtension: String,
    to destination: URL
) throws {
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: try Fixture.url(resource, extension: fileExtension),
        to: destination
    )
}

func makeSyntheticImportWebM() -> Data {
    let opusHead = Data([
        0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,
        0x01, 0x02, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00,
        0x00, 0x00, 0x00,
    ])
    let ebmlHeader = importEBMLElement(
        [0x1A, 0x45, 0xDF, 0xA3],
        payload: importEBMLElement([0x42, 0x82], payload: Data("webm".utf8))
    )
    let audio = importEBMLElement(
        [0xE1],
        payload: importEBMLElement([0xB5], payload: importFloat64(48_000))
            + importEBMLElement([0x9F], payload: Data([0x02]))
    )
    let track = importEBMLElement(
        [0xAE],
        payload: importEBMLElement([0xD7], payload: Data([0x01]))
            + importEBMLElement([0x83], payload: Data([0x02]))
            + importEBMLElement([0x86], payload: Data("A_OPUS".utf8))
            + importEBMLElement([0x63, 0xA2], payload: opusHead)
            + audio
    )
    let tracks = importEBMLElement([0x16, 0x54, 0xAE, 0x6B], payload: track)
    let block = importEBMLElement(
        [0xA3],
        payload: Data([0x81, 0x00, 0x00, 0x80, 0xF8, 0xFF, 0xFE])
    )
    let cluster = importEBMLElement(
        [0x1F, 0x43, 0xB6, 0x75],
        payload: importEBMLElement([0xE7], payload: Data([0x00])) + block
    )
    return ebmlHeader
        + Data([0x18, 0x53, 0x80, 0x67, 0x01])
        + Data(repeating: 0xFF, count: 7)
        + tracks
        + cluster
}

private func importEBMLElement(_ id: [UInt8], payload: Data) -> Data {
    precondition(payload.count < 127)
    return Data(id) + Data([0x80 | UInt8(payload.count)]) + payload
}

private func importFloat64(_ value: Double) -> Data {
    var bits = value.bitPattern.bigEndian
    return withUnsafeBytes(of: &bits) { Data($0) }
}
