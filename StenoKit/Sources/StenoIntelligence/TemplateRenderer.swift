import Foundation
import StenoDomain

public struct TemplateRenderingConfiguration: Equatable, Sendable {
    public let targetInputWordCount: Int
    public let maximumReductionDepth: Int

    public init(
        targetInputWordCount: Int = 1_200,
        maximumReductionDepth: Int = 16
    ) {
        self.targetInputWordCount = targetInputWordCount
        self.maximumReductionDepth = maximumReductionDepth
    }
}

public enum TemplateRendererError: Error, Equatable, Sendable {
    case invalidConfiguration
    case turnExceedsTargetWordCount(actual: Int, limit: Int)
    case invalidStructuredOutput
    case reductionDidNotConverge
}

public struct TemplateRenderer: Sendable {
    private let provider: any StructuredTextModelProvider
    private let configuration: TemplateRenderingConfiguration

    public init(
        provider: any StructuredTextModelProvider,
        configuration: TemplateRenderingConfiguration = TemplateRenderingConfiguration()
    ) {
        self.provider = provider
        self.configuration = configuration
    }

    /// `participants` ist die verbindliche, bereits kuratierte Liste für
    /// datenbasierte Sektionen (z. B. vom Coordinator aus dem Review-Stand
    /// gebaut: nach Beitragsmenge sortiert, ohne Kanal-Labels und ohne als
    /// generisch markierte Cluster). Ohne Liste wird sie ersatzweise aus
    /// den Sprechern der Revision abgeleitet.
    public func render(
        template: Template,
        transcript: TranscriptRevision,
        resolvingSpeakerName resolver: SpeakerNameResolver = { _ in nil },
        participants: [String]? = nil,
        context: RenderContext = .empty
    ) async throws -> TemplateResult {
        guard configuration.targetInputWordCount > 0,
              configuration.maximumReductionDepth > 0
        else {
            throw TemplateRendererError.invalidConfiguration
        }

        let participantNames = participants ?? participantNames(
            transcript: transcript,
            resolver: resolver
        )
        // Der Kontext traegt die Teilnehmer mit, damit das Modell Namen und
        // Firmen so schreibt, wie sie in der Teilnehmersektion stehen.
        let context = RenderContext(
            userNotes: context.userNotes,
            participants: context.participants.isEmpty
                ? participantNames
                : context.participants
        )
        let chunks = try makeChunks(transcript: transcript, resolver: resolver)
        var mapped: [StructuredTemplateOutput] = []
        mapped.reserveCapacity(chunks.count)

        for chunk in chunks {
            mapped.append(
                try await generate(
                    template: template,
                    request: .map(chunk),
                    context: context
                )
            )
        }

        let fittedOutputs = try await reduceToFit(
            mapped,
            template: template,
            depth: 0,
            context: context
        )
        let output = try await generate(
            template: template,
            request: .reduce(fittedOutputs),
            context: context
        )
        return TemplateResult(
            markdown: markdown(
                for: output,
                template: template,
                participantNames: participantNames
            ),
            template: template,
            engine: provider.descriptor,
            revisionID: transcript.id
        )
    }

