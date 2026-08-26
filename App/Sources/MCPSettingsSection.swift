import AppKit
import SwiftUI

/// Settings surface for the local MCP server.
///
/// Mirrors the legacy Integrations-tab contract: the toggle defaults to OFF,
/// plain disclosure copy states exactly what the server exposes, the API key
/// is masked until revealed, ports validate inline without touching the
/// backend, regenerating asks for confirmation, and the client snippet's
/// copy buttons stay disabled while the server is stopped - a one-click copy
/// of a dead endpoint just sends users off to configure a client that cannot
/// connect.
struct MCPSettingsSection: View {
    @Bindable var controller: MCPController

    /// The mask length matches the legacy masked-key row.
    private let maskedKey = String(repeating: "•", count: 32)

    var body: some View {
        Section {
            disclosureCopy

            Toggle("Local MCP server", isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            ))

            statusLine
            portRow
            keyRows
            clientConfigBlock
        } header: {
            Text("MCP")
        }
    }

    // MARK: Disclosure

    private var disclosureCopy: some View {
        Group {
            Text(
                "Listens on localhost (127.0.0.1) only and requires an API key "
                    + "on every request."
            )
            Text(
                "Connected clients can read your notes, transcripts, and folders, "
                    + "and ask questions across them."
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let startError = controller.startError {
            Label(startError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if controller.running {
            Text("The server is running locally on port \(controller.validatedPort ?? 0).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Server is stopped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Port

    private var portRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Port")
                Spacer()
                TextField("27127", text: $controller.portInput)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            if let message = controller.portErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Key management

    @ViewBuilder
    private var keyRows: some View {
        if !controller.hasKey {
            Text("The API key will be created when you enable the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if controller.isCustomKeyEntryActive {
            customKeyRow
        } else {
            keyDisplayRow
        }
    }

    private var keyDisplayRow: some View {
        HStack {
            if controller.isKeyRevealed {
                Text(controller.revealedKey() ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text(maskedKey)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            Spacer()
            Button(controller.isKeyRevealed ? "Hide" : "Reveal") {
                controller.isKeyRevealed.toggle()
            }
            Button("Regenerate…") {
                controller.isRegenerateConfirmPresented = true
            }
            Button("Paste Custom Key…") {
                controller.isCustomKeyEntryActive = true
            }
        }
        .alert(
            "Regenerate MCP API key?",
            isPresented: $controller.isRegenerateConfirmPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                controller.regenerateKey()
            }
        } message: {
            Text(
                "This will disconnect any active MCP clients until they are "
                    + "updated with the new key."
            )
        }
    }

    private var customKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Paste your own API key", text: $controller.customKeyDraft)
            HStack {
                Spacer()
                Button("Save") {
                    _ = controller.saveCustomKey()
                }
                .disabled(controller.customKeyDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    controller.cancelCustomKey()
                }
            }
        }
    }

    // MARK: Client snippet

    private var clientConfigBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Client configuration")
                .font(.caption.weight(.semibold))

            HStack {
                Text(controller.endpointURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy URL") {
                    copy(controller.endpointURL)
                }
                .disabled(!controller.running)
            }

            Text(controller.clientSnippet)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Copy Configuration") {
                    copy(controller.clientSnippet)
                }
                .disabled(!controller.running)
            }

            if !controller.running {
                Text("Server is stopped - start it before copying the configuration.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
