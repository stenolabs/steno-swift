import Foundation
import Testing
@testable import StenoLibrary

@Suite("AtomicFile")
struct AtomicFileTests {
    @Test("writes new data and atomically replaces existing data")
    func writeAndReplace() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("document.json")

            try AtomicFile.write(Data("old".utf8), to: destination)
            try AtomicFile.write(Data("new".utf8), to: destination)

            #expect(try Data(contentsOf: destination) == Data("new".utf8))
        }
    }

    @Test("an interruption before rename leaves the previous document intact")
    func interruptionBeforeRename() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("document.json")
            try AtomicFile.write(Data("old".utf8), to: destination)

            let prepared = try AtomicFile.prepare(
                Data("new".utf8),
                to: destination
            )
            defer { try? FileManager.default.removeItem(at: prepared.temporaryURL) }

            #expect(try Data(contentsOf: destination) == Data("old".utf8))
            #expect(try Data(contentsOf: prepared.temporaryURL) == Data("new".utf8))
        }
    }
}
