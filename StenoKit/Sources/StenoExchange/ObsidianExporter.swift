import Foundation

/// One meeting prepared for the vault. The caller (app layer) renders the
/// Markdown body — transcript, notes and reports — with its existing
/// export pipeline; this module owns everything vault-specific: frontmatter,
/// stable file naming, collision handling and idempotent writes.
public struct ObsidianVaultDocument: Sendable, Equatable {
    /// Stable identity across title/date changes; recorded in the
    /// frontmatter as `steno-id` so a re-export finds its file even after a
    /// rename instead of writing a duplicate.
    public let meetingID: UUID
    public let title: String
    public let createdAt: Date
    public let status: String
    public let participants: [String]
    public let bodyMarkdown: String

    public init(
        meetingID: UUID,
        title: String,
        createdAt: Date,
        status: String,
        participants: [String],
        bodyMarkdown: String
    ) {
        self.meetingID = meetingID
        self.title = title
        self.createdAt = createdAt
        self.status = status
        self.participants = participants
        self.bodyMarkdown = bodyMarkdown
    }
}

/// Outcome of one vault pass. `isDiffEmpty` is the idempotence contract: a
/// second export without changes must report zero written and zero updated
/// files.
public struct ObsidianSyncSummary: Sendable, Equatable {
    public var written = 0
    public var updated = 0
    public var unchanged = 0
    public var failures: [String] = []

    public init() {}

    public var isDiffEmpty: Bool { written == 0 && updated == 0 }
}

/// Builds and mirrors Obsidian-ready notes into a vault folder.
///
/// Parity with legacy `app/obsidian-sync.js`, adapted to the Swift library:
/// the mirror is one-way (vault edits are never read back into Steno) and
/// non-destructive (nothing in the vault is ever deleted). Unlike the legacy
/// note copy, the vault document keeps the transcript section so the vault
/// holds the complete meeting record — that divergence is deliberate.
public enum ObsidianExporter {
    /// Frontmatter block: title, date, status, participants plus the two
    /// identity lines (`source` for humans, `steno-id` for our own lookup).
    public static func frontmatter(
        for document: ObsidianVaultDocument,
        calendar: Calendar = .current
    ) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlQuoted(document.title))")
        lines.append("date: \(dateString(document.createdAt, calendar: calendar))")
        lines.append("status: \(document.status)")
        if !document.participants.isEmpty {
            lines.append("participants:")
            for participant in document.participants {
                lines.append("  - \(yamlQuoted(participant))")
            }
        }
        lines.append("source: Steno")
        lines.append("steno-id: \(document.meetingID.uuidString)")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// The full vault document: frontmatter, blank line, then exactly the
    /// body the individual Markdown export produces.
    public static func render(
        _ document: ObsidianVaultDocument,
        calendar: Calendar = .current
    ) -> String {
        frontmatter(for: document, calendar: calendar)
            + "\n\n"
            + document.bodyMarkdown
    }

    /// `YYYY-MM-DD Title.md`, mirroring `MeetingMarkdown.fileName(for:)`
    /// character for character so a vault note and a hand export of the same
    /// meeting share a name convention. (MeetingMarkdown lives in
    /// StenoPipeline, which StenoExchange must not depend on — hence the
    /// mirrored implementation, covered by tests on both sides.)
    public static func fileName(
        date: Date,
        title: String,
        calendar: Calendar = .current
    ) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let slug = title
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safe = slug.isEmpty ? "meeting" : String(slug.prefix(80))
        return "\(dateString(date, calendar: calendar)) \(safe).md"
    }

    /// Probes suffixed candidates until one is free. A second collision can
    /// never clobber an earlier note because every candidate is tested
    /// against the caller's `isTaken`.
    public static func collisionFreeName(
        preferred: String,
        isTaken: (String) -> Bool
    ) -> String {
        guard isTaken(preferred) else { return preferred }
        let stem = preferred.dropLast(".md".count)
        var suffix = 2
        while true {
            let candidate = "\(stem) \(suffix).md"
            if !isTaken(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Reads `steno-id:` back out of a vault file's frontmatter. Only the
    /// well-formed UUID form counts — anything else is foreign content and
    /// yields nil rather than a guessed identity.
    public static func stenoMeetingID(ofMarkdown text: String) -> UUID? {
        guard let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("steno-id:") })
        else { return nil }
        let raw = line.dropFirst("steno-id:".count)
            .trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: raw)
    }

    /// Mirrors the documents into the vault. Existing files are located by
    /// their `steno-id`, renamed when title or date changed, overwritten
    /// only when content actually differs, and never deleted.
    @discardableResult
    public static func sync(
        _ documents: [ObsidianVaultDocument],
        into vault: ObsidianVault,
        calendar: Calendar = .current
    ) -> ObsidianSyncSummary {
        var summary = ObsidianSyncSummary()
        var existing = vault.markdownFileNames()
        var taken = Set(existing)

        // Identity index: which meeting already owns which vault file.
        var ownerOf: [UUID: String] = [:]
        for name in existing {
            if let id = vault.contents(fileName: name).flatMap(stenoMeetingID(ofMarkdown:)) {
                ownerOf[id] = name
            }
        }

        for document in documents {
            let desired = fileName(
                date: document.createdAt,
                title: document.title,
                calendar: calendar
            )
            do {
                let existingName = ownerOf[document.meetingID]
                var target = desired
                var moved = false
                if let current = existingName, current != desired {
                    // Title or date moved: keep the same file, move it to
                    // the new name. Probe names taken by *other* notes only.
                    target = collisionFreeName(preferred: desired) { taken.contains($0) }
                    try vault.rename(from: current, to: target)
                    existing.removeAll { $0 == current }
                    moved = true
                } else if existingName == nil {
                    target = collisionFreeName(preferred: desired) { taken.contains($0) }
                }

                let text = render(document, calendar: calendar)
                if !moved, let current = vault.contents(fileName: target), current == text {
                    // Byte-identical: the honest no-op that makes a repeated
                    // sync diff-empty instead of churning mtimes.
                    summary.unchanged += 1
                } else {
                    // A rename with unchanged body counts once, as an update.
                    try vault.write(text, fileName: target)
                    if existingName != nil || moved {
                        summary.updated += 1
                    } else {
                        summary.written += 1
                    }
                }
                taken.insert(target)
                ownerOf[document.meetingID] = target
            } catch {
                summary.failures.append("\(document.title): \(error.localizedDescription)")
            }
        }
        return summary
    }

    /// Always double-quotes and escapes: a title like `Kapitel 2: "Ende"`
    /// must survive YAML round-trips untouched.
    static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func dateString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Approval gate for vault writes.
