import Testing
@testable import StenoDomain

@Suite("Channel labels")
struct ChannelLabelTests {
    @Test("speaker labels and track names are resolved by different functions")
    func speakerAndTrackAreSeparate() {
        #expect(ChannelLabel.speakerLabel("Ich") == "Me")
        #expect(ChannelLabel.speakerLabel("Andere") == "Others")
        #expect(ChannelLabel.trackName("micTrack") == "Microphone")
        #expect(ChannelLabel.trackName("systemTrack") == "System audio")
        #expect(ChannelLabel.trackName("imported") == "Imported track")
    }

    @Test("a speaker label function does not answer for track kinds")
    func speakerLabelLeavesTrackKindsAlone() {
        #expect(ChannelLabel.speakerLabel("micTrack") == "micTrack")
        #expect(ChannelLabel.speakerLabel("imported") == "imported")
    }

    /// Die Gegenrichtung: `trackName` darf ein Sprecherlabel nicht
    /// beantworten. Faellt die Trennung, wuerde das spaetere Bindungs-Paket
    /// an zwei Stellen ansetzen muessen statt an einer.
    @Test("a track name function does not answer for speaker labels")
    func trackNameLeavesSpeakerLabelsAlone() {
        #expect(ChannelLabel.trackName("Ich") == "Ich")
        #expect(ChannelLabel.trackName("Andere") == "Andere")
    }
}
