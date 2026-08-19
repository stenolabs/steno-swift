import Foundation

public struct LegacySummarySource: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case markdown
        case json
    }

    public let kind: Kind
    public let url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

public struct LegacyStemEntry: Equatable, Sendable {
    public let stem: String
    public let recordings: [URL]
    public let transcript: URL?
    public let summary: LegacySummarySource?
    public let shadowedSummaryJSON: URL?
    public let reports: URL?
    public let speakers: URL?
    public let original: URL?
    public let overrides: URL?

    public init(
        stem: String,
        recordings: [URL],
        transcript: URL?,
        summary: LegacySummarySource?,
        shadowedSummaryJSON: URL?,
        reports: URL?,
        speakers: URL?,
        original: URL?,
        overrides: URL?
    ) {
        self.stem = stem
        self.recordings = recordings
        self.transcript = transcript
        self.summary = summary
        self.shadowedSummaryJSON = shadowedSummaryJSON
        self.reports = reports
        self.speakers = speakers
        self.original = original
        self.overrides = overrides
    }
}

public struct LegacyOrphan: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case recordingWithoutSidecars
        case transcriptWithoutSummary
        case summaryWithoutTranscript
    }

    public let stem: String
    public let kind: Kind

    public init(stem: String, kind: Kind) {
        self.stem = stem
        self.kind = kind
    }
}

public struct LegacyStoreSnapshot: Equatable, Sendable {
    public let entries: [LegacyStemEntry]
    public let orphans: [LegacyOrphan]
    public let pendingDeleteFiles: [URL]

    public init(
        entries: [LegacyStemEntry],
        orphans: [LegacyOrphan],
        pendingDeleteFiles: [URL]
    ) {
        self.entries = entries
        self.orphans = orphans
        self.pendingDeleteFiles = pendingDeleteFiles
    }
}

public struct LegacyStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func scan() throws -> LegacyStoreSnapshot {
        let recordings = try regularFiles(in: rootURL.appending(path: "recordings"))
        let transcripts = try regularFiles(in: rootURL.appending(path: "transcripts"))
        let outputURL = rootURL.appending(path: "output")
        let output = try regularFiles(in: outputURL)

        var builders: [String: StemBuilder] = [:]
        for url in recordings {
            let stem = url.deletingPathExtension().lastPathComponent
            builders[stem, default: StemBuilder()].recordings.append(url)
        }
        for url in transcripts where url.lastPathComponent.hasSuffix("_transcript.txt") {
            let stem = String(url.lastPathComponent.dropLast("_transcript.txt".count))
            builders[stem, default: StemBuilder()].transcript = url
        }
        for url in output {
            addOutput(url, to: &builders)
        }

        let entries = builders.map { stem, builder in
            let summary: LegacySummarySource?
            if let markdown = builder.summaryMarkdown {
                summary = LegacySummarySource(kind: .markdown, url: markdown)
            } else if let json = builder.summaryJSON {
                summary = LegacySummarySource(kind: .json, url: json)
            } else {
                summary = nil
            }
            return LegacyStemEntry(
                stem: stem,
                recordings: builder.recordings.sorted { $0.lastPathComponent < $1.lastPathComponent },
                transcript: builder.transcript,
                summary: summary,
                shadowedSummaryJSON: builder.summaryMarkdown == nil ? nil : builder.summaryJSON,
                reports: builder.reports,
                speakers: builder.speakers,
                original: builder.original,
                overrides: builder.overrides
            )
        }.sorted { $0.stem < $1.stem }

        var orphans: [LegacyOrphan] = []
        for entry in entries {
            if !entry.recordings.isEmpty, entry.transcript == nil, entry.summary == nil {
                orphans.append(LegacyOrphan(stem: entry.stem, kind: .recordingWithoutSidecars))
            }
            if entry.transcript != nil, entry.summary == nil {
                orphans.append(LegacyOrphan(stem: entry.stem, kind: .transcriptWithoutSummary))
            }
            if entry.summary != nil, entry.transcript == nil {
                orphans.append(LegacyOrphan(stem: entry.stem, kind: .summaryWithoutTranscript))
            }
        }
        orphans.sort {
            ($0.stem, $0.kind.rawValue) < ($1.stem, $1.kind.rawValue)
        }

        return LegacyStoreSnapshot(
            entries: entries,
            orphans: orphans,
            pendingDeleteFiles: try recursiveRegularFiles(
                in: outputURL.appending(path: ".pending-delete")
            )
        )
    }
}

private struct StemBuilder {
    var recordings: [URL] = []
    var transcript: URL?
    var summaryMarkdown: URL?
    var summaryJSON: URL?
    var reports: URL?
    var speakers: URL?
    var original: URL?
    var overrides: URL?
}

private func addOutput(_ url: URL, to builders: inout [String: StemBuilder]) {
    let name = url.lastPathComponent
    let suffixes: [(String, WritableKeyPath<StemBuilder, URL?>)] = [
        ("_summary.md", \.summaryMarkdown),
        ("_summary.json", \.summaryJSON),
        ("_reports.json", \.reports),
        ("_speakers.json", \.speakers),
        ("_original.json", \.original),
        ("_overrides.json", \.overrides),
    ]
    guard let (suffix, keyPath) = suffixes.first(where: { name.hasSuffix($0.0) }) else {
        return
    }
    let stem = String(name.dropLast(suffix.count))
    var builder = builders[stem, default: StemBuilder()]
    builder[keyPath: keyPath] = url
    builders[stem] = builder
}

private func regularFiles(in directory: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        return []
    }
    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ).filter { url in
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func recursiveRegularFiles(in directory: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        return []
    }
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator where
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}
