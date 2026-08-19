import Foundation
import StenoDomain
import Testing
@testable import Steno

@Suite("iOS model consent")
struct ModelConsentTests {
    @Test("grant persists its first timestamp and the named source")
    @MainActor
    func grantPersistsRecord() throws {
        let suite = "ModelConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "consent"
        let consent = ModelConsent(defaults: defaults, key: key)

        consent.grant(sources: [.appleSystemAssets])
        let first = try #require(consent.record)
        consent.grant(sources: [.appleSystemAssets])

        #expect(consent.record?.grantedAt == first.grantedAt)
        #expect(consent.record?.sources == ["Apple"])
        #expect(ModelConsent(defaults: defaults, key: key).record == consent.record)
    }

    @Test("revoke removes consent without deleting installed assets")
    @MainActor
    func revokeRemovesRecord() throws {
        let suite = "ModelConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let consent = ModelConsent(defaults: defaults, key: "consent")
        consent.grant(sources: [.appleSystemAssets])

        consent.revoke()

        #expect(!consent.isGranted)
        #expect(consent.record == nil)
    }

    @Test("speech and diarization consent use independent persisted records")
    @MainActor
    func consentScopesAreIndependent() throws {
        let suite = "ModelConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = ModelConsent.speech(defaults: defaults)
        let diarization = ModelConsent.diarization(defaults: defaults)

        speech.grant(sources: [.appleSystemAssets])
        #expect(speech.record?.sources == ["Apple"])
        #expect(diarization.record == nil)

        diarization.grant(sources: [.huggingFace])
        speech.revoke()

        #expect(speech.record == nil)
        #expect(diarization.record?.sources == ["huggingface.co"])
        #expect(ModelConsent.diarization(defaults: defaults).record == diarization.record)
    }
}
