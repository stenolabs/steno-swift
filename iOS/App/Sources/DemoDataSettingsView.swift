import StenoDemo
import SwiftUI

/// A deliberately compact operations surface, not a general settings pane.
/// The provenance summary is first because it tells the user what can safely
/// happen before any destructive-looking control appears.
struct DemoDataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmation: ConfirmationAction?

    private enum ConfirmationAction: Identifiable {
        case install
        case replace
        case remove

        var id: String {
            switch self {
            case .install: "install"
            case .replace: "replace"
            case .remove: "remove"
            }
        }
    }

    private var actionPolicy: DemoDataActionPolicy {
        DemoDataPresentation.actionPolicy(for: model.demoDataStatus)
    }

    private var operationIsInFlight: Bool {
        model.demoDataOperation != nil
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(DemoDataPresentation.summaryTitle)
                        .font(.headline)
                    Text(DemoDataPresentation.provenanceDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    localBoundaryLabels
                }
                .padding(.vertical, 4)
            }

            Section(DemoDataPresentation.statusTitle) {
                if let operation = model.demoDataOperation {
                    LabeledContent {
                        ProgressView()
                            .accessibilityLabel(operation.title)
                    } label: {
                        Text(operation.title)
                    }
                } else {
                    Text(DemoDataPresentation.statusText(model.demoDataStatus))
                        .foregroundStyle(.secondary)
                }

                if let status = model.demoDataStatus {
                    ForEach(DemoDataPresentation.itemPresentations(for: status)) { item in
                        demoItemRow(item)
                    }
                }

                if let result = model.demoDataResult {
                    LabeledContent(
                        DemoDataPresentation.hasPartialResult(result)
                            ? DemoDataPresentation.partialResultTitle
                            : DemoDataPresentation.completedResultTitle
                    ) {
                        Text(DemoDataPresentation.resultText(result))
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.demoDataError {
                    errorRow(DemoDataPresentation.mutationErrorTitle, detail: error)
                }
                if let error = model.demoDataStatusError {
                    errorRow(DemoDataPresentation.statusErrorTitle, detail: error)
                }
                if let error = model.demoDataReconciliationError {
                    errorRow(DemoDataPresentation.reconciliationErrorTitle, detail: error)
                }
            }

            Section {
                Button(DemoDataPresentation.installAction) {
                    confirmation = .install
                }
                .disabled(operationIsInFlight || !actionPolicy.install)

                Button(DemoDataPresentation.replaceAction) {
                    confirmation = .replace
                }
                .disabled(operationIsInFlight || !actionPolicy.replace)

                Button(DemoDataPresentation.removeAction, role: .destructive) {
                    confirmation = .remove
                }
                .disabled(operationIsInFlight || !actionPolicy.remove)
            }

            Section(DemoDataPresentation.attributionTitle) {
                Text(DemoDataPresentation.attributionDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(DemoDataPresentation.title)
        .task { await model.refreshDemoDataStatus() }
        .alert(
            confirmationTitle,
            isPresented: confirmationIsPresented,
            presenting: confirmation
        ) { action in
            ForEach(confirmationDefinition(for: action).buttons) { button in
                Button(button.title, role: buttonRole(for: button.role)) {
                    performConfirmationAction(button.id)
                }
            }
        } message: { action in
            Text(confirmationDefinition(for: action).message)
        }
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )
    }

    private var confirmationTitle: LocalizedStringResource {
        guard let confirmation else { return DemoDataPresentation.title }
        return confirmationDefinition(for: confirmation).title
    }

    private func confirmationDefinition(
        for action: ConfirmationAction
    ) -> DemoDataPresentation.Confirmation {
        switch action {
        case .install:
            DemoDataPresentation.installConfirmation
        case .replace:
            DemoDataPresentation.replacementConfirmation
        case .remove:
            DemoDataPresentation.removeConfirmation
        }
    }

    private func buttonRole(
        for role: DemoDataPresentation.ConfirmationButtonRole
    ) -> ButtonRole? {
        switch role {
        case .regular: nil
        case .destructive: .destructive
        case .cancel: .cancel
        }
    }

    private func performConfirmationAction(
        _ id: DemoDataPresentation.ConfirmationButtonID
    ) {
        guard let command = DemoDataPresentation.lifecycleCommand(for: id) else {
            return
        }
        switch command {
        case .install:
            Task { await model.installDemoData() }
        case .replace(let replacingEditedMeetings):
            Task {
                await model.replaceDemoData(
                    replacingEditedMeetings: replacingEditedMeetings
                )
            }
        case .remove:
            Task { await model.removeDemoData() }
        }
    }

    private var localBoundaryLabels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Label(DemoDataPresentation.noNetwork, systemImage: "lock")
                Label(DemoDataPresentation.noModels, systemImage: "cpu")
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 4) {
                Label(DemoDataPresentation.noNetwork, systemImage: "lock")
                Label(DemoDataPresentation.noModels, systemImage: "cpu")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func demoItemRow(
        _ item: DemoDataPresentation.ItemPresentation
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint = item.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
        }
    }

    private func errorRow(
        _ title: LocalizedStringResource,
        detail: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
    }
}