///
/// The contract is strict: `.granted` is reachable ONLY from `.requested`
/// via an explicit user approval, and `beginExport` hands out permission
/// only in `.granted`. No code path can write to the vault without having
/// passed through the plaintext-warning dialog first — the type makes the
/// bypass unrepresentable rather than trusting callers to remember.
public struct ObsidianExportApprovalGate: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case requested(targetPath: String)
        case granted(targetPath: String)
        case declined(targetPath: String)
        case consumed(targetPath: String)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public var requestedTargetPath: String? {
        switch phase {
        case .requested(let path), .granted(let path),
             .declined(let path), .consumed(let path):
            return path
        case .idle:
            return nil
        }
    }

    /// Opens the gate request for one concrete folder. Any pending state is
    /// replaced: only the newest request can be resolved.
    public mutating func requestExport(into targetPath: String) {
        phase = .requested(targetPath: targetPath)
    }

    /// Resolves the open request. Returns true only when this call granted
    /// it; resolving while nothing is requested is rejected (false) instead
    /// of silently approving a stale dialog.
    @discardableResult
    public mutating func resolveApproval(_ approved: Bool) -> Bool {
        guard case .requested(let path) = phase else { return false }
        phase = approved ? .granted(targetPath: path) : .declined(targetPath: path)
        return approved
    }

    /// Consumes the grant to start exporting. Returns the approved folder
    /// exactly once; a second call gets nil — one dialog, one export run.
    public mutating func beginExport() -> String? {
        guard case .granted(let path) = phase else { return nil }
        phase = .consumed(targetPath: path)
        return path
    }

    public mutating func reset() {
        phase = .idle
    }
}
