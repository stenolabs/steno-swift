import StenoDomain
import SwiftUI

/// Sheet for managing report templates: the locked built-in gallery,
/// user-defined markdown templates (create/edit/duplicate/delete) and
/// overrides of built-ins. Editing a built-in never touches the shipped
/// definition - it stores an independent copy ("override") that shadows it;
/// resetting deletes that copy and restores the locked original.
struct TemplateEditorView: View {
    var defaults: UserDefaults = .standard
    /// Called after every persisted mutation so open pickers can refresh.
    var onChanged: () -> Void = {}

    @State private var catalog = TemplateCatalog()
    @State private var draft: TemplateDraft?
    @State private var deleteConfirmation: CustomTemplate?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Built-in templates") {
                    ForEach(builtinEntries, id: \.template.id) { entry in
                        builtinRow(entry)
                    }
                }
                Section("Your templates") {
                    ForEach(catalog.customTemplates, id: \.id) { custom in
                        customRow(custom)
                    }
                    Button {
                        draft = .newCustom()
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Report Templates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $draft) { draft in
                TemplateDraftEditor(draft: draft) { saved in
                    persist(saved)
                }
            }
            .confirmationDialog(
                "Delete “\(deleteConfirmation?.name ?? "")”?",
                isPresented: Binding(
                    get: { deleteConfirmation != nil },
                    set: { if !$0 { deleteConfirmation = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let custom = deleteConfirmation {
                        catalog.removeCustom(id: custom.id)
                        persistCatalog()
                    }
                    deleteConfirmation = nil
                }
            }
            .onAppear(perform: reload)
        }
        .frame(width: 460, height: 520)
    }

    private var builtinEntries: [ResolvedTemplateEntry] {
        catalog.resolvedEntries().filter { $0.kind != .custom }
    }

    // MARK: Rows

    private func builtinRow(_ entry: ResolvedTemplateEntry) -> some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: entry.kind == .builtin ? "lock" : "pencil.line")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.template.name)
                Text(rowCaption(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if catalog.defaultTemplateID == entry.template.id {
                Text("Default")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Menu("Edit") {
                Button("Edit…") {
                    draft = TemplateDraft.overrideDraft(
                        builtinID: entry.kind == .builtin
                            ? entry.template.id
                            : entry.original?.id ?? entry.template.id,
                        current: entry.template
                    )
                }
                if entry.kind == .override(builtinID: entry.template.id)
                    || entry.original != nil
                {
                    Button("Reset to Original", role: .destructive) {
                        catalog.removeOverride(forBuiltinID: entry.original?.id ?? entry.template.id)
                        persistCatalog()
                    }
                }
                Button(catalog.defaultTemplateID == entry.template.id ? "Default" : "Set as Default") {
                    catalog.setDefault(id: entry.template.id)
                    persistCatalog()
                }
                .disabled(catalog.defaultTemplateID == entry.template.id)
            }
            .fixedSize()
        }
    }

    private func rowCaption(_ entry: ResolvedTemplateEntry) -> String {
        let state = entry.kind == .builtin ? "Locked original" : "Edited copy"
        return "\(state) · v\(entry.template.version)"
    }

    private func customRow(_ custom: CustomTemplate) -> some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(custom.name)
                Text("Markdown · v\(custom.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if catalog.defaultTemplateID == custom.id {
                Text("Default")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Menu("Edit") {
                Button("Edit…") {
                    draft = TemplateDraft.existingDraft(custom)
                }
                Button("Duplicate…") {
                    draft = TemplateDraft.duplicateDraft(custom)
                }
                Button("Set as Default") {
                    catalog.setDefault(id: custom.id)
                    persistCatalog()
                }
                .disabled(catalog.defaultTemplateID == custom.id)
                Button("Delete…", role: .destructive) {
                    deleteConfirmation = custom
                }
            }
            .fixedSize()
        }
    }

    // MARK: Persistence

    private func reload() {
        catalog = TemplateCatalogStore(defaults: defaults).load()
    }

    private func persist(_ draft: TemplateDraft) {
        switch draft.mode {
        case .newCustom:
            let existingIDs = Set(catalog.customTemplates.map(\.id))
            let custom = CustomTemplate(
                id: TemplateAuthoring.newID(from: draft.name, existingIDs: existingIDs),
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: draft.description,
                body: draft.body
            )
            catalog.upsertCustom(custom)
        case .existingCustom(let id, _):
            guard var custom = catalog.customTemplates.first(where: { $0.id == id }) else { break }
            custom = CustomTemplate(
                id: custom.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: draft.description,
                body: draft.body,
                version: custom.version + 1
            )
            catalog.upsertCustom(custom)
        case .builtinOverride(let builtinID, _, _, _):
            guard let builtin = Template.builtin(id: builtinID) else { break }
            let generated = builtin.generatedSections
            let updatedSections = builtin.sections.map { section in
                guard section.source == .generated,
                      let index = generated.firstIndex(where: { $0.id == section.id }),
                      index < draft.sectionPrompts.count
                else { return section }
                return TemplateSection(
                    id: section.id,
                    title: section.title,
                    prompt: draft.sectionPrompts[index],
                    source: section.source
                )
            }
            let previousVersion = catalog.overrides[builtinID]?.version
            catalog.upsertOverride(
                Template(
                    id: builtin.id,
                    name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: draft.description,
                    version: (previousVersion ?? builtin.version),
                    sections: updatedSections,
                    prompts: builtin.prompts
                ),
                forBuiltinID: builtinID
            )
        }
        persistCatalog()
    }

    private func persistCatalog() {
        TemplateCatalogStore(defaults: defaults).save(catalog)
        onChanged()
    }
}

