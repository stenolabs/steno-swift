import Foundation
import Testing
@testable import StenoTranscription

@Suite("Local Parakeet model loader")
struct LocalParakeetModelLoaderTests {
    @Test("vocabulary rejects non-numeric token IDs")
    func rejectsInvalidVocabulary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"not-a-token":"word"}"#.utf8).write(
            to: directory.appendingPathComponent("parakeet_v3_vocab.json")
        )

        #expect(throws: (any Error).self) {
            try LocalParakeetModelLoader.vocabulary(from: directory)
        }
    }

    @Test("vocabulary maps numeric token IDs")
    func mapsVocabulary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"1":"Guten","2":"Morgen"}"#.utf8).write(
            to: directory.appendingPathComponent("parakeet_v3_vocab.json")
        )

        let vocabulary = try LocalParakeetModelLoader.vocabulary(from: directory)

        #expect(vocabulary == [1: "Guten", 2: "Morgen"])
    }
}
