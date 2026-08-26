import AppKit
import SwiftUI
import StenoLibrary

/// Privacy/Beta rows for the library-encryption beta in the General tab.
///
/// Owns the full user flow around `LibraryEncryptionCoordinator`:
///
/// **Enable:** status row -> Enable -> double consent (recordings and voice
/// data get encrypted; the old library is kept as a backup until it is
/// deleted explicitly) -> prepare with progress UI -> recovery code display
/// with Copy and an "I have saved it" gate -> Activate -> success row plus an
/// optional Delete Backup.
///
/// **Disable:** mirrors enable without a code display; if the Keychain entry
/// was lost (`kekUnavailable`), a recovery-code field offers
/// `decryptWithRecoveryCode(_:)` before restaging.
///
/// Failure at any point keeps the old library untouched and surfaces the
/// error inline. A staging directory left behind by a previous run is offered
/// as "discard"; activation is deliberately NOT offered there, because the
/// recovery code of an encryption staging run was never displayed.
struct EncryptionSettingsSection: View {
    let layout: LibraryLayout

    @State private var flow = EncryptionFlowModel()

    var body: some View {
        Section("Library Encryption (Beta)") {
            content
        }
        .task(id: layout.root.path) { await flow.refresh(layout: layout) }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .idle:
            idleRows
        case .confirmingEnable:
            consentRows(
                title: "Encrypt this library?",
                detail:
                    "Your recordings, transcripts and voice prints will be "
                    + "encrypted on disk. Your current library is kept as a "
                    + "backup until you delete it explicitly after switching.",
                gate: "I understand my recordings will be encrypted",
                confirmation: "Prepare Encryption"
            )
        case .confirmingDisable:
            consentRows(
                title: "Decrypt this library?",
                detail:
                    "A plain copy of every file will be written and verified. "
                    + "The encrypted original is kept as a backup until you "
                    + "delete it explicitly after switching.",
                gate: "I understand my library will be stored unencrypted",
                confirmation: "Prepare Decryption"
            )
        case .preparing(let operation, let progress):
            preparingRows(operation: operation, progress: progress)
        case .reviewRecoveryCode(let code):
            recoveryCodeRows(code: code)
        case .awaitingActivation(let operation):
            awaitingActivationRows(operation: operation)
        case .recoveringKey:
            recoveryKeyRows
        }
    }

    // MARK: Idle / status rows

    @ViewBuilder
    private var idleRows: some View {
        if let status = flow.status {
            LabeledContent("Library") {
                Text(status.isEncrypted ? "Encrypted" : "Unencrypted")
            }
            if status.pendingOperation != nil {
                Text(
                    "An interrupted conversion was found next to the library. "
                        + "It can be discarded; your library is untouched."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Discard Interrupted Conversion", role: .destructive) {
                    Task { await flow.discardStaging() }
                }
            }
            if status.backupExists {
                LabeledContent("Pre-switch backup") {
                    Text("Present")
                        .foregroundStyle(.secondary)
                }
                ForEach(flow.existingBackupOperations, id: \.rawValue) { operation in
                    Button(
                        "Delete Backup (.\(operation.rawValue).bak)",
                        role: .destructive
                    ) {
                        Task { await flow.deleteBackup(operation) }
                    }
                }
                Text(
                    "The backup keeps your previous library until you delete "
                        + "it explicitly."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        Text(
            "Beta: encrypts the entire library at rest with a key held in the "
                + "Keychain. Keep the printed recovery code safe; it is the "
                + "only way back if the Keychain entry is lost."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let status = flow.status {
            if status.isEncrypted {
                Button("Disable Encryption…") { flow.beginDisable() }
                    .disabled(status.pendingOperation != nil)
            } else {
                Button("Enable Encryption…") { flow.beginEnable() }
                    .disabled(status.pendingOperation != nil)
            }
        }
        if let error = flow.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Button("Dismiss") { flow.dismissError() }
        }
    }

    // MARK: Double-consent rows

    @ViewBuilder
    private func consentRows(
        title: String,
        detail: String,
        gate: String,
        confirmation: String
    ) -> some View {
        Label(title, systemImage: "exclamationmark.shield")
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle(gate, isOn: $flow.consentConfirmed)
        HStack {
            Button("Cancel") { flow.cancelConsent() }
            Button(confirmation) { flow.confirmConsent() }
                .disabled(!flow.consentConfirmed)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Prepare progress rows

    private func preparingRows(
        operation: LibraryEncryptionOperation,
        progress: EncryptionProgress
    ) -> some View {
        let fraction =
            progress.totalFiles > 0
            ? Double(progress.processedFiles) / Double(progress.totalFiles)
            : nil
        return Group {
            Text(
                operation == .encryption
                    ? "Writing encrypted copy…"
                    : "Writing decrypted copy…"
            )
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Text(
                "\(progress.phase == .transferring ? "Copying" : "Verifying") "
                    + "\(progress.processedFiles) of \(progress.totalFiles) files"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    // MARK: Recovery-code review rows (enable)

    private func recoveryCodeRows(code: RecoveryCode) -> some View {
        Group {
            Label("Save your recovery code", systemImage: "key")
            Text(
                "This code unlocks your library if the Keychain entry is ever "
                    + "lost. It cannot be shown again after activation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(code.displayText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button("Copy") { Self.copyToPasteboard(code.displayText) }
            Toggle(
                "I have saved my recovery code",
                isOn: $flow.recoveryCodeSavedConfirmed
            )
            HStack {
                Button("Discard", role: .destructive) {
                    Task { await flow.discardStaging() }
                }
                Button("Activate Encryption") {
                    Task { await flow.activateStagedCopy() }
                }
                .disabled(!flow.recoveryCodeSavedConfirmed)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Awaiting activation rows (disable)

    private func awaitingActivationRows(
        operation: LibraryEncryptionOperation
    ) -> some View {
        Group {
            Text(
                operation == .decryption
                    ? "A verified plain copy is ready."
                    : "A verified encrypted copy is ready."
            )
            HStack {
                Button("Discard", role: .destructive) {
                    Task { await flow.discardStaging() }
                }
                Button(operation == .decryption ? "Switch to Plain Library" : "Switch to Encrypted Library") {
                    Task { await flow.activateStagedCopy() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Keychain-loss recovery rows (disable)

    private var recoveryKeyRows: some View {
        Group {
            Label("Keychain entry unavailable", systemImage: "lock.slash")
            Text(
                "The library key could not be loaded from the Keychain. Enter "
                    + "your recovery code to unlock the library, then the "
                    + "decryption can be prepared."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField(
                "Recovery code (e.g. ABCD-EFGH-…)",
                text: $flow.recoveryCodeInput
            )
            .onSubmit { Task { await flow.submitRecoveryCode() } }
            if let error = flow.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { flow.cancelConsent() }
                Button("Unlock and Continue") {
                    Task { await flow.submitRecoveryCode() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// State machine driving the encryption enable/disable flow. All decisions
/// live here (mirroring `LibraryLocationForm`) so the flow is testable
/// without driving the form.
@MainActor
@Observable
final class EncryptionFlowModel {
    enum Step: Equatable {
        /// Showing the status row.
        case idle
        /// Double consent before any bytes are touched.
        case confirmingEnable
        case confirmingDisable
        /// A staging run is in flight.
        case preparing(LibraryEncryptionOperation, EncryptionProgress)
        /// Enable: staged copy done, code MUST be acknowledged first.
        case reviewRecoveryCode(RecoveryCode)
        /// Disable: staged copy done, no code involved.
        case awaitingActivation(LibraryEncryptionOperation)
        /// Disable with a lost Keychain entry: ask for the recovery code.
        case recoveringKey
    }

    private(set) var status: EncryptionStatus?
    private(set) var step: Step = .idle
    private(set) var errorMessage: String?

    /// Consent checkboxes; both gate their Activate/Confirm button.
    var consentConfirmed = false
    var recoveryCodeSavedConfirmed = false
    /// User input for `decryptWithRecoveryCode` when the Keychain is lost.
    var recoveryCodeInput = ""

    private var layout: LibraryLayout?
    private var coordinatorRoot: URL?
    private var coordinator: LibraryEncryptionCoordinator?

    /// Test seam: nil uses the default Keychain-backed store.
    private let injectedKeyStore: (any KEKStoring)?

    init(keyStore: (any KEKStoring)? = nil) {
        self.injectedKeyStore = keyStore
    }
    /// Backups present next to the active root, newest-check both directions.
    var existingBackupOperations: [LibraryEncryptionOperation] {
        guard let root = layout?.root else { return [] }
        return [LibraryEncryptionOperation.encryption, .decryption].filter {
            FileManager.default.fileExists(
                atPath: LibraryEncryptionLocation.backupURL(root: root, operation: $0).path
            )
        }
    }

    /// Rebuilds the coordinator when the library moves and re-reads status.
    func refresh(layout: LibraryLayout) async {
        self.layout = layout
        if coordinator == nil || coordinatorRoot != layout.root {
            if let injectedKeyStore {
                coordinator = LibraryEncryptionCoordinator(
                    layout: layout,
                    keyStore: injectedKeyStore
                )
            } else {
                coordinator = LibraryEncryptionCoordinator(layout: layout)
            }
            coordinatorRoot = layout.root
        }
        status = await coordinator?.status()
    }

    func beginEnable() {
        guard status?.isEncrypted == false, step == .idle else { return }
        resetGates()
        step = .confirmingEnable
    }

    func beginDisable() {
        guard status?.isEncrypted == true, step == .idle else { return }
        resetGates()
        step = .confirmingDisable
    }
    func confirmConsent() {
        switch step {
        case .confirmingEnable:
            runPrepare(.encryption)
        case .confirmingDisable:
            runPrepare(.decryption)
        default:
            break
        }
    }

    func cancelConsent() {
        resetGates()
        step = .idle
    }

    /// Acknowledges the saved recovery code and activates the staged copy.
    /// Refuses to run while the "I have saved it" gate is unchecked.
    func activateStagedCopy() async {
        guard let coordinator, step.isReadyForActivation else { return }
        if case .reviewRecoveryCode = step, !recoveryCodeSavedConfirmed {
            return
        }
        do {
            try await coordinator.activateStaged()
            self.resetGates()
            self.step = .idle
        } catch {
            // The old library is still in place; surface and re-read status.
            self.errorMessage = Self.describe(error)
            self.step = .idle
        }
        if let layout {
            await refresh(layout: layout)
        }
    }

    /// Unlocks the KEK with a user-provided recovery code and continues the
    /// disabled-disable flow. Malformed or wrong codes keep the prompt up.
    func submitRecoveryCode() async {
        guard let coordinator, step == .recoveringKey else { return }
        do {
            let code = try RecoveryCode(recoveryCodeInput)
            try await coordinator.decryptWithRecoveryCode(code)
            recoveryCodeInput = ""
            errorMessage = nil
            runPrepare(.decryption)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Clears any staging directory (crash leftover or abandoned run) and
    /// returns to the status row. Never touches the active library or backups.
    func discardStaging() async {
        await coordinator?.cancel()
        resetGates()
        step = .idle
        if let layout {
            await refresh(layout: layout)
        }
    }

    /// Explicit deletion path for a pre-switch backup.
    func deleteBackup(_ operation: LibraryEncryptionOperation) async {
        guard let coordinator else { return }
        do {
            try await coordinator.deleteBackup(operation)
        } catch {
            errorMessage = Self.describe(error)
        }
        if let layout {
            await refresh(layout: layout)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Private

    private func runPrepare(_ operation: LibraryEncryptionOperation) {
        guard let coordinator else { return }
        step = .preparing(
            operation,
            EncryptionProgress(phase: .transferring, processedFiles: 0, totalFiles: 0)
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                // The staging run executes on the coordinator actor; report
                // progress by hopping straight back to the main actor. No
                // intermediate relay whose finish signal could race or be
                // swallowed.
                let reportProgress: @Sendable (EncryptionProgress) -> Void =
                    { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.noteProgress(operation, progress)
                        }
                    }
                let staged: StagedCopy
                switch operation {
                case .encryption:
                    staged = try await coordinator.prepareEncryption(
                        progress: reportProgress
                    )
                case .decryption:
                    staged = try await coordinator.prepareDecryption(
                        progress: reportProgress
                    )
                }
                switch staged.operation {
                case .encryption:
                    guard let code = staged.recoveryCode else {
                        throw LibraryEncryptionError.kekBackupCorrupt
                    }
                    self.resetGates()
                    self.step = .reviewRecoveryCode(code)
                case .decryption:
                    self.resetGates()
                    self.step = .awaitingActivation(.decryption)
                }
            } catch let error as LibraryEncryptionError
                where error == .kekUnavailable && operation == .decryption {
                // Keychain entry lost; offer the recovery-code path instead.
                self.errorMessage = nil
                self.step = .recoveringKey
            } catch {
                // Failure keeps the old library; nothing was switched yet.
                self.errorMessage = Self.describe(error)
                self.step = .idle
            }
            if let layout = self.layout {
                await self.refresh(layout: layout)
            }
        }
    }

    private func noteProgress(
        _ operation: LibraryEncryptionOperation,
        _ progress: EncryptionProgress
    ) {
        if case .preparing(let current, _) = step, current == operation {
            step = .preparing(operation, progress)
        }
    }

    private func resetGates() {
        consentConfirmed = false
        recoveryCodeSavedConfirmed = false
    }

    private static func describe(_ error: Error) -> String {
        "Encryption error: \(error.localizedDescription)"
    }
}

extension EncryptionFlowModel.Step {
    /// Activation is allowed exactly when the recovery code was displayed and
    /// acknowledged (enable) or no code was involved (disable).
    var isReadyForActivation: Bool {
        switch self {
        case .reviewRecoveryCode, .awaitingActivation:
            return true
        case .idle, .confirmingEnable, .confirmingDisable, .preparing,
            .recoveringKey:
            return false
        }
    }
}
