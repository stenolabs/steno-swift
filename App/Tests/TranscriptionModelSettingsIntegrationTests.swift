import Foundation
import StenoDomain
import StenoTranscription
import Testing
@testable import steno_macos

@Suite("Mac transcription model settings")
@MainActor
struct TranscriptionModelSettingsIntegrationTests {
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
        fixture.settings.select(.parakeetTDTv3, for: .final)

        let reloaded = TranscriptionModelSettings(defaults: fixture.defaults)

        #expect(reloaded.liveProviderID == .apple)
        #expect(reloaded.finalProviderID == .parakeetTDTv3)
    }

    @Test("a plan snapshots the current live and final choices")
    func snapshotsCurrentChoices() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.settings.select(.parakeetTDTv3, for: .final)
        let app = AppModel(
            transcriptionModels: fixture.settings,
            transcriptionRegistry: .appleOnly
        )

        let plan = app.currentTranscriptionPlan()

        #expect(plan.liveProviderID == .apple)
        #expect(plan.finalProviderID == .parakeetTDTv3)
    }

    @Test("model choices remain unlocked outside a recording")
    func choicesUnlockedByDefault() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let app = AppModel(
            transcriptionModels: fixture.settings,
            transcriptionRegistry: .appleOnly
        )

        #expect(app.canChangeTranscriptionModels)
    }

    @Test("a stored but unknown provider falls back to the catalog default")
    func unknownStoredProviderFallsBack() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.defaults.set("some.retired-provider", forKey: "steno.transcription.model.final")

        let settings = TranscriptionModelSettings(defaults: fixture.defaults)

        #expect(settings.finalProviderID == .apple)
    }

    @Test("Apple never needs an installation, an unchecked Parakeet does")
    func installedStateIsFailClosedForParakeet() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let app = AppModel(
            transcriptionModels: fixture.settings,
            transcriptionRegistry: .appleOnly
        )

        #expect(app.isTranscriptionModelInstalled(.apple))
        // Ohne einen zuvor erfolgten `refreshParakeetReadiness()`-Lauf ist
        // Parakeet nicht bekannt bereit - Falle 4: lieber nicht waehlbar als
        // faelschlich als verfuegbar gezeigt.
        #expect(!app.isTranscriptionModelInstalled(.parakeetTDTv3))
    }
}

@MainActor
private struct SettingsFixture {
    let name: String
    let defaults: UserDefaults
    let settings: TranscriptionModelSettings

    init() throws {
        name = "MacTranscriptionModelSettingsTests-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        settings = TranscriptionModelSettings(defaults: defaults)
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite("Transcription model selectability")
@MainActor
struct TranscriptionModelSelectabilityTests {
    /// Parakeet taucht bei "Live transcript" auf, ist dort aber gesperrt.
    /// Es einfach wegzulassen sah aus, als gaebe es die Wahl gar nicht - der
    /// Nutzer sucht dann nach etwas, das die Oberflaeche verschweigt.
    @Test("an experimental model is listed for live but not selectable")
    func experimentalModelIsVisibleButLocked() {
        let catalog = TranscriptionModelCatalog.standard
        let parakeet = catalog.descriptor(for: .parakeetTDTv3)

        #expect(parakeet?.maturity == .experimental)
        // Der Katalog laesst es zu, wenn der Aufrufer die Sperre kennt.
        #expect(catalog.supports(
            .parakeetTDTv3,
            use: .live,
            locale: Locale(identifier: "de-DE"),
            experimentalLiveEnabled: true
        ))
        // Und blendet es aus, wenn der Aufrufer sie nicht kennt.
        #expect(!catalog.supports(
            .parakeetTDTv3,
            use: .live,
            locale: Locale(identifier: "de-DE"),
            experimentalLiveEnabled: false
        ))
    }

    @Test("Apple stays selectable for both uses")
    func appleRemainsSelectable() {
        let catalog = TranscriptionModelCatalog.standard
        for use in [TranscriptionUse.live, .final] {
            #expect(catalog.supports(
                .apple,
                use: use,
                locale: Locale(identifier: "de-DE"),
                experimentalLiveEnabled: false
            ))
        }
    }
}

@Suite("Experimental live switch")
@MainActor
struct ExperimentalLiveSwitchTests {
    @Test("the switch is off until someone turns it on")
    func defaultsToOff() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }

        #expect(fixture.settings.liveExperimentalEnabled == false)
        #expect(fixture.settings.experimentalFeatures.parakeetLiveEnabled == false)
    }

    @Test("turning it on reaches the feature flags")
    func enablingReachesTheFeatureFlags() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }

        fixture.settings.setLiveExperimentalEnabled(true)

        #expect(fixture.settings.experimentalFeatures.parakeetLiveEnabled)
    }

    /// Waere die Wahl geblieben, zeigte die Oberflaeche ein Modell als aktiv,
    /// das ohne die Freischaltung gar nicht laufen kann - und der Nutzer
    /// erfuehre es erst an der stummen Live-Spur.
    @Test("turning it off drops a live choice that depends on it")
    func disablingResetsAnExperimentalLiveChoice() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.settings.setLiveExperimentalEnabled(true)
        fixture.settings.select(.parakeetTDTv3, for: .live)
        #expect(fixture.settings.liveProviderID == .parakeetTDTv3)

        fixture.settings.setLiveExperimentalEnabled(false)

        #expect(fixture.settings.liveProviderID == .apple)
    }

    @Test("the final choice is untouched by the switch")
    func finalChoiceSurvives() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        fixture.settings.select(.parakeetTDTv3, for: .final)

        fixture.settings.setLiveExperimentalEnabled(true)
        fixture.settings.setLiveExperimentalEnabled(false)

        #expect(fixture.settings.finalProviderID == .parakeetTDTv3)
    }
}
