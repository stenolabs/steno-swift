import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary

struct PreparedLegacyMeeting {
    let bundle: PreparedMeetingImport
    let diarizationRunID: RunID?
    let clusterCount: Int
    let warnings: [String]
}

func prepareLegacyMeeting(
    entry: LegacyStemEntry,
    folderNames: [String: String],
    customTemplateNames: [String: String],
    timestampParser: LegacyTimestampParser,
    audioWorkspaceDirectory: URL
) async throws -> PreparedLegacyMeeting {
    guard let summarySource = entry.summary, let transcriptURL = entry.transcript else {
        throw LegacyExchangeError.invalidFormat("Incomplete legacy stem \(entry.stem)")
    }
    let summary = try ImportedLegacySummary.read(
        summarySource,
        timestampParser: timestampParser
    )
    let transcript = try LegacyTranscriptFile.read(
        from: transcriptURL,
        timestampParser: timestampParser
    )
    let meetingID = MeetingID()
    let provenanceKey = "legacy:\(entry.stem)"
    var warnings: [String] = []
    let createdAt: Date
    if let recordedAt = timestampParser.recordingStartedAt(stem: entry.stem) {
        createdAt = recordedAt
    } else if let summaryDate = summary.date {
        createdAt = summaryDate
    } else {
        createdAt = Date(timeIntervalSince1970: 0)
        warnings.append("Stem \(entry.stem) has no usable legacy date")
    }
    let legacyFolders = summary.folderIDs.map { folderID in
        if let name = folderNames[folderID] { return name }
        warnings.append("Stem \(entry.stem) references unknown folder \(folderID)")
        return folderID
    }
    let meeting = Meeting(
        id: meetingID,
        title: summary.title.isEmpty ? entry.stem : summary.title,
        createdAt: createdAt,
        status: .ready,
        metadata: MeetingMetadata(
            legacyProvenanceKey: provenanceKey,
            legacyFolders: legacyFolders
        )
    )

    let speakers = try entry.speakers.map(LegacySpeakersFile.read(from:))
    let diarization = try speakers.map {
        try makeDiarizationImport(file: $0, meetingID: meetingID)
    }
    let turns = try makeTranscriptTurns(
        transcript.body,
        duration: summary.durationSeconds,
        speakers: speakers,
        runID: diarization?.run.id
    )
    let revision = TranscriptRevision(
        meetingID: meetingID,
        createdAt: createdAt,
        origin: .legacyImport,
        turns: turns
    )

    var media: [PreparedMediaImport] = []
    for sourceURL in entry.recordings {
        let assetID = MediaAssetID()
        do {
            let preparedAudio = try await prepareLegacyAudio(
                sourceURL: sourceURL,
                assetID: assetID,
                workspaceDirectory: audioWorkspaceDirectory
            )
            media.append(PreparedMediaImport(
                asset: MediaAsset(
                    id: assetID,
                    meetingID: meetingID,
                    kind: .imported,
                    sampleRate: preparedAudio.sampleRate,
                    duration: summary.durationSeconds ?? 0,
                    provenanceKey: legacyMediaProvenance(
                        entry: entry,
                        sourceURL: sourceURL
                    ),
                    fileName: "\(assetID).\(preparedAudio.fileExtension)",
                    conversion: preparedAudio.conversion
                ),
                sourceURL: preparedAudio.sourceURL
            ))
        } catch {
            warnings.append(
                "Stem \(entry.stem) audio \(sourceURL.lastPathComponent) "
                    + "could not be converted: \(error)"
            )
        }
    }

    let overrides = try entry.overrides.map {
        try LegacyOverrides.read(from: $0, timestampParser: timestampParser)
    }
    let reports = try entry.reports.map {
        try LegacyReportsFile.read(from: $0, timestampParser: timestampParser)
    } ?? LegacyReportsFile(reports: [], activeReport: nil)
    let templateResults = makeTemplateResults(
        summary: summary,
        overrides: overrides,
        reports: reports,
        customTemplateNames: customTemplateNames,
        revisionID: revision.id,
        fallbackDate: createdAt
    )
    let notes: [PreparedMeetingNoteImport]
    if let userNotes = summary.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
       !userNotes.isEmpty {
        notes = [PreparedMeetingNoteImport(
            fileName: "legacy-user-notes.md",
            data: Data(userNotes.utf8)
        )]
    } else {
        notes = []
    }

    return PreparedLegacyMeeting(
        bundle: PreparedMeetingImport(
            meeting: meeting,
            media: media,
            revision: revision,
            runs: diarization.map { [$0.preparedRun] } ?? [],
            templateResults: templateResults,
            notes: notes,
            reviewData: diarization?.reviewData
        ),
        diarizationRunID: diarization?.run.id,
        clusterCount: diarization?.clusters.count ?? 0,
        warnings: warnings
    )
}