    /// Verbindliche Teilnehmerliste aus den Sprechern der Revision, in
    /// Reihenfolge des ersten Auftretens. Wird deterministisch gerendert,
    /// damit das Modell keine Namen erfinden oder verstümmeln kann.
    private func participantNames(
        transcript: TranscriptRevision,
        resolver: SpeakerNameResolver
    ) -> [String] {
        var unresolvedSpeakers: [SpeakerReference] = []
        var names: [String] = []
        for turn in transcript.turns {
            let name = speakerName(
                for: turn.speaker,
                resolver: resolver,
                unresolvedSpeakers: &unresolvedSpeakers
            )
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private func makeChunks(
        transcript: TranscriptRevision,
        resolver: SpeakerNameResolver
    ) throws -> [TranscriptChunk] {
        var unresolvedSpeakers: [SpeakerReference] = []
        let turns = transcript.turns.map { turn in
            TranscriptChunkTurn(
                speakerName: speakerName(
                    for: turn.speaker,
                    resolver: resolver,
                    unresolvedSpeakers: &unresolvedSpeakers
                ),
                start: turn.start,
                end: turn.end,
                text: turn.segments.map(\.text).joined(separator: " ")
            )
        }

        guard !turns.isEmpty else {
            return [TranscriptChunk(turns: [])]
        }

        var chunks: [TranscriptChunk] = []
        var currentTurns: [TranscriptChunkTurn] = []
        var currentWordCount = 0

        for turn in turns {
            let turnWordCount = max(1, wordCount(turn.text))
            guard turnWordCount <= configuration.targetInputWordCount else {
                throw TemplateRendererError.turnExceedsTargetWordCount(
                    actual: turnWordCount,
                    limit: configuration.targetInputWordCount
                )
            }
            if !currentTurns.isEmpty,
               currentWordCount + turnWordCount > configuration.targetInputWordCount
            {
                chunks.append(TranscriptChunk(turns: currentTurns))
                currentTurns = []
                currentWordCount = 0
            }
            currentTurns.append(turn)
            currentWordCount += turnWordCount
        }

        if !currentTurns.isEmpty {
            chunks.append(TranscriptChunk(turns: currentTurns))
        }
        return chunks
    }

    private func speakerName(
        for speaker: SpeakerReference?,
        resolver: SpeakerNameResolver,
        unresolvedSpeakers: inout [SpeakerReference]
    ) -> String {
        guard let speaker else {
            return "Unknown speaker"
        }
        if case .importedTextLabel(let imported) = speaker {
            if imported.wasConfirmedAtSource, !imported.text.isEmpty {
                return imported.text
            }
            if let index = unresolvedSpeakers.firstIndex(of: speaker) {
                return "Speaker \(index + 1)"
            }
            unresolvedSpeakers.append(speaker)
            return "Speaker \(unresolvedSpeakers.count)"
        }
        if let resolved = resolver(speaker), !resolved.isEmpty {
            return resolved
        }
        if case .channel(let label) = speaker, !label.isEmpty {
            return label
        }
        if let index = unresolvedSpeakers.firstIndex(of: speaker) {
            return "Speaker \(index + 1)"
        }
        unresolvedSpeakers.append(speaker)
        return "Speaker \(unresolvedSpeakers.count)"
    }

    private func reduceToFit(
        _ outputs: [StructuredTemplateOutput],
        template: Template,
        depth: Int,
        context: RenderContext
    ) async throws -> [StructuredTemplateOutput] {
        guard depth < configuration.maximumReductionDepth else {
            throw TemplateRendererError.reductionDidNotConverge
        }
        let previousWordCount = outputs.reduce(into: 0) { count, output in
            count += outputWordCount(output)
        }
        if previousWordCount <= configuration.targetInputWordCount {
            return outputs
        }

        let batches = reductionBatches(outputs)
        var next: [StructuredTemplateOutput] = []
        next.reserveCapacity(batches.count)
        let singletonCarryLimit = configuration.targetInputWordCount / 2
        for batch in batches {
            if batch.count == 1,
               let output = batch.first,
               outputWordCount(output) <= singletonCarryLimit
            {
                next.append(output)
            } else {
                next.append(
                    try await generate(
                        template: template,
                        request: .reduce(batch),
                        context: context
                    )
                )
            }
        }

        let nextWordCount = next.reduce(into: 0) { count, output in
            count += outputWordCount(output)
        }
        guard next.count < outputs.count || nextWordCount < previousWordCount else {
            throw TemplateRendererError.reductionDidNotConverge
        }
        return try await reduceToFit(
            next,
            template: template,
            depth: depth + 1,
            context: context
        )
    }

    private func reductionBatches(
        _ outputs: [StructuredTemplateOutput]
    ) -> [[StructuredTemplateOutput]] {
        var batches: [[StructuredTemplateOutput]] = []
        var current: [StructuredTemplateOutput] = []
        var currentWordCount = 0

        for output in outputs {
            let count = max(1, outputWordCount(output))
            if !current.isEmpty,
               currentWordCount + count > configuration.targetInputWordCount
            {
                batches.append(current)
                current = []
                currentWordCount = 0
            }
            current.append(output)
            currentWordCount += count
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    private func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        let output = try await provider.generate(
            template: template,
            request: request,
            context: context
        )
        let expectedIDs = template.generatedSections.map(\.id)
        let actualIDs = output.sections.map(\.sectionID)
        guard actualIDs.count == expectedIDs.count,
              Set(actualIDs).count == actualIDs.count,
              Set(actualIDs) == Set(expectedIDs)
        else {
            throw TemplateRendererError.invalidStructuredOutput
        }
        return output
    }

    private func outputWordCount(_ output: StructuredTemplateOutput) -> Int {
        output.sections.reduce(into: 0) { count, section in
            count += wordCount(section.markdown)
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func markdown(
        for output: StructuredTemplateOutput,
        template: Template,
        participantNames: [String]
    ) -> String {
        template.sections.map { section in
            let content: String
            switch section.source {
            case .speakerList:
                content = participantNames.joined(separator: ", ")
            case .generated:
                content = output.sections
                    .filter { $0.sectionID == section.id }
                    .map(\.markdown)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
            let renderedContent = content.isEmpty ? "_No information._" : content
            return "## \(section.title)\n\n\(renderedContent)"
        }
        .joined(separator: "\n\n")
    }
}
