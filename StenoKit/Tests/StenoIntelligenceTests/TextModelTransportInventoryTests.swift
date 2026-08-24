import Foundation
import Testing

/// Erzwingt, dass StenoIntelligence keine zweite Stelle bekommt, die eine
/// eigene URLSession baut. Die Umleitungssperre lebt genau einmal in
/// TextModelHTTPClient.swift (siehe RedirectBlockingURLSessionDelegate dort);
/// jede weitere URLSession-Konstruktion in diesem Modul wuerde daran vorbei
/// senden koennen, ohne die Sperre je zu durchlaufen.
///
/// Das ist kein Stilcheck: Die spaeteren Provider-Dateien (Ollama, LM
/// Studio, Anthropic, OpenAI Responses, Amazon Bedrock) muessen ausschliesslich
/// ueber TextModelHTTPClient senden. Wer eine solche Datei unveraendert aus
/// einem Altbranch uebernimmt, der noch `URLSession(session: .shared)` an
/// einen Provider-Init reicht, macht diesen Test rot, bevor der Provider je
/// gesendet hat.
@Suite("Text model transport inventory")
struct TextModelTransportInventoryTests {
    @Test("URLSession is constructed only inside TextModelHTTPClient.swift")
    func urlSessionConstructionIsConfinedToTheHTTPClient() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourcesDirectory = testFile
            .deletingLastPathComponent() // StenoIntelligenceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // StenoKit
            .appendingPathComponent("Sources")
            .appendingPathComponent("StenoIntelligence")

        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourcesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(!sourceFiles.isEmpty)

        var violations: [String] = []
        for file in sourceFiles where file.lastPathComponent != "TextModelHTTPClient.swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                if line.contains("URLSession(") || line.contains("URLSession.shared") {
                    violations.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            URLSession darf nur in TextModelHTTPClient.swift konstruiert werden. \
            Fund(e) ausserhalb: \(violations.joined(separator: ", ")). \
            Sende stattdessen ueber TextModelHTTPClient.
            """
        )
    }
}