private struct PreparedLegacyDiarization {
    let run: ProcessingRun
    let clusters: [IdentityCluster]
    let preparedRun: PreparedRunImport
    let reviewData: Data
}

private func makeDiarizationImport(
    file: LegacySpeakersFile,
    meetingID: MeetingID
) throws -> PreparedLegacyDiarization {
    let runID = RunID()
    let engine = EngineDescriptor(name: "legacy-stenoai", version: "1")
    let run = ProcessingRun(
        id: runID,
        meetingID: meetingID,
        kind: .diarization,
        engine: engine,
        status: .finished,
        createdAt: file.createdAt,
        startedAt: file.createdAt,
        finishedAt: file.createdAt
    )
    let clusters = file.channels.sorted { $0.key < $1.key }.flatMap { channel, value in
        value.clusters.sorted { $0.key < $1.key }.map { speakerID, cluster in
            IdentityCluster(
                meetingID: meetingID,
                runID: runID,
                channel: channel,
                clusterID: "\(channel)/\(speakerID)",
                recordingType: value.recordingType,
                embedding: cluster.embedding,
                speechDurationSeconds: cluster.speechDurationSeconds,
                segmentCount: cluster.segmentCount,
                containsMultipleSpeakers: cluster.containsMultipleSpeakers,
                reviewState: legacyReviewState(cluster.reviewState),
                isSelf: false
            )
        }
    }
    let segmentsByClusterID = Dictionary(uniqueKeysWithValues:
        file.channels.flatMap { channel, value in
            value.clusters.map { speakerID, cluster in
                ("\(channel)/\(speakerID)", cluster.segments)
            }
        }
    )
    let artifactData = try encoded(LegacyDiarizationArtifact(
        clusters: clusters,
        segmentsByClusterID: segmentsByClusterID
    ))
    return PreparedLegacyDiarization(
        run: run,
        clusters: clusters,
        preparedRun: PreparedRunImport(
            run: run,
            artifactFileName: "diarization.json",
            artifactData: artifactData
        ),
        reviewData: try encoded(LegacyReviewDocument(runID: runID, clusters: clusters))
    )
}

private func legacyReviewState(_ value: String?) -> IdentityCluster.ReviewState {
    switch value {
    case "generic": .generic
    case "multiple": .multiple
    default: .unreviewed
    }
}

private func makeTranscriptTurns(
    _ body: LegacyTranscriptBody,
    duration: TimeInterval?,
    speakers: LegacySpeakersFile?,
    runID: RunID?
) throws -> [TranscriptTurn] {
    switch body {
    case .diarized(let legacyTurns):
        let lines: [LegacyTranscriptLine]?
        if speakers?.transcriptLines != nil {
            lines = try speakers?.pairTranscriptLines(with: legacyTurns).map(\.line)
        } else {
            lines = nil
        }
        return legacyTurns.enumerated().map { index, turn in
            let end: TimeInterval
            if legacyTurns.indices.contains(index + 1) {
                end = max(turn.start, legacyTurns[index + 1].start)
            } else {
                let estimated = turn.start + estimatedSpeechDuration(turn.text)
                end = max(turn.start, duration.map { min($0, estimated) } ?? estimated)
            }
            let speaker: SpeakerReference
            if let line = lines?[index],
               let speakerID = line.diarizationSpeakerID,
               let runID {
                speaker = .cluster(
                    runID: runID,
                    clusterID: "\(line.channel)/\(speakerID)"
                )
            } else if let line = lines?[index], !line.originalLabel.isEmpty {
                speaker = .channel(line.originalLabel)
            } else {
                speaker = .channel(turn.speaker)
            }
            return transcriptTurn(
                text: turn.text,
                start: turn.start,
                end: end,
                speaker: speaker
            )
        }
    case .plain(let paragraphs):
        var cursor: TimeInterval = 0
        return paragraphs.map { paragraph in
            let estimatedEnd = cursor + estimatedSpeechDuration(paragraph)
            let end = max(cursor, duration.map { min($0, estimatedEnd) } ?? estimatedEnd)
            defer { cursor = end }
            return transcriptTurn(text: paragraph, start: cursor, end: end, speaker: nil)
        }
    }
}

