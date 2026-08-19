import Testing
@testable import StenoExchange

@Suite("Legacy person profile reader")
struct LegacyPersonProfilesTests {
    @Test("reads prototypes and hard negatives without losing dangling meeting stems")
    func readsProfiles() throws {
        let file = try LegacyPersonProfiles.read(
            from: Fixture.url("legacy_config", extension: "json")
        )

        let profile = try #require(file.profiles.first)
        #expect(profile.personID == "11111111-1111-4111-8111-111111111111")
        #expect(profile.displayName == "Ada")
        #expect(profile.prototypes.first?.embeddingMean.count == 256)
        #expect(profile.prototypes.first?.meetingID == "vorhandenes-meeting")
        #expect(profile.hardNegatives.first?.meetingID == "gelöschtes-meeting")
        #expect(profile.hardNegatives.first?.channel == nil)
        #expect(profile.hardNegatives.first?.createdFrom == .userCorrected)
    }
}
