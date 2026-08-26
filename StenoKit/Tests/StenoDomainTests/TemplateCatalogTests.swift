import Foundation
import Testing
@testable import StenoDomain

@Suite("Template catalog")
struct TemplateCatalogTests {
    private func makeSuiteDefaults() -> UserDefaults {
        let suiteName = "template-catalog-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: Built-in gallery

    @Test("builtin gallery ships the five expected templates in order")
    func builtinGallery() {
        #expect(Template.builtinTemplates.map(\.id) == [
            "meeting-minutes",
            "product-demo",
            "sales-call",
            "one-on-one",
            "standup",
        ])
        #expect(Template.builtin(id: "standup")?.name == "Standup")
        #expect(Template.builtin(id: "nope") == nil)
    }

    @Test("new builtin templates keep hallucination guards and data-based participants")
    func builtinGuardsAndSections() throws {
        for id in ["product-demo", "sales-call", "one-on-one", "standup"] {
            let template = try #require(Template.builtin(id: id))
            #expect(
                template.sections.first { $0.source == .speakerList } != nil,
                "\(id) must fill participants deterministically"
            )
            let generatedPrompts = template.generatedSections.map(\.prompt).joined()
            #expect(
                generatedPrompts.contains("Do not invent"),
                "\(id) sections must carry the no-invention guard"
            )
            #expect(
                template.prompts.reduceInstructions.contains("Do not add anything"),
                "\(id) reduce instructions must forbid unsupported additions"
            )
            // Locked originals never drift from version 1.
            #expect(template.version == 1)
        }
    }

    @Test("stored templates without a version field decode as version 1")
    func legacyTemplateDecode() throws {
        let legacyJSON = Data("""
        {
          "id": "meeting-minutes",
          "name": "Meeting Minutes",
          "description": "d",
          "sections": [],
          "prompts": {"role": "r", "mapInstructions": "m", "reduceInstructions": "s"}
        }
        """.utf8)

        let template = try JSONDecoder().decode(Template.self, from: legacyJSON)
        #expect(template.version == 1)
    }

    // MARK: Override semantics

    @Test("editing a builtin resolves to the override copy; reset restores the locked original")
    func overrideAndReset() throws {
        var catalog = TemplateCatalog()
        #expect(catalog.resolve(id: "standup") == Template.standup)

        var overridden = Template.standup
        overridden = Template(
            id: overridden.id,
            name: "My Standup",
            description: overridden.description,
            version: overridden.version + 1,
            sections: overridden.sections,
            prompts: overridden.prompts
        )
        catalog.upsertOverride(overridden, forBuiltinID: "standup")

        let resolved = try #require(catalog.resolve(id: "standup"))
        #expect(resolved.name == "My Standup")
        #expect(resolved.version == 2)

        let entries = catalog.resolvedEntries().first { $0.template.id == "standup" }
        #expect(entries?.kind == .override(builtinID: "standup"))
        #expect(entries?.original == Template.standup)

        catalog.removeOverride(forBuiltinID: "standup")
        #expect(catalog.resolve(id: "standup") == Template.standup)
    }

    @Test("override resolution wins over other lookups and leaves other builtins locked")
    func overrideIsolation() {
        var catalog = TemplateCatalog()
        catalog.upsertOverride(.standup, forBuiltinID: "meeting-minutes")
        // meeting-minutes is overridden, sales-call untouched.
        #expect(catalog.resolve(id: "sales-call") == .salesCall)
        #expect(catalog.resolve(id: "meeting-minutes")?.name == "Standup")
    }

    // MARK: Custom markdown templates

    @Test("custom markdown template projects onto a single guarded generated section")
    func customProjection() throws {
        let custom = CustomTemplate(
            id: "retro",
            name: "Retro",
            description: "Sprint retrospective.",
            body: "Collect what went well, what did not, and action items."
        )
        let template = custom.makeTemplate()

        #expect(template.version == 1)
        #expect(template.generatedSections.count == 1)
        let prompt = try #require(template.generatedSections.first?.prompt)
        #expect(prompt.contains("what went well"))
        #expect(prompt.contains(Template.hallucinationGuard))
    }

    @Test("custom CRUD round-trips and duplicate ids get slug suffixes")
    func customCRUDAndSlugIDs() {
        var catalog = TemplateCatalog()
        catalog.upsertCustom(
            CustomTemplate(id: "retro", name: "Retro", description: "", body: "b")
        )

        let secondID = TemplateAuthoring.newID(
            from: "Retro",
            existingIDs: Set(catalog.customTemplates.map(\.id))
        )
        catalog.upsertCustom(
            CustomTemplate(id: secondID, name: "Retro", description: "", body: "b")
        )
        #expect(secondID == "retro-2")
        #expect(catalog.customTemplates.count == 2)

        catalog.removeCustom(id: "retro")
        #expect(catalog.customTemplates.map(\.id) == ["retro-2"])
    }

    @Test("deleting the default custom clears the default pointer")
    func deleteClearsDefault() {
        var catalog = TemplateCatalog()
        catalog.upsertCustom(
            CustomTemplate(id: "retro", name: "Retro", description: "", body: "b")
        )
        catalog.setDefault(id: "retro")
        #expect(catalog.defaultTemplateID == "retro")

        catalog.removeCustom(id: "retro")
        #expect(catalog.defaultTemplateID == nil)
        #expect(catalog.resolvedDefault() == .meetingMinutes)
    }

    @Test("default falls back when it points at a missing id and accepts builtin ids")
    func defaultResolution() {
        var catalog = TemplateCatalog()
        catalog.setDefault(id: "standup")
        #expect(catalog.resolvedDefault().id == "standup")

        catalog.setDefault(id: "vanished")
        #expect(catalog.defaultTemplateID == nil)
        #expect(catalog.resolvedDefault() == .meetingMinutes)
    }

    // MARK: Authoring rules

    @Test("validation rejects empty and oversized drafts")
    func validation() {
        #expect(TemplateAuthoring.validate(name: "", body: "b") != nil)
        #expect(TemplateAuthoring.validate(name: "  ", body: "b") != nil)
        #expect(TemplateAuthoring.validate(name: "Ok", body: "   ") != nil)
        #expect(
            TemplateAuthoring.validate(
                name: String(repeating: "x", count: TemplateAuthoring.maxNameLength + 1),
                body: "b"
            ) != nil
        )
        #expect(
            TemplateAuthoring.validate(
                name: "Ok",
                body: String(repeating: "x", count: TemplateAuthoring.maxBodyLength + 1)
            ) != nil
        )
        #expect(TemplateAuthoring.validate(name: "Ok", body: "Real instructions.") == nil)
    }

    @Test("slug ids never collide with builtin ids")
    func slugsAvoidBuiltins() {
        let id = TemplateAuthoring.newID(from: "Standup", existingIDs: [])
        #expect(id == "standup-2")
        #expect(TemplateAuthoring.newID(from: "!!!", existingIDs: []) == "template")
    }

    // MARK: Persistence round-trip through UserDefaults

    @Test("catalog store round-trips overrides, customs, and default through defaults")
    func storeRoundTrip() {
        let defaults = makeSuiteDefaults()
        var catalog = TemplateCatalog()
        catalog.upsertOverride(.standup, forBuiltinID: "standup")
        catalog.upsertCustom(
            CustomTemplate(id: "retro", name: "Retro", description: "d", body: "b", version: 3)
        )
        catalog.setDefault(id: "retro")

        TemplateCatalogStore(defaults: defaults).save(catalog)
        let loaded = TemplateCatalogStore(defaults: defaults).load()

        #expect(loaded == catalog)
        #expect(loaded.resolve(id: "standup")?.name == "Standup")
        #expect(loaded.customTemplates.first?.version == 3)
    }

    @Test("a corrupt stored document loads as the pristine catalog")
    func corruptDocumentFallsBackCleanly() {
        let defaults = makeSuiteDefaults()
        defaults.set(Data("not json".utf8), forKey: TemplateCatalogStore.defaultsKey)
        let loaded = TemplateCatalogStore(defaults: defaults).load()

        #expect(loaded.overrides.isEmpty)
        #expect(loaded.customTemplates.isEmpty)
        #expect(loaded.resolvedDefault() == .meetingMinutes)
    }
}
