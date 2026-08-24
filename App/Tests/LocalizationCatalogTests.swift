import Foundation
import StenoIntelligence
import Testing
@testable import steno_macos

@Suite("macOS localization catalogs")
struct LocalizationCatalogTests {
    @Test("catalogs use English as source and provide German translations")
    func catalogsHaveCompleteGermanTranslations() throws {
        let localizable = try catalog(named: "Localizable")
        let infoPlist = try catalog(named: "InfoPlist")

        #expect(localizable.sourceLanguage == "en")
        #expect(infoPlist.sourceLanguage == "en")
        #expect(localizable.version == "1.0")
        #expect(infoPlist.version == "1.0")
        expectGermanTranslations(in: localizable)
        expectGermanTranslations(in: infoPlist)
    }

    @Test("InfoPlist catalog contains macOS privacy usage descriptions")
    func infoPlistContainsPlatformPrivacyKeys() throws {
        let catalog = try catalog(named: "InfoPlist")
        let expected: [String: (english: String, german: String)] = [
            "NSMicrophoneUsageDescription": (
                "Steno records your microphone so it can transcribe conversations locally on this Mac.",
                "Steno verwendet dein Mikrofon, um Gespräche lokal auf diesem Mac zu transkribieren."
            ),
            "NSAudioCaptureUsageDescription": (
                "Steno records system audio so it can transcribe the people you talk to in calls, locally on this Mac.",
                "Steno zeichnet Systemaudio auf, um die Personen in deinen Gesprächen lokal auf diesem Mac zu transkribieren."
            ),
        ]

        for (key, values) in expected {
            let entry = try #require(catalog.strings[key], "Missing InfoPlist key: \(key)")
            #expect(entry.localizations["en"]?.stringUnit?.value == values.english)
            #expect(entry.localizations["de"]?.stringUnit?.value == values.german)
        }
    }

    @Test("dynamic presentation copy localizes with interpolation")
    func dynamicPresentationCopyLocalizes() throws {
        let german = Locale(identifier: "de")
        let endpoint = TextModelEndpoint(
            name: "Lokal",
            baseURL: try #require(URL(string: "https://models.example.com/v1")),
            modelID: "gemma",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )

        #expect(
            localized(
                MacStartupFailure.runtimeOpening("Datenträgerfehler").title,
                locale: german
            ) == "Die Bibliothek konnte nicht geöffnet werden"
        )
        #expect(
            localized(
                MacStartupFailure.runtimeOpening("Datenträgerfehler").explanation,
                locale: german
            ) == "Steno konnte das Öffnen der lokalen Bibliothek nicht abschließen. Versuche es erneut, um dieselbe lokale Bibliothek zu verwenden. Datenträgerfehler"
        )
        #expect(
            localized(
                MacTextModelEndpointPresentation.deletionMessage(for: endpoint),
                locale: german
            ) == "Beim Löschen von „Lokal“ werden die Konfiguration und der gespeicherte API-Schlüssel von diesem Mac entfernt. Dies kann nicht rückgängig gemacht werden."
        )
        #expect(
            localized(
                DemoDataPresentation.reviewProgressTitle(
                    SpeakerReviewPresentation.ReviewProgress(
                        reviewed: 1,
                        total: 3
                    )
                ),
                locale: german
            ) == "1 von 3 geprüft"
        )
        #expect(
            localized(DemoDataPresentation.installAction, locale: german)
                == "Demo-Meetings installieren"
        )
    }

    private func expectGermanTranslations(in catalog: StringCatalog) {
        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            let german = entry.localizations["de"]?.stringUnit
            #expect(
                german?.state == "translated",
                "Missing translated German value for \(key)"
            )
            #expect(
                !(german?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                "German value is empty for \(key)"
            )
        }
    }

    private func catalog(named name: String) throws -> StringCatalog {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let url = resources.appendingPathComponent("\(name).xcstrings")
        return try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: url))
    }

    private func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: StringCatalogEntry]
    let version: String
}

private struct StringCatalogEntry: Decodable {
    let shouldTranslate: Bool?
    let localizations: [String: StringCatalogLocalization]

    private enum CodingKeys: String, CodingKey {
        case shouldTranslate
        case localizations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shouldTranslate = try container.decodeIfPresent(Bool.self, forKey: .shouldTranslate)
        localizations = try container.decodeIfPresent(
            [String: StringCatalogLocalization].self,
            forKey: .localizations
        ) ?? [:]
    }
}

private struct StringCatalogLocalization: Decodable {
    let stringUnit: StringCatalogStringUnit?
}

private struct StringCatalogStringUnit: Decodable {
    let state: String
    let value: String
}