/// One editing session over a template draft, presented as its own sheet.
/// The sheet owns its working copy and closes itself via dismiss; the parent
/// receives validated drafts through onSave only.
struct TemplateDraftEditor: View {
    let draft: TemplateDraft
    let onSave: (TemplateDraft) -> Void

    @State private var working: TemplateDraft
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss

    init(draft: TemplateDraft, onSave: @escaping (TemplateDraft) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _working = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $working.name)
                TextField("Description", text: $working.description)
                switch working.mode {
                case .newCustom, .existingCustom:
                    Section("Instructions (Markdown)") {
                        TextEditor(text: $working.body)
                            .frame(minHeight: 160)
                            .font(.system(size: 12, design: .monospaced))
                    }
                case .builtinOverride(_, let sections, _, _):
                    Section("Section instructions") {
                        ForEach(sections.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sections[index].title)
                                    .font(.caption.weight(.medium))
                                TextField("Section instruction", text: $working.sectionPrompts[index])
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Steno.Colors.error)
                        .font(.callout)
                }
            }
            .padding()
            .navigationTitle(working.sheetTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .frame(width: 420, height: 420)
    }

    private func save() {
        if let error = TemplateAuthoring.validate(name: working.name, body: working.body) {
            validationError = error
            return
        }
        onSave(working)
        dismiss()
    }
}

/// Editable snapshot behind one TemplateDraftEditor session.
struct TemplateDraft: Equatable, Identifiable {
    enum Mode: Equatable {
        case newCustom
        case existingCustom(id: String, version: Int)
        case builtinOverride(
            builtinID: String,
            generatedSections: [TemplateSection],
            previousVersion: Int?,
            originalVersion: Int
        )
    }

    var id: String { "\(mode)" }
    var mode: Mode
    var name: String
    var description: String
    /// Markdown instruction body (customs only).
    var body: String
    /// Prompts parallel to the built-in's generated sections (overrides only).
    var sectionPrompts: [String]

    static func newCustom() -> TemplateDraft {
        TemplateDraft(
            mode: .newCustom,
            name: "",
            description: "",
            body: "",
            sectionPrompts: []
        )
    }

    static func existingDraft(_ custom: CustomTemplate) -> TemplateDraft {
        TemplateDraft(
            mode: .existingCustom(id: custom.id, version: custom.version),
            name: custom.name,
            description: custom.description,
            body: custom.body,
            sectionPrompts: []
        )
    }

    static func duplicateDraft(_ custom: CustomTemplate) -> TemplateDraft {
        TemplateDraft(
            mode: .newCustom,
            name: "\(custom.name) (copy)",
            description: custom.description,
            body: custom.body,
            sectionPrompts: []
        )
    }

    /// Starts an override copy of the given built-in. If an override already
    /// exists, edits that copy in place.
    static func overrideDraft(builtinID: String, current: Template) -> TemplateDraft {
        TemplateDraft(
            mode: .builtinOverride(
                builtinID: builtinID,
                generatedSections: current.generatedSections,
                previousVersion: current.version,
                originalVersion: Template.builtin(id: builtinID)?.version ?? 1
            ),
            name: current.name,
            description: current.description,
            body: "",
            sectionPrompts: current.generatedSections.map(\.prompt)
        )
    }

    var sheetTitle: String {
        switch mode {
        case .newCustom: "New Template"
        case .existingCustom: "Edit Template"
        case .builtinOverride: "Edit Built-in Copy"
        }
    }
}
