#if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Native Gemma model settings")
@MainActor
struct NativeGemmaModelSettingsTests {
    @Test("only the exact persisted production snapshot is restored")
    func restoresOnlyProductionSnapshot() throws {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let approved = NativeGemmaProviderCatalog.gemma4E2BSnapshot
        fixture.defaults.set(
            try JSONEncoder().encode(approved),
            forKey: DefaultsFixture.selectionKey
        )

        let restored = NativeGemmaModelSettings(defaults: fixture.defaults)
        #expect(restored.selectedSnapshot == approved)

        fixture.defaults.set(
            try JSONEncoder().encode(unapprovedSnapshot()),
            forKey: DefaultsFixture.selectionKey
        )
        let rejected = NativeGemmaModelSettings(defaults: fixture.defaults)
        #expect(rejected.selectedSnapshot == nil)
    }

    @Test("deselect removes the persisted native selection")
    func deselectPersists() throws {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        fixture.defaults.set(
            try JSONEncoder().encode(NativeGemmaProviderCatalog.gemma4E2BSnapshot),
            forKey: DefaultsFixture.selectionKey
        )
        let settings = NativeGemmaModelSettings(defaults: fixture.defaults)

        settings.deselect()

        #expect(settings.selectedSnapshot == nil)
        #expect(fixture.defaults.data(forKey: DefaultsFixture.selectionKey) == nil)
        #expect(NativeGemmaModelSettings(defaults: fixture.defaults).selectedSnapshot == nil)
    }

    private func unapprovedSnapshot() -> NativeGemmaModelSnapshot {
        NativeGemmaModelSnapshot(
            modelIdentifier: "mlx-community/unapproved-gemma",
            checkpointRevision: String(repeating: "a", count: 40),
            adapterRevision: String(repeating: "b", count: 40),
            licenseIdentifier: "gemma",
            manifestSHA256: String(repeating: "c", count: 64)
        )
    }
}

private struct DefaultsFixture {
    static let selectionKey = "steno.nativeGemma.selection"

    let suiteName = "NativeGemmaModelSettingsTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
#endif
