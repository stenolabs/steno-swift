import Testing
import Foundation
import StenoDomain
import CryptoKit
@testable import StenoDiarization

@Suite("Model checksum manifest")
struct ModelChecksumManifestTests {
    private func makeFile(_ directory: URL, _ name: String, _ content: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try content.data(using: .utf8)!.write(to: url)
        let digest = SHA256.hash(data: content.data(using: .utf8)!)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @Test("matching bytes pass")
    func matchingBytesPass() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = try makeFile(directory, "weights.bin", "hello")
        let manifest = ModelChecksumManifest(entries: ["weights.bin": hash])
        try manifest.verify(directory: directory)
    }

    @Test("a single changed byte throws and names the file")
    func changedByteThrows() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = try makeFile(directory, "weights.bin", "hello")
        let manifest = ModelChecksumManifest(entries: ["weights.bin": String(repeating: "0", count: 64)])
        // Eigener Typ, damit die Oberflaeche ihn von einem Netzfehler
        // unterscheiden kann: nur hier sind alle Dateien da und trotzdem
        // falsch. Der Dateiname ist mitgeprueft, sonst haette die Meldung
        // keine Zaehne.
        #expect(throws: ModelIntegrityError.bytesDoNotMatch(
            file: "weights.bin",
            expected: String(repeating: "0", count: 64),
            actual: hash
        )) {
            try manifest.verify(directory: directory)
        }
    }

    @Test("a missing file throws")
    func missingFileThrows() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = ModelChecksumManifest(entries: ["absent.bin": String(repeating: "0", count: 64)])
        #expect(throws: ModelManifestError.self) {
            try manifest.verify(directory: directory)
        }
    }
}