private func estimatedSpeechDuration(_ text: String) -> TimeInterval {
    let wordCount = text.split(whereSeparator: \.isWhitespace).count
    return max(1, Double(wordCount) / 2.5)
}

private func transcriptTurn(
    text: String,
    start: TimeInterval,
    end: TimeInterval,
    speaker: SpeakerReference?
) -> TranscriptTurn {
    TranscriptTurn(
        speaker: speaker,
        start: start,
        end: end,
        segments: [TranscriptSegment(text: text, start: start, end: end, words: [])]
    )
}

private enum ImportedLegacySummary {
    case markdown(LegacySummaryFile)
    case json(LegacySummaryJSON)

    static func read(
        _ source: LegacySummarySource,
        timestampParser: LegacyTimestampParser
    ) throws -> Self {
        switch source.kind {
        case .markdown:
            .markdown(try LegacySummaryFile.read(
                from: source.url,
                timestampParser: timestampParser
            ))
        case .json:
            .json(try LegacySummaryJSON.read(
                from: source.url,
                timestampParser: timestampParser
            ))
        }
    }

    var title: String {
        switch self {
        case .markdown(let file): file.title ?? ""
        case .json(let file): file.sessionInfo.name
        }
    }

    var date: Date? {
        switch self {
        case .markdown(let file): file.date
        case .json(let file): file.sessionInfo.processedAt
        }
    }

    var durationSeconds: TimeInterval? {
        switch self {
        case .markdown(let file): file.durationSeconds.map(TimeInterval.init)
        case .json(let file): file.sessionInfo.durationSeconds
        }
    }

    var folderIDs: [String] {
        switch self {
        case .markdown(let file): file.folders
        case .json(let file): file.folders
        }
    }

    var userNotes: String? {
        switch self {
        case .markdown(let file): file.body.userNotes
        case .json(let file): file.userNotes
        }
    }

    var standardValues: [String: LegacyJSONValue] {
        switch self {
        case .markdown(let file):
            [
                "summary": .string(file.body.summary ?? ""),
                "key_topics": .array(file.body.keyTopics.map {
                    .object(["title": .string($0.title), "body": .string($0.body)])
                }),
                "key_points": .array(file.body.keyPoints.map(LegacyJSONValue.string)),
                "action_items": .array(file.body.actionItems.map(LegacyJSONValue.string)),
            ]
        case .json(let file):
            [
                "summary": .string(file.summary),
                "key_topics": .array(file.discussionAreas.map {
                    .object(["title": .string($0.title), "body": .string($0.analysis)])
                }),
                "key_points": .array(file.keyPoints.map(LegacyJSONValue.string)),
                "action_items": .array(file.actionItems.map(LegacyJSONValue.string)),
            ]
        }
    }

    var resultDate: Date? {
        switch self {
        case .markdown(let file):
            file.summaryGeneratedAt ?? file.updatedAt ?? file.date
        case .json(let file):
            file.sessionInfo.updatedAt ?? file.sessionInfo.processedAt
        }
    }
}

