import Foundation
import StenoDomain
import StenoTranscription
import Testing
@testable import Steno

@Suite("iOS transcription model settings")
@MainActor
struct TranscriptionModelSettingsTests {
    @Test("a fresh installation defaults both choices to Apple")
    func defaultsToApple() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }

        #expect(fixture.settings.liveProviderID == .apple)
        #expect(fixture.settings.finalProviderID == .apple)
    }

    @Test("a selection persists across a new instance on the same defaults")
    func selectionPersists() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.settings.select(.parakeetTDTv3, for: .live)

        let reloaded = TranscriptionModelSettings(defaults: fixture.defaults)

        #expect(reloaded.liveProviderID == .parakeetTDTv3)
        #expect(reloaded.finalProviderID == .apple)
    }

    @Test("a stored but unknown provider falls back to the catalog default")
    func unknownStoredProviderFallsBack() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.defaults.set("some.retired-provider", forKey: "steno.transcription.model.final")

        let settings = TranscriptionModelSettings(defaults: fixture.defaults)

        #expect(settings.finalProviderID == .apple)
    }
}

@MainActor
private struct SettingsFixture {
    let name: String
    let defaults: UserDefaults
    let settings: TranscriptionModelSettings

    init() throws {
        name = "IOSTranscriptionModelSettingsTests-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        settings = TranscriptionModelSettings(defaults: defaults)
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}
