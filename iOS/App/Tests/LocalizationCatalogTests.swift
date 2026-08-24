import Foundation
import StenoDomain
import StenoIntelligence
import Testing
@testable import Steno

@Suite("iOS localization catalogs")
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

    @Test("InfoPlist catalog contains iOS privacy usage descriptions")
    func infoPlistContainsPlatformPrivacyKeys() throws {
        let catalog = try catalog(named: "InfoPlist")
        let expected: [String: (english: String, german: String)] = [
            "NSMicrophoneUsageDescription": (
                "Steno records your microphone so it can transcribe conversations locally on this device.",
                "Steno zeichnet dein Mikrofon auf, damit Gespräche lokal auf diesem Gerät transkribiert werden können."
            ),
            "NSLocalNetworkUsageDescription": (
                "Steno connects to a language model server only when you test it or explicitly generate minutes with it.",
                "Steno verbindet sich mit einem Sprachmodellserver nur, wenn du ihn testest oder ausdrücklich ein Protokoll erstellst."
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
                MeetingActionCopy.retranscriptionTitle(
                    meetingTitle: "Projektauftakt"
                ),
                locale: german
            ) == "„Projektauftakt“ erneut transkribieren?"
        )
        #expect(
            localized(MeetingActionCopy.retranscriptionMessage, locale: german)
                == "Steno fügt eine neue Transkriptrevision hinzu und behält das aktuelle Transkript und die Korrekturen als frühere Revisionen.\nDie Sprechertrennung läuft mit neuen Cluster-Kennungen erneut, daher müssen Sprecher danach erneut bestätigt werden.\nDeine Korrekturen werden niemals stillschweigend überschrieben."
        )
        #expect(
            localized(
                TextModelEndpointPresentation.deletionTitle(for: endpoint),
                locale: german
            ) == "Endpunkt „Lokal“ löschen?"
        )
        #expect(
            localized(
                TextModelEndpointPresentation.deletionMessage(for: endpoint),
                locale: german
            ).contains("gespeicherten API-Schlüssel")
        )
        #expect(
            localized(
                IOSStartupFailure.runtimeOpening("Datenträgerfehler").explanation,
                locale: german
            ) == "Steno konnte die lokale Bibliothek nicht öffnen. Datenträgerfehler"
        )
        #expect(
            localized(DemoDataPresentation.installAction, locale: german)
                == "Demo-Meetings installieren"
        )
        #expect(
            localized(ReportShareDisclosurePresentation.message, locale: german)
                == "Der ausgewählte Protokolltext wird an die gewählte App oder den gewählten Dienst übergeben. Audio, Stimmbelege und Einbettungen sind nicht enthalten."
        )

        let running = try #require(MeetingJobPresentation.make([
            Job(kind: .finalASR, meetingID: MeetingID(), status: .running)
        ]))
        #expect(
            localized(running.title, locale: german)
                == "Auf diesem Gerät transkribieren"
        )
        #expect(
            localized(running.message, locale: german)
                == "Schritt 1 von 3. Steno erstellt aus der Originalaufnahme ein neues Transkript."
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
