import Foundation
import Testing
@testable import StenoLibrary
import StenoDomain

@Suite("Folder appearance")
struct FolderAppearanceTests {
    // MARK: - Codable compatibility

    @Test("folders written before appearance fields decode with nil color and icon")
    func decodesLegacyFolderWithoutAppearance() throws {
        let folder = Folder(
            name: "Work",
            sortIndex: 0,
            colorToken: .blue,
            icon: .briefcase
        )
        var object = try jsonObject(of: folder)
        object.removeValue(forKey: "colorToken")
        object.removeValue(forKey: "icon")

        let decoded = try JSONDecoder().decode(
            Folder.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.colorToken == nil)
        #expect(decoded.icon == nil)
        #expect(decoded.name == "Work")
    }

    @Test("appearance round-trips through JSON")
    func appearanceRoundTripsThroughJSON() throws {
        let folder = Folder(
            name: "Work",
            sortIndex: 0,
            colorToken: .teal,
            icon: .people
        )

        let decoded = try JSONDecoder().decode(
            Folder.self,
            from: JSONEncoder().encode(folder)
        )

        #expect(decoded.colorToken == .teal)
        #expect(decoded.icon == .people)
    }

    @Test("an unknown color token aborts decoding")
    func rejectsUnknownColorToken() throws {
        var object = try jsonObject(of: Folder(name: "Work", sortIndex: 0))
        object["colorToken"] = "mauve"

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                Folder.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("an unknown icon aborts decoding")
    func rejectsUnknownIcon() throws {
        var object = try jsonObject(of: Folder(name: "Work", sortIndex: 0))
        object["icon"] = "rocket"

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                Folder.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("every palette token and allowlist icon survives a coding round-trip")
    func allCasesRoundTrip() throws {
        for token in FolderColorToken.allCases {
            let data = try JSONEncoder().encode([token])
            #expect(try JSONDecoder().decode([FolderColorToken].self, from: data) == [token])
        }
        for icon in FolderIcon.allCases {
            let data = try JSONEncoder().encode([icon])
            #expect(try JSONDecoder().decode([FolderIcon].self, from: data) == [icon])
        }
    }

    // MARK: - Store round-trip

    @Test("color and icon persist across a store reopen")
    func appearancePersistsAcrossReopen() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let folder = try await store.createFolder(name: "Clients")

            _ = try await store.setColorToken(.orange, of: folder.id)
            _ = try await store.setIcon(.target, of: folder.id)

            let reopened = try FolderStore.open(layout: library.layout)
            let stored = try await reopened.folder(folder.id)
            #expect(stored?.colorToken == .orange)
            #expect(stored?.icon == .target)
        }
    }

    @Test("clearing appearance restores the default look")
    func clearsAppearanceBackToNil() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)
            let folder = try await store.createFolder(name: "Clients")
            _ = try await store.setColorToken(.red, of: folder.id)
            _ = try await store.setIcon(.bookmark, of: folder.id)

            _ = try await store.setColorToken(nil, of: folder.id)
            _ = try await store.setIcon(nil, of: folder.id)

            let stored = try await store.folder(folder.id)
            #expect(stored?.colorToken == nil)
            #expect(stored?.icon == nil)
        }
    }

    @Test("appearance changes reject unknown folders without writing")
    func rejectsUnknownFolder() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try FolderStore.open(layout: library.layout)

            await #expect(throws: LibraryError.self) {
                try await store.setColorToken(.blue, of: FolderID())
            }
            await #expect(throws: LibraryError.self) {
                try await store.setIcon(.microphone, of: FolderID())
            }
        }
    }

    @Test("a schema 2 document without appearance fields reads as untinted folders")
    func readsSchema2DocumentWithoutAppearanceFields() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let document = """
            {"schemaVersion":2,"adoptedLegacyFolders":true,"folders":[\
            {"id":"D1D1D1D1-0000-0000-0000-000000000001","name":"Legacy",\
            "parentFolderID":null,"sortIndex":0,\
            "createdAt":76000000.0}]}
            """
            try Data(document.utf8).write(to: library.layout.folders)

            let store = try FolderStore.open(layout: library.layout)
            let folders = try await store.listFolders()

            #expect(folders.map(\.name) == ["Legacy"])
            #expect(folders.map(\.colorToken) == [nil])
            #expect(folders.map(\.icon) == [nil])
        }
    }

    /// Encodes a value and returns its JSON representation as a mutable
    /// object so individual keys can be stripped to simulate documents
    /// written by older app versions.
    private func jsonObject(of value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Expected a JSON object"
            ))
        }
        return object
    }
}
