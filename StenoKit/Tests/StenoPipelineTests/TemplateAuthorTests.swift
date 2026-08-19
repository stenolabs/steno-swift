import Testing
import Foundation
import StenoDomain
import StenoIntelligence
@testable import StenoPipeline

/// Der Verfassername geht **nicht** an ein Sprachmodell.
///
/// Er fiel zwar in die freigegebene Klasse "Teilnehmerliste, Namen und
/// Firmen" (PLAN-PRIVACY.md:52), aber keine Sektion von `Template
/// .meetingMinutes` fragt danach, wer das Protokoll schreibt. Eine
/// Uebertragung ohne Empfaenger ist eine Uebertragung ohne Nutzen.
///
/// Wer sich selbst als Anwesenden nennen will, tut das ueber die
/// Teilnehmerliste: entweder durch Bestaetigen des eigenen Sprechers oder
/// ueber "Add participant". Dieser Weg fuehrt den Namen mit Absicht.
@Suite("Template author")
struct TemplateAuthorTests {
    @Test("the render context has no place for an author at all")
    func renderContextCarriesNoAuthor() {
        let context = RenderContext(
            userNotes: "note",
            participants: ["Ada Lovelace (Stadt Musterstadt)"]
        )
        // Ohne diese Zusicherung koennte der Name ueber irgendein Feld
        // zurueckkehren, ohne dass ein Test es merkt.
        let mirror = Mirror(reflecting: context)
        let labels = mirror.children.compactMap(\.label)
        #expect(!labels.contains { $0.lowercased().contains("author") })
    }

    @Test("a job carries no author to pin")
    func jobCarriesNoAuthor() throws {
        let job = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            templateID: "meeting-minutes"
        )
        let encoded = try JSONEncoder().encode(job)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let fields = try #require(object as? [String: Any])
        #expect(fields["authorLine"] == nil)
    }

    @Test("a job stored while the author field existed still decodes")
    func jobWithLegacyAuthorLineStillDecodes() throws {
        let job = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            templateID: "meeting-minutes"
        )
        let encoded = try JSONEncoder().encode(job)
        let object = try JSONSerialization.jsonObject(with: encoded)
        var fields = try #require(object as? [String: Any])
        // Alte Jobs auf der Platte tragen den Schluessel noch. Er muss
        // folgenlos ueberlesen werden, sonst scheitert das Wiederaufsetzen
        // nach dem Update.
        fields["authorLine"] = "Ada Lovelace, Stadt Musterstadt"

        let decoded = try JSONDecoder().decode(
            Job.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
        #expect(decoded.schemaVersion == Job.currentSchemaVersion)
        #expect(decoded.templateID == "meeting-minutes")
    }

    @Test("the exported markdown header still carries the author")
    func markdownStillCarriesAuthor() {
        // Der Kopf des Exports bleibt: er entsteht lokal und verlaesst den
        // Rechner nur mit der Datei, die der Nutzer selbst weitergibt.
        let markdown = MeetingMarkdown.header(title: "Weekly", authorLine: "Ada Lovelace")
        #expect(markdown.contains("Ada Lovelace"))
    }
}