private func makeTemplateResults(
    summary: ImportedLegacySummary,
    overrides: LegacyOverrides?,
    reports: LegacyReportsFile,
    customTemplateNames: [String: String],
    revisionID: RevisionID,
    fallbackDate: Date
) -> [PreparedTemplateResultImport] {
    var values = summary.standardValues
    for (key, override) in overrides?.fields ?? [:] {
        let normalized = key == "discussion_areas" ? "key_topics" : key
        if values[normalized] != nil {
            values[normalized] = override.value
        }
    }
    let model = reports.reports.first?.model
    var results = [PreparedTemplateResultImport(
        runID: RunID(),
        result: TemplateResult(
            markdown: renderStandardNote(values),
            template: legacyTemplate(id: "standard", name: "Standard Note"),
            engine: legacyEngine(modelVersion: model),
            revisionID: revisionID,
            createdAt: summary.resultDate ?? fallbackDate
        )
    )]
    results.append(contentsOf: reports.reports.map { report in
        PreparedTemplateResultImport(
            runID: RunID(),
            result: TemplateResult(
                markdown: report.content,
                template: legacyTemplate(
                    id: report.templateID,
                    name: resolvedTemplateName(
                        report,
                        customTemplateNames: customTemplateNames
                    )
                ),
                engine: legacyEngine(modelVersion: report.model),
                revisionID: revisionID,
                createdAt: report.createdAt ?? fallbackDate
            )
        )
    })
    return results
}

private func legacyEngine(modelVersion: String?) -> EngineDescriptor {
    EngineDescriptor(
        name: "legacy-stenoai",
        version: "1",
        modelVersion: modelVersion?.isEmpty == false ? modelVersion : nil
    )
}

private func legacyTemplate(id: String, name: String) -> Template {
    Template(
        id: id,
        name: name,
        description: "Imported from legacy Steno",
        sections: [TemplateSection(id: "legacy-content", title: name, prompt: "")],
        prompts: TemplatePromptComponents(role: "", mapInstructions: "", reduceInstructions: "")
    )
}

private func resolvedTemplateName(
    _ report: LegacyReport,
    customTemplateNames: [String: String]
) -> String {
    if !report.templateName.isEmpty { return report.templateName }
    if let customName = customTemplateNames[report.templateID], !customName.isEmpty {
        return customName
    }
    let builtIns = [
        "standard": "Standard Note",
        "product-demo": "Product Demo",
        "sales-call": "Sales Call",
        "one-on-one": "One-on-One",
        "standup": "Standup",
        "shareable-summary": "Shareable Summary",
        "standard-backup": "Previous version",
    ]
    return builtIns[report.templateID] ?? report.templateID
}

private func renderStandardNote(_ values: [String: LegacyJSONValue]) -> String {
    let summary = renderScalar(values["summary"])
    let topics = renderTopics(values["key_topics"])
    let keyPoints = renderBullets(values["key_points"])
    let actionItems = renderBullets(values["action_items"])
    return [
        "## Summary\n\(summary)",
        "## Key Topics\n\(topics)",
        "## Key Points\n\(keyPoints)",
        "## Action Items\n\(actionItems)",
    ].joined(separator: "\n\n")
}

private func renderScalar(_ value: LegacyJSONValue?) -> String {
    guard let value else { return "" }
    return switch value {
    case .string(let string): string
    case .number(let number): String(number)
    case .bool(let bool): String(bool)
    case .array(let values): values.map { renderScalar($0) }.joined(separator: "\n")
    case .object(let object): object.sorted { $0.key < $1.key }
        .map { "\($0.key): \(renderScalar($0.value))" }.joined(separator: "\n")
    case .null: ""
    }
}

private func renderTopics(_ value: LegacyJSONValue?) -> String {
    guard case let .array(values) = value else { return renderScalar(value) }
    return values.map { item in
        guard case let .object(object) = item else { return renderScalar(item) }
        let title = renderScalar(object["title"])
        let body = renderScalar(object["body"] ?? object["analysis"])
        return title.isEmpty ? body : "### \(title)\n\(body)"
    }.joined(separator: "\n\n")
}

private func renderBullets(_ value: LegacyJSONValue?) -> String {
    guard case let .array(values) = value else { return renderScalar(value) }
    return values.map { "- \(renderScalar($0))" }.joined(separator: "\n")
}

private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
