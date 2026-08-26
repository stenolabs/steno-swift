import Foundation
import StenoLibrary
import Testing
import StenoDomain
@testable import StenoPipeline

@Suite("Template render request template resolution")
struct TemplateRenderRequestResolutionTests {
    private func makeSuiteDefaults() -> UserDefaults {
        let suiteName = "template-render-resolution-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("locked builtins resolve without any stored catalog")
    func builtinResolution() {
        #expect(
            TemplateRenderRequest.template(
                for: Template.meetingMinutes.id,
                defaults: makeSuiteDefaults()
            ) == .meetingMinutes
        )
        #expect(TemplateRenderRequest.template(for: "nope", defaults: makeSuiteDefaults()) == nil)
    }

    @Test("an override shadows the builtin for the same id")
    func overrideWins() throws {
        let defaults = makeSuiteDefaults()
        var catalog = TemplateCatalog()
        catalog.upsertOverride(.standup, forBuiltinID: "sales-call")
        TemplateCatalogStore(defaults: defaults).save(catalog)

        let resolved = try #require(
            TemplateRenderRequest.template(for: "sales-call", defaults: defaults)
        )
        #expect(resolved.name == "Standup")
    }

    @Test("custom markdown templates resolve through their structured projection")
    func customResolves() throws {
        let defaults = makeSuiteDefaults()
        var catalog = TemplateCatalog()
        catalog.upsertCustom(
            CustomTemplate(id: "retro", name: "Retro", description: "", body: "Retro prompt.")
        )
        TemplateCatalogStore(defaults: defaults).save(catalog)

        let resolved = try #require(
            TemplateRenderRequest.template(for: "retro", defaults: defaults)
        )
        #expect(resolved.id == "retro")
        #expect(resolved.generatedSections.count == 1)

        // Unknown ids still fail validation so enqueue rejects them.
        #expect(TemplateRenderRequest.template(for: "ghost", defaults: defaults) == nil)
    }

    // MARK: - Report-run precedence (explicit > pin > default > minutes)

    @Test("precedence: explicit beats pinned beats catalog default beats meeting minutes")
    func precedence() throws {
        let defaults = makeSuiteDefaults()
        var catalog = TemplateCatalog()
        catalog.setDefault(id: "standup")
        // The pin target must resolve through the catalog like a saved
        // custom template would; otherwise the pin correctly falls through.
        catalog.upsertCustom(CustomTemplate(
            id: "action-items",
            name: "Action Items",
            description: "Collect decisions and owners.",
            body: "List every action item with its owner."
        ))
        TemplateCatalogStore(defaults: defaults).save(catalog)

        // No explicit, no pin: the catalog default applies.
        #expect(
            TemplateRenderRequest.resolveReportTemplateID(
                explicit: nil,
                pinned: nil,
                defaults: defaults
            ) == "standup"
        )
        // The pin outranks the catalog default.
        #expect(
            TemplateRenderRequest.resolveReportTemplateID(
                explicit: nil,
                pinned: "action-items",
                defaults: defaults
            ) == "action-items"
        )
        // An explicit per-run choice outranks everything.
        #expect(
            TemplateRenderRequest.resolveReportTemplateID(
                explicit: "sales-call",
                pinned: "action-items",
                defaults: defaults
            ) == "sales-call"
        )
    }

    @Test("a stale pin falls through to the catalog default instead of failing")
    func stalePinFallsThrough() {
        let defaults = makeSuiteDefaults()
        #expect(
            TemplateRenderRequest.resolveReportTemplateID(
                explicit: nil,
                pinned: "deleted-custom",
                defaults: defaults
            ) == Template.meetingMinutes.id
        )
    }

    @Test("no choice anywhere resolves to Meeting Minutes")
    func bareFallback() {
        let defaults = makeSuiteDefaults()
        #expect(
            TemplateRenderRequest.resolveReportTemplateID(
                explicit: nil,
                pinned: nil,
                defaults: defaults
            ) == Template.meetingMinutes.id
        )
    }

    // MARK: - Pin write/read round-trip on meeting metadata

    private func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-pin-\(UUID())", isDirectory: true)
        return try Library.open(at: root)
    }

    @Test("pin survives a library round-trip and decodes legacy documents as nil")
    func pinRoundTrip() async throws {
        let library = try makeLibrary()
        let meeting = try await library.createMeeting(title: "Pinned", status: .ready)

        // Before any choice: no pin at all.
        var loaded = try await library.loadMeeting(meeting.id)
        #expect(loaded.metadata?.pinnedTemplateID == nil)

        try await library.setPinnedTemplate("action-items", for: meeting.id)
        loaded = try await library.loadMeeting(meeting.id)
        #expect(loaded.metadata?.pinnedTemplateID == "action-items")

        // Overwriting replaces the pin.
        try await library.setPinnedTemplate("standup", for: meeting.id)
        loaded = try await library.loadMeeting(meeting.id)
        #expect(loaded.metadata?.pinnedTemplateID == "standup")

        // Clearing returns to the unpinned state.
        try await library.setPinnedTemplate(nil, for: meeting.id)
        loaded = try await library.loadMeeting(meeting.id)
        #expect(loaded.metadata?.pinnedTemplateID == nil)
    }

    @Test("legacy metadata JSON without a pin key decodes unchanged")
    func legacyMetadataDecodes() throws {
        let json = #"{"legacyFolders":[]}"#.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: json)
        #expect(metadata.pinnedTemplateID == nil)

        let encoded = try JSONEncoder().encode(
            metadata.withPinnedTemplateID("standup")
        )
        let decoded = try JSONDecoder().decode(MeetingMetadata.self, from: encoded)
        #expect(decoded.pinnedTemplateID == "standup")
    }

    // MARK: - One-shot reset semantics

    @Test("the dock choice is one-shot: reset after stop clears it")
    func oneShotReset() {
        var choice = RecordingTemplateChoice()
        #expect(choice.pinnedTemplateID == nil)

        choice.choose("action-items")
        #expect(choice.pinnedTemplateID == "action-items")

        choice.resetAfterStop()
        #expect(choice.pinnedTemplateID == nil)
        #expect(!choice.continuesExistingMeeting)
    }

    @Test("continue recordings adopt but never override an existing pin")
    func continueNeverOverrides() {
        var choice = RecordingTemplateChoice()
        choice.beginExistingMeeting(pinnedTemplateID: "standup")
        #expect(choice.pinnedTemplateID == "standup")

        // Even an explicit pick during a continue run is ignored.
        choice.choose("action-items")
        #expect(choice.pinnedTemplateID == "standup")
        #expect(choice.continuesExistingMeeting)

        // Stop resets both the display pin and the continue flag.
        choice.resetAfterStop()
        #expect(choice.pinnedTemplateID == nil)
    }

    @Test("a fresh recording starts from the previous stop's clean slate")
    func newRecordingAfterReset() {
        var choice = RecordingTemplateChoice()
        choice.choose("standup")
        choice.resetAfterStop()
        choice.beginNewMeeting()
        #expect(choice.pinnedTemplateID == nil)
        #expect(!choice.continuesExistingMeeting)

        choice.choose("retro")
        #expect(choice.pinnedTemplateID == "retro")
    }
}
