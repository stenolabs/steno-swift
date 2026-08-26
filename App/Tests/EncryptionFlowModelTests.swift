import Foundation
import Testing
import StenoLibrary
@testable import steno_macos

/// Hermetic KEK store so the flow can be driven without touching the login
/// Keychain (mirrors the core suite's in-memory store).
final class FlowInMemoryKEKStore: KEKStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func storeKEK(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func loadKEK() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func deleteKEK() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}

@Suite("Encryption settings flow")
@MainActor
struct EncryptionSettingsFlowTests {
    private func makeLayout() throws -> LibraryLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: root.appendingPathComponent("library.json")
        )
        return LibraryLayout(root: root)
    }

    /// Polls until the predicate holds; the flow drives its staging run on an
    /// unstructured task, so tests wait for step transitions.
    private func waitFor(
        _ predicate: @autoclosure () -> Bool,
        timeout seconds: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() >= deadline {
                Issue.record("Timed out waiting for flow condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Drives enable up to the recovery-code review; returns the code that
    /// was displayed to the user.
    private func enableLibrary(
        _ flow: EncryptionFlowModel,
        layout: LibraryLayout
    ) async throws -> RecoveryCode {
        await flow.refresh(layout: layout)
        #expect(flow.status?.isEncrypted == false)
        flow.beginEnable()
        flow.consentConfirmed = true
        flow.confirmConsent()
        var code: RecoveryCode?
        try await waitFor({
            if case .reviewRecoveryCode(let stagedCode) = flow.step {
                code = stagedCode
                return true
            }
            return false
        }())
        guard let code else {
            Issue.record("Enable never reached recovery-code review: \(flow.step)")
            Issue.record("\(flow.errorMessage ?? "")")
            throw TestFailure.missingCode
        }
        return code
    }

    private enum TestFailure: Error {
        case missingCode
    }

    @Test("enable flow gates activation on the saved-code acknowledgement")
    func enableFlowHappyPath() async throws {
        let layout = try makeLayout()
        let flow = EncryptionFlowModel(keyStore: FlowInMemoryKEKStore())

        let code = try await enableLibrary(flow, layout: layout)

        // The save-gate blocks activation: status must stay plain.
        #expect(flow.recoveryCodeSavedConfirmed == false)
        await flow.activateStagedCopy()
        #expect(flow.status?.isEncrypted == false)

        // Acknowledging the gate activates and leaves a deletable backup.
        flow.recoveryCodeSavedConfirmed = true
        await flow.activateStagedCopy()
        try await waitFor(flow.status?.isEncrypted == true)
        #expect(flow.status?.backupExists == true)
        #expect(code.normalized.count == 32)
        await flow.deleteBackup(.encryption)
        try await waitFor(flow.status?.backupExists == false)

        // Clean up the temp library.
        try? FileManager.default.removeItem(at: layout.root)
    }

    @Test("disable flow recovers a lost Keychain entry via the code field")
    func disableFlowWithKeychainLoss() async throws {
        let layout = try makeLayout()
        let enablingStore = FlowInMemoryKEKStore()
        let enabler = EncryptionFlowModel(keyStore: enablingStore)
        let code = try await enableLibrary(enabler, layout: layout)

        // Finish the enable flow: acknowledge the code and activate.
        enabler.recoveryCodeSavedConfirmed = true
        await enabler.activateStagedCopy()
        try await waitFor(enabler.status?.isEncrypted == true)

        // A fresh session whose Keychain entry is empty.
        let flow = EncryptionFlowModel(keyStore: FlowInMemoryKEKStore())
        await flow.refresh(layout: layout)
        #expect(flow.status?.isEncrypted == true)

        flow.beginDisable()
        flow.consentConfirmed = true
        flow.confirmConsent()

        // kekUnavailable routes to the recovery prompt instead of failing.
        try await waitFor({
            if case .recoveringKey = flow.step { return true }
            return false
        }())
        // A well-formed but wrong code keeps the prompt up with an error.
        let wrong = RecoveryCode.generate().displayText
        flow.recoveryCodeInput = wrong
        await flow.submitRecoveryCode()
        #expect({
            if case .recoveringKey = flow.step { return true }
            return false
        }())
        #expect(flow.errorMessage != nil)

        // The real code unlocks the KEK and continues into staging.
        flow.recoveryCodeInput = code.displayText
        await flow.submitRecoveryCode()
        try await waitFor({
            if case .awaitingActivation(.decryption) = flow.step {
                return true
            }
            return false
        }())

        await flow.activateStagedCopy()
        try await waitFor(flow.status?.isEncrypted == false)
        #expect(flow.status?.backupExists == true)

        try? FileManager.default.removeItem(at: layout.root)
        try? FileManager.default.removeItem(
            at: layout.root.appendingPathExtension("encrypted.bak")
        )
    }

    @Test("discarding a staged copy clears it without touching the library")
    func discardStagedCopy() async throws {
        let layout = try makeLayout()
        let flow = EncryptionFlowModel(keyStore: FlowInMemoryKEKStore())
        _ = try await enableLibrary(flow, layout: layout)

        await flow.discardStaging()
        try await waitFor(flow.step == .idle)
        #expect(flow.status?.isEncrypted == false)
        #expect(flow.status?.pendingOperation == nil)
        #expect(flow.status?.backupExists == false)
        #expect(
            !FileManager.default.fileExists(
                atPath: layout.root.appendingPathExtension("encryption-staging").path
            )
        )

        try? FileManager.default.removeItem(at: layout.root)
    }
}
