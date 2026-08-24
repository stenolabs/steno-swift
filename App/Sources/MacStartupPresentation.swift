import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import SwiftUI

struct MacPipelineStartRequest: Sendable {
    let libraryURL: URL
    let transcriptionProviderResolver: TranscriptionProviderResolver
    let modelCacheDirectory: URL?
    let textModelProviderResolver: TextModelProviderResolver
    let locale: Locale
    let activeMeetingIDs: Set<MeetingID>
}

typealias MacPipelineStarter = @Sendable (
    MacPipelineStartRequest
) async throws -> PipelineRuntime

typealias MacSupportedLocalesLoader = @Sendable () async -> [Locale]
typealias MacMeetingListLoader = @Sendable (Library) async throws -> [Meeting]
typealias MacFolderListLoader = @Sendable (FolderStore) async throws -> [Folder]

enum MacStartupState: Equatable {
    case opening
    case ready
    case failed(MacStartupFailure)
}

enum MacStartupFailure: Equatable {
    case runtimeOpening(String)

    var title: LocalizedStringResource {
        "The library could not be opened"
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .runtimeOpening(let detail):
            "Steno could not finish opening the local library. Try again to use the same local library. \(detail)"
        }
    }

    var compatibilityMessage: String {
        switch self {
        case .runtimeOpening(let detail):
            detail
        }
    }
}

enum MacLibraryIssue: Equatable, Identifiable {
    case meetings(String)
    case folders(String)

    enum ID: Hashable {
        case meetings
        case folders
    }

    var id: ID {
        switch self {
        case .meetings:
            .meetings
        case .folders:
            .folders
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .meetings:
            "Meetings unavailable"
        case .folders:
            "Folders unavailable"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .meetings(let detail):
            "The meeting list could not be loaded. Recording remains available. \(detail)"
        case .folders(let detail):
            "The folder list could not be loaded. Meetings and recording remain available. \(detail)"
        }
    }

    var retryTitle: LocalizedStringResource {
        switch self {
        case .meetings:
            "Reload Meetings"
        case .folders:
            "Reload Folders"
        }
    }

    var compatibilityMessage: String {
        switch self {
        case .meetings(let detail), .folders(let detail):
            detail
        }
    }
}

enum MacStartupWarning: Equatable, Identifiable {
    case pipeline(String)
    case captureRecovery(String)

    enum ID: Hashable {
        case pipeline
        case captureRecovery
    }

    var id: ID {
        switch self {
        case .pipeline:
            .pipeline
        case .captureRecovery:
            .captureRecovery
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .pipeline:
            "Library needs attention"
        case .captureRecovery:
            "Recording recovery needs attention"
        }
    }

    var explanation: String {
        switch self {
        case .pipeline(let detail), .captureRecovery(let detail):
            detail
        }
    }

    var isError: Bool {
        if case .captureRecovery = self { return true }
        return false
    }
}

struct MacStartupOpeningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening library")
                .font(.headline)
            Text("Steno is checking and opening the local library.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(MacWindowPresentation.meetingsTitle)
    }
}

struct MacStartupFailedView: View {
    let failure: MacStartupFailure
    let retry: () async -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.title)
                        .fontWeight(.semibold)
                    Text(failure.explanation)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "externaldrive.badge.xmark")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Steno.Colors.error)

            Button("Try Again") {
                Task { await retry() }
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

struct MacStartupUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Library unavailable",
            systemImage: "externaldrive.badge.xmark"
        )
        .navigationTitle(MacWindowPresentation.meetingsTitle)
    }
}

struct MacLibraryIssueBanner: View {
    let issue: MacLibraryIssue
    let isRetrying: Bool
    let retry: () async -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .fontWeight(.semibold)
                    Text(issue.explanation)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Steno.Colors.error)

            if isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(issue.retryTitle)
            }

            Button(issue.retryTitle) {
                Task { await retry() }
            }
            .buttonStyle(.bordered)
            .disabled(isRetrying)
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct MacStartupWarningBanner: View {
    let warning: MacStartupWarning

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title)
                    .fontWeight(.semibold)
                Text(warning.explanation)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: warning.isError
                ? "exclamationmark.triangle.fill"
                : "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(warning.isError ? Steno.Colors.error : .secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
