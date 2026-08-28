import Foundation

/// Uebersetzt Kanal-Labels fuer die Anzeige. Kanal-Labels sind Datenwerte:
/// Sie stehen so in jedem gespeicherten Transkript und in bestehenden Alt-Importen.
/// Uebersetzt wird deshalb nur die Anzeige, nie der gespeicherte Wert.
///
/// Zwei getrennte Funktionen statt einer gemeinsamen, weil sie fachlich
/// verschiedenes tun: `speakerLabel` benennt einen Menschen an der Spur,
/// `trackName` benennt die Spur selbst. Nur `speakerLabel` meint je einen
/// Menschen; nur sie wird das spaetere Bindungs-Paket auf die Abfrage von
/// meeting.json umstellen.
public enum ChannelLabel {
    /// Loest ein Sprecher-Kanallabel auf. Das ist die einzige Stelle, an der
    /// aus "Ich" ein Mensch wird; das spaetere Bindungs-Paket ersetzt hier
    /// die feste Uebersetzung durch die Abfrage von meeting.json.
    public static func speakerLabel(_ raw: String) -> String {
        switch raw {
        case "Ich", "You": "Me"
        case "Andere": "Others"
        default: raw
        }
    }

    /// Benennt eine Spur. Meint nie einen Menschen.
    public static func trackName(_ raw: String) -> String {
        switch raw {
        case MediaAsset.Kind.micTrack.rawValue: "Microphone"
        case MediaAsset.Kind.systemTrack.rawValue: "System audio"
        case MediaAsset.Kind.imported.rawValue: "Imported track"
        default: raw
        }
    }
}
