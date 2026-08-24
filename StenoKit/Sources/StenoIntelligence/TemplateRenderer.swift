import Foundation
import StenoDomain

public struct TemplateRenderingConfiguration: Equatable, Sendable {
    /// Kompatibilitaets-Nahtstelle fuer Tests und Aufrufer, die ein festes,
    /// kleineres Budget als das Provider-Kontextfenster erzwingen wollen.
    /// Produktion laesst den Default stehen und budgetiert ausschliesslich
    /// gegen `provider.contextWindow`.
    public let targetInputTokenCount: Int
    public let maximumReductionDepth: Int
    /// Obergrenze fuer alle adaptiven Wiederholungen (Kontextfenster
    /// ueberschritten oder Antwort abgeschnitten) innerhalb eines
    /// render()-Laufs. Ohne dieses Limit koennte ein Provider, der
    /// wiederholt selbst kleinste Anfragen ablehnt, den Lauf unbegrenzt
    /// weiter aufteilen.
    public let maximumAdaptiveRetries: Int

    public init(
        targetInputTokenCount: Int = .max,
        maximumReductionDepth: Int = 16,
        maximumAdaptiveRetries: Int = 32
    ) {
        self.targetInputTokenCount = targetInputTokenCount
        self.maximumReductionDepth = maximumReductionDepth
        self.maximumAdaptiveRetries = maximumAdaptiveRetries
    }
}

public enum TemplateRendererError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    /// Schon die feste Umgebung - Instruktionen, leerer Prompt und das
    /// Ausgabeschema, ganz ohne Transkriptinhalt - passt nicht in das
    /// Kontextfenster des Providers. Kein Aufteilen kann das beheben.
    case fixedPromptExceedsContextWindow
    /// Ein Stueck Modell-Input (ein einzelner Redebeitrag oder ein
    /// Zwischenergebnis) laesst sich nicht weiter aufteilen und passt trotz
    /// maximaler Tiefe nicht in das Kontextfenster.
    case contentCannotBeSplitToFit
    case invalidStructuredOutput
    case reductionDidNotConverge
    /// Das render-weite Budget fuer adaptive Wiederholungen ist erschoepft.
    case adaptiveRetryLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The text model has no usable input token budget."
        case .fixedPromptExceedsContextWindow:
            "The template, notes and output schema already exceed the model context window. Check the configured context window under Language Models settings."
        case .contentCannotBeSplitToFit:
            "Part of the model input cannot be split small enough for this context window."
        case .invalidStructuredOutput:
            "The text model returned an incomplete structured result."
        case .reductionDidNotConverge:
            "The intermediate results could not be reduced to the model context window."
        case .adaptiveRetryLimitExceeded:
            "The text model repeatedly rejected smaller requests as too large."
        }
    }
}

/// Teilt einen Text an einer moeglichst nahe an der Mitte liegenden Grenze,
/// ohne ein einziges Byte der Quelle zu veraendern oder zu verlieren:
/// `split.0 + split.1 == text` gilt immer. Bevorzugt Zeilenumbrueche vor
/// Satzenden vor Leerraum vor einer rohen Graphem-Grenze - letztere greift
/// nur bei Text ganz ohne Leerraum (z. B. CJK), bei dem Zeilen-,
/// Satz- und Leerraumgrenzen fehlen.
enum TemplateTextSplitter {
    private struct Boundary {
        let index: String.Index
        let utf8Offset: Int
    }

    static func splitPreservingSource(_ text: String) -> (String, String)? {
        guard text.count > 1 else { return nil }
        let midpoint = text.utf8.count / 2
        var lineBoundaries: [Boundary] = []
        var sentenceBoundaries: [Boundary] = []
        var whitespaceBoundaries: [Boundary] = []
        var graphemeBoundaries: [Boundary] = []

        var index = text.startIndex
        var utf8Offset = 0
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard next < text.endIndex else { break }
            utf8Offset += text[index..<next].utf8.count
            let boundary = Boundary(index: next, utf8Offset: utf8Offset)
            graphemeBoundaries.append(boundary)
            if character == "\n" {
                lineBoundaries.append(boundary)
            } else if ".!?".contains(character) {
                sentenceBoundaries.append(boundary)
            } else if character.isWhitespace {
                whitespaceBoundaries.append(boundary)
            }
            index = next
        }

        let candidates = !lineBoundaries.isEmpty
            ? lineBoundaries
            : (!sentenceBoundaries.isEmpty
                ? sentenceBoundaries
                : (!whitespaceBoundaries.isEmpty ? whitespaceBoundaries : graphemeBoundaries))
        guard let boundary = candidates.min(by: { lhs, rhs in
            abs(lhs.utf8Offset - midpoint) < abs(rhs.utf8Offset - midpoint)
        }) else {
            return nil
        }
        return (
            String(text[..<boundary.index]),
            String(text[boundary.index...])
        )
    }
}

/// Render-weites Guthaben fuer adaptive Wiederholungen. Kontextfenster- und
/// Trunkierungs-Retries teilen sich dieses eine Budget, statt jeweils ein
/// eigenes zu fuehren - sonst koennte ein Provider, der abwechselnd beide
/// Fehler liefert, den Lauf trotz Limit unbegrenzt verlaengern.
private actor AdaptiveRetryBudget {
    private var remaining: Int

    init(maximumRetries: Int) {
        remaining = maximumRetries
    }

    func consume() throws {
        guard remaining > 0 else {
            throw TemplateRendererError.adaptiveRetryLimitExceeded
        }
        remaining -= 1
    }
}

/// Sammelt waehrend eines render()-Laufs, welcher map- oder reduce-Aufruf
/// gerade unterwegs ist, damit ein gescheiterter Provider-Aufruf eine
/// inhaltssichere Diagnostik mit Phase und Index bekommt - Metadaten, die
/// der Provider selbst nicht kennt. Eine Ausnahme: TemplateRendererError
/// bleibt unveraendert, ein invalidStructuredOutput etwa ist ein
/// Renderer-Befund, keine Provider-Diagnostik.
private actor TextModelDiagnosticTracker {
    private struct RequestLocation: Sendable {
        let stage: String
        let index: Int
    }

    private let dialect: String
    private var nextIndex = ["map": 0, "reduce": 0]
    private var current: RequestLocation?
    private var failure: TextModelRunDiagnostic?

    init(descriptor: EngineDescriptor) {
        switch descriptor.version {
        case "ollama-native": dialect = TextModelAPIDialect.ollama.rawValue
        case "lmstudio-openai-chat": dialect = TextModelAPIDialect.lmStudio.rawValue
        case "openai-compat": dialect = TextModelAPIDialect.openAICompatible.rawValue
        case "openai-responses": dialect = TextModelAPIDialect.openAI.rawValue
        case "anthropic-messages": dialect = TextModelAPIDialect.anthropic.rawValue
        case "bedrock-converse": dialect = TextModelAPIDialect.amazonBedrock.rawValue
        default: dialect = descriptor.version
        }
    }

    func begin(_ request: TextModelRequest) {
        failure = nil
        let stage: String
        switch request {
        case .map: stage = "map"
        case .reduce: stage = "reduce"
        }
        let index = (nextIndex[stage] ?? 0) + 1
        nextIndex[stage] = index
        current = RequestLocation(stage: stage, index: index)
    }

    func record(_ error: any Error) {
        guard let current else { return }
        if let diagnostic = (error as? any TextModelDiagnosticProviding)?
            .textModelDiagnostic
        {
            failure = copying(
                diagnostic,
                stage: current.stage,
                requestIndex: current.index
            )
        } else if error as? TemplateRendererError == .invalidStructuredOutput {
            failure = TextModelRunDiagnostic(
                dialect: dialect,
                stage: current.stage,
                requestIndex: current.index,
                providerCode: "invalid_structured_output",
                parsingFailure: "section_schema"
            )
        }
    }

    func wrapped(_ error: any Error) -> TextModelDiagnosticError? {
        guard let failure else { return nil }
        return TextModelDiagnosticError(
            errorDescription: (error as? LocalizedError)?.errorDescription
                ?? String(describing: error),
            textModelDiagnostic: failure
        )
    }

    private func copying(
        _ diagnostic: TextModelRunDiagnostic,
        stage: String,
        requestIndex: Int?
    ) -> TextModelRunDiagnostic {
        TextModelRunDiagnostic(
            dialect: diagnostic.dialect.isEmpty ? dialect : diagnostic.dialect,
            stage: stage,
            requestIndex: requestIndex,
            httpStatus: diagnostic.httpStatus,
            providerCode: diagnostic.providerCode,
            finishReason: diagnostic.finishReason,
            inputTokens: diagnostic.inputTokens,
            outputTokens: diagnostic.outputTokens,
            responseBytes: diagnostic.responseBytes,
            parsingFailure: diagnostic.parsingFailure,
            transportRetryCount: diagnostic.transportRetryCount,
            adaptiveRetryCount: diagnostic.adaptiveRetryCount
        )
    }
}

public struct TemplateRenderer: Sendable {
    private struct TextPiece: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

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
        guard effectiveInputLimit > 0,
              configuration.maximumReductionDepth > 0,
              configuration.maximumAdaptiveRetries >= 0
        else {
            throw TemplateRendererError.invalidConfiguration
        }

        let participantNames = participants ?? participantNames(
            transcript: transcript,
            resolver: resolver
        )
        // Der Kontext traegt die Teilnehmer mit, damit das Modell Namen und
        // Firmen so schreibt, wie sie in der Teilnehmersektion stehen. Die
        // gespeicherte Ausgabesprache reist unveraendert mit - sie ist vom
        // Aufrufer bereits ausdruecklich gesetzt, keine Ableitung dieser
        // Stelle.
        let context = RenderContext(
            userNotes: context.userNotes,
            participants: context.participants.isEmpty
                ? participantNames
                : context.participants,
            outputLocaleIdentifier: context.outputLocaleIdentifier
        )
        let diagnosticTracker = TextModelDiagnosticTracker(descriptor: provider.descriptor)
        let retryBudget = AdaptiveRetryBudget(
            maximumRetries: configuration.maximumAdaptiveRetries
        )
        do {
            let chunks = try await makeChunks(
                transcript: transcript,
                resolver: resolver,
                template: template,
                context: context
            )
            var mapped: [StructuredTemplateOutput] = []
            for chunk in chunks {
                mapped.append(contentsOf: try await generateMap(
                    chunk,
                    template: template,
                    context: context,
                    depth: 0,
                    retryBudget: retryBudget,
                    diagnosticTracker: diagnosticTracker
                ))
            }

            let output = try await finalOutput(
                mapped,
                template: template,
                context: context,
                depth: 0,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
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
        } catch {
            if error is TemplateRendererError {
                throw error
            }
            if let wrapped = await diagnosticTracker.wrapped(error) {
                throw wrapped
            }
            throw error
        }
    }

    /// Das tatsaechliche Eingabe-Budget dieses Laufs: das kleinere aus dem
    /// Provider-Kontextfenster und einer optionalen, engeren
    /// Konfigurationsgrenze.
    private var effectiveInputLimit: Int {
        min(
            provider.contextWindow.maximumInputTokens,
            configuration.targetInputTokenCount
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

    /// Zerlegt das Transkript in Map-Chunks, die jeweils gerade noch in das
    /// Eingabe-Budget passen. Prueft zuerst die feste Umgebung (leerer Map-
    /// und Reduce-Aufruf), dann teilt sie einzelne, zu lange Redebeitraege
    /// vor dem Chunking auf, und sucht die groesstmoegliche Chunk-Grenze per
    /// Sprungsuche statt jedes Praefix einzeln zu zaehlen.
    private func makeChunks(
        transcript: TranscriptRevision,
        resolver: SpeakerNameResolver,
        template: Template,
        context: RenderContext
    ) async throws -> [TranscriptChunk] {
        let empty = TranscriptChunk(turns: [])
        for request in [TextModelRequest.map(empty), .reduce([])] {
            guard try await requestFits(
                template: template,
                request: request,
                context: context
            ) else {
                throw TemplateRendererError.fixedPromptExceedsContextWindow
            }
        }

        var unresolvedSpeakers: [SpeakerReference] = []
        var fittedTurns: [TranscriptChunkTurn] = []
        for turn in transcript.turns {
            try Task.checkCancellation()
            let name = speakerName(
                for: turn.speaker,
                resolver: resolver,
                unresolvedSpeakers: &unresolvedSpeakers
            )
            let pieces = turn.segments.isEmpty
                ? [TextPiece(text: "", start: turn.start, end: turn.end)]
                : turn.segments.map {
                    TextPiece(text: $0.text, start: $0.start, end: $0.end)
                }
            fittedTurns.append(contentsOf: try await splitToFit(
                speakerName: name,
                pieces: pieces,
                template: template,
                context: context,
                depth: 0
            ))
        }

        guard !fittedTurns.isEmpty else {
            return [empty]
        }

        var chunks: [TranscriptChunk] = []
        var start = fittedTurns.startIndex
        var spanHint = 1
        while start < fittedTurns.endIndex {
            try Task.checkCancellation()
            let end = try await largestFittingMapEnd(
                in: fittedTurns,
                startingAt: start,
                spanHint: spanHint,
                template: template,
                context: context
            )
            guard end > start else {
                throw TemplateRendererError.contentCannotBeSplitToFit
            }
            chunks.append(TranscriptChunk(turns: Array(fittedTurns[start..<end])))
            spanHint = end - start
            start = end
        }
        return chunks
    }

    /// Sprungsuche: verdoppelt die Kandidatenspanne, solange sie passt, und
    /// grenzt danach binaer auf die groesste passende Spanne ein. Damit
    /// waechst die Anzahl der Token-Zaehlungen mit dem Logarithmus der
    /// tatsaechlichen Chunk-Groesse statt mit der Gesamtlaenge des
    /// Transkripts - ein einzelner Chunk am Ende eines langen Transkripts
    /// wuerde sonst jedes wachsende Praefix erneut zaehlen.
    private func largestFittingMapEnd(
        in turns: [TranscriptChunkTurn],
        startingAt start: Int,
        spanHint: Int,
        template: Template,
        context: RenderContext
    ) async throws -> Int {
        let remaining = turns.endIndex - start
        var fittingSpan = 0
        var candidateSpan = min(max(1, spanHint), remaining)
        var failingSpan: Int?

        while true {
            try Task.checkCancellation()
            let candidateEnd = start + candidateSpan
            let chunk = TranscriptChunk(turns: Array(turns[start..<candidateEnd]))
            if try await requestFits(
                template: template,
                request: .map(chunk),
                context: context
            ) {
                fittingSpan = candidateSpan
                if candidateSpan == remaining {
                    return turns.endIndex
                }
                candidateSpan = min(remaining, candidateSpan * 2)
            } else {
                failingSpan = candidateSpan
                break
            }
        }

        var lower = fittingSpan + 1
        var upper = (failingSpan ?? remaining + 1) - 1
        var best = fittingSpan
        while lower <= upper {
            try Task.checkCancellation()
            let span = lower + ((upper - lower) / 2)
            let candidateEnd = start + span
            let chunk = TranscriptChunk(turns: Array(turns[start..<candidateEnd]))
            if try await requestFits(
                template: template,
                request: .map(chunk),
                context: context
            ) {
                best = span
                lower = span + 1
            } else {
                upper = span - 1
            }
        }
        return start + best
    }

    /// Teilt einen einzelnen Redebeitrag rekursiv, bis jedes Stueck allein
    /// in einen Map-Aufruf passt. Teilt zuerst an Segmentgrenzen (die
    /// Transkriptionsgrenzen des ASR), erst danach innerhalb eines
    /// Segments an Text- statt Wortgrenzen.
    private func splitToFit(
        speakerName: String,
        pieces: [TextPiece],
        template: Template,
        context: RenderContext,
        depth: Int
    ) async throws -> [TranscriptChunkTurn] {
        try Task.checkCancellation()
        guard depth < configuration.maximumReductionDepth else {
            throw TemplateRendererError.contentCannotBeSplitToFit
        }
        let turn = combinedTurn(speakerName: speakerName, pieces: pieces)
        if try await requestFits(
            template: template,
            request: .map(TranscriptChunk(turns: [turn])),
            context: context
        ) {
            return [turn]
        }

        if pieces.count > 1 {
            let middle = pieces.count / 2
            return try await splitToFit(
                speakerName: speakerName,
                pieces: Array(pieces[..<middle]),
                template: template,
                context: context,
                depth: depth + 1
            ) + splitToFit(
                speakerName: speakerName,
                pieces: Array(pieces[middle...]),
                template: template,
                context: context,
                depth: depth + 1
            )
        }

        guard let piece = pieces.first,
              let split = splitTextPiece(piece)
        else {
            throw TemplateRendererError.contentCannotBeSplitToFit
        }
        return try await splitToFit(
            speakerName: speakerName,
            pieces: [split.0],
            template: template,
            context: context,
            depth: depth + 1
        ) + splitToFit(
            speakerName: speakerName,
            pieces: [split.1],
            template: template,
            context: context,
            depth: depth + 1
        )
    }

    private func combinedTurn(
        speakerName: String,
        pieces: [TextPiece]
    ) -> TranscriptChunkTurn {
        TranscriptChunkTurn(
            speakerName: speakerName,
            start: pieces.first?.start ?? 0,
            end: pieces.last?.end ?? 0,
            text: pieces.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    private func splitTextPiece(_ piece: TextPiece) -> (TextPiece, TextPiece)? {
        guard let split = TemplateTextSplitter.splitPreservingSource(piece.text) else {
            return nil
        }
        let ratio = Double(split.0.utf8.count) / Double(piece.text.utf8.count)
        let splitTime = piece.start + ((piece.end - piece.start) * ratio)
        return (
            TextPiece(text: split.0, start: piece.start, end: splitTime),
            TextPiece(text: split.1, start: splitTime, end: piece.end)
        )
    }

    /// Fuehrt einen einzelnen Map-Aufruf aus. Meldet der Provider das
    /// Kontextfenster als ueberschritten oder die Antwort als abgeschnitten,
    /// wird der Chunk halbiert und beide Haelften einzeln versucht - der
    /// naechste Map-Aufruf fuer diesen Chunk zaehlt gegen das render-weite
    /// Retry-Budget, nicht nur gegen die Rekursionstiefe.
    private func generateMap(
        _ chunk: TranscriptChunk,
        template: Template,
        context: RenderContext,
        depth: Int,
        retryBudget: AdaptiveRetryBudget,
        diagnosticTracker: TextModelDiagnosticTracker
    ) async throws -> [StructuredTemplateOutput] {
        do {
            return [try await generate(
                template: template,
                request: .map(chunk),
                context: context,
                diagnosticTracker: diagnosticTracker
            )]
        } catch TextModelProviderError.contextWindowExceeded, TextModelProviderError.responseTruncated {
            try await retryBudget.consume()
            guard depth < configuration.maximumReductionDepth,
                  let split = splitChunk(chunk)
            else {
                throw TemplateRendererError.contentCannotBeSplitToFit
            }
            return try await generateMap(
                split.0,
                template: template,
                context: context,
                depth: depth + 1,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            ) + generateMap(
                split.1,
                template: template,
                context: context,
                depth: depth + 1,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            )
        }
    }

    private func splitChunk(_ chunk: TranscriptChunk) -> (TranscriptChunk, TranscriptChunk)? {
        if chunk.turns.count > 1 {
            let middle = chunk.turns.count / 2
            return (
                TranscriptChunk(turns: Array(chunk.turns[..<middle])),
                TranscriptChunk(turns: Array(chunk.turns[middle...]))
            )
        }
        guard let turn = chunk.turns.first,
              let split = splitTextPiece(TextPiece(
                  text: turn.text,
                  start: turn.start,
                  end: turn.end
              ))
        else { return nil }
        return (
            TranscriptChunk(turns: [combinedTurn(
                speakerName: turn.speakerName,
                pieces: [split.0]
            )]),
            TranscriptChunk(turns: [combinedTurn(
                speakerName: turn.speakerName,
                pieces: [split.1]
            )])
        )
    }

    /// Reduziert die Map-Ergebnisse, bis genau eine finale Reduce-Antwort
    /// vorliegt. Ueberschreitet auch der letzte Reduce-Aufruf das
    /// Kontextfenster oder liefert er eine abgeschnittene Antwort, werden
    /// die schon reduzierten Zwischenergebnisse zwangsweise weiter halbiert
    /// (forceReduce), statt den Lauf scheitern zu lassen.
    private func finalOutput(
        _ outputs: [StructuredTemplateOutput],
        template: Template,
        context: RenderContext,
        depth: Int,
        retryBudget: AdaptiveRetryBudget,
        diagnosticTracker: TextModelDiagnosticTracker
    ) async throws -> StructuredTemplateOutput {
        guard depth < configuration.maximumReductionDepth else {
            throw TemplateRendererError.reductionDidNotConverge
        }
        let fitted = try await reduceToFit(
            outputs,
            template: template,
            depth: depth,
            context: context,
            retryBudget: retryBudget,
            diagnosticTracker: diagnosticTracker
        )
        do {
            return try await generate(
                template: template,
                request: .reduce(fitted),
                context: context,
                diagnosticTracker: diagnosticTracker
            )
        } catch TextModelProviderError.contextWindowExceeded, TextModelProviderError.responseTruncated {
            try await retryBudget.consume()
            let smaller = try await forceReduce(
                fitted,
                template: template,
                context: context,
                depth: depth + 1,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            )
            return try await finalOutput(
                smaller,
                template: template,
                context: context,
                depth: depth + 1,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            )
        }
    }

    /// Fuehrt Map-Ergebnisse batchweise zusammen, bis das Gesamtergebnis in
    /// das Eingabe-Budget passt. Jedes einzelne Zwischenergebnis wird zuerst
    /// so weit gesplittet, dass es allein passt (`splitOutputToFit`), dann
    /// wird per Sprungsuche die groesstmoegliche Batchgrenze gesucht.
    private func reduceToFit(
        _ outputs: [StructuredTemplateOutput],
        template: Template,
        depth: Int,
        context: RenderContext,
        retryBudget: AdaptiveRetryBudget,
        diagnosticTracker: TextModelDiagnosticTracker
    ) async throws -> [StructuredTemplateOutput] {
        guard depth < configuration.maximumReductionDepth else {
            throw TemplateRendererError.reductionDidNotConverge
        }
        if try await requestFits(
            template: template,
            request: .reduce(outputs),
            context: context
        ) {
            return outputs
        }

        var units: [StructuredTemplateOutput] = []
        for output in outputs {
            try Task.checkCancellation()
            units.append(contentsOf: try await splitOutputToFit(
                output,
                template: template,
                context: context,
                depth: depth
            ))
        }
        let batches = try await reductionBatches(
            units,
            template: template,
            context: context
        )
        var next: [StructuredTemplateOutput] = []
        for batch in batches {
            try Task.checkCancellation()
            next.append(contentsOf: try await generateReduce(
                batch,
                template: template,
                context: context,
                depth: depth,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            ))
        }
        let previousTokens = try await inputTokens(
            template: template,
            request: .reduce(outputs),
            context: context
        )
        let nextTokens = try await inputTokens(
            template: template,
            request: .reduce(next),
            context: context
        )
        guard next.count < outputs.count || nextTokens < previousTokens else {
            throw TemplateRendererError.reductionDidNotConverge
        }
        return try await reduceToFit(
            next,
            template: template,
            depth: depth + 1,
            context: context,
            retryBudget: retryBudget,
            diagnosticTracker: diagnosticTracker
        )
    }

    private func reductionBatches(
        _ outputs: [StructuredTemplateOutput],
        template: Template,
        context: RenderContext
    ) async throws -> [[StructuredTemplateOutput]] {
        var batches: [[StructuredTemplateOutput]] = []
        var start = outputs.startIndex
        var spanHint = 1
        while start < outputs.endIndex {
            try Task.checkCancellation()
            let remaining = outputs.endIndex - start
            var fittingSpan = 0
            var candidateSpan = min(max(1, spanHint), remaining)
            var failingSpan: Int?
            while true {
                try Task.checkCancellation()
                if try await requestFits(
                    template: template,
                    request: .reduce(Array(outputs[start..<(start + candidateSpan)])),
                    context: context
                ) {
                    fittingSpan = candidateSpan
                    if candidateSpan == remaining { break }
                    candidateSpan = min(remaining, candidateSpan * 2)
                } else {
                    failingSpan = candidateSpan
                    break
                }
            }
            if fittingSpan == remaining {
                batches.append(Array(outputs[start..<outputs.endIndex]))
                break
            }
            var lower = fittingSpan + 1
            var upper = (failingSpan ?? remaining + 1) - 1
            var best = fittingSpan
            while lower <= upper {
                try Task.checkCancellation()
                let span = lower + ((upper - lower) / 2)
                let candidateEnd = start + span
                if try await requestFits(
                    template: template,
                    request: .reduce(Array(outputs[start..<candidateEnd])),
                    context: context
                ) {
                    best = span
                    lower = span + 1
                } else {
                    upper = span - 1
                }
            }
            guard best > 0 else {
                throw TemplateRendererError.contentCannotBeSplitToFit
            }
            let end = start + best
            batches.append(Array(outputs[start..<end]))
            spanHint = best
            start = end
        }
        return batches
    }

    private func generateReduce(
        _ outputs: [StructuredTemplateOutput],
        template: Template,
        context: RenderContext,
        depth: Int,
        retryBudget: AdaptiveRetryBudget,
        diagnosticTracker: TextModelDiagnosticTracker
    ) async throws -> [StructuredTemplateOutput] {
        do {
            return [try await generate(
                template: template,
                request: .reduce(outputs),
                context: context,
                diagnosticTracker: diagnosticTracker
            )]
        } catch TextModelProviderError.contextWindowExceeded, TextModelProviderError.responseTruncated {
            try await retryBudget.consume()
            return try await forceReduce(
                outputs,
                template: template,
                context: context,
                depth: depth + 1,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            )
        }
    }

    /// Halbiert ein Batch, dessen Reduce-Aufruf gescheitert ist, so lange,
    /// bis jede Haelfte fuer sich reduziert werden kann. Ein einzelnes,
    /// nicht mehr teilbares Zwischenergebnis wird als Text gesplittet.
    private func forceReduce(
        _ outputs: [StructuredTemplateOutput],
        template: Template,
        context: RenderContext,
        depth: Int,
        retryBudget: AdaptiveRetryBudget,
        diagnosticTracker: TextModelDiagnosticTracker
    ) async throws -> [StructuredTemplateOutput] {
        guard depth < configuration.maximumReductionDepth else {
            throw TemplateRendererError.reductionDidNotConverge
        }
        let halves: [[StructuredTemplateOutput]]
        if outputs.count > 1 {
            let middle = outputs.count / 2
            halves = [Array(outputs[..<middle]), Array(outputs[middle...])]
        } else if let output = outputs.first,
                  let split = splitOutput(output)
        {
            halves = [[split.0], [split.1]]
        } else {
            throw TemplateRendererError.contentCannotBeSplitToFit
        }
        var result: [StructuredTemplateOutput] = []
        for half in halves {
            try Task.checkCancellation()
            result.append(contentsOf: try await generateReduce(
                half,
                template: template,
                context: context,
                depth: depth,
                retryBudget: retryBudget,
                diagnosticTracker: diagnosticTracker
            ))
        }
        return result
    }

    private func splitOutputToFit(
        _ output: StructuredTemplateOutput,
        template: Template,
        context: RenderContext,
        depth: Int
    ) async throws -> [StructuredTemplateOutput] {
        try Task.checkCancellation()
        guard depth < configuration.maximumReductionDepth else {
            throw TemplateRendererError.contentCannotBeSplitToFit
        }
        if try await requestFits(
            template: template,
            request: .reduce([output]),
            context: context
        ) {
            return [output]
        }
        guard let split = splitOutput(output) else {
            throw TemplateRendererError.contentCannotBeSplitToFit
        }
        return try await splitOutputToFit(
            split.0,
            template: template,
            context: context,
            depth: depth + 1
        ) + splitOutputToFit(
            split.1,
            template: template,
            context: context,
            depth: depth + 1
        )
    }

    /// Teilt ein Zwischenergebnis entlang seiner Sektionen: solange mehr als
    /// eine nichtleere Sektion existiert, wandert je eine Haelfte der
    /// Sektionen in jedes Teil. Bleibt nur eine uebrig, wird ihr Markdown
    /// als Text gesplittet.
    private func splitOutput(
        _ output: StructuredTemplateOutput
    ) -> (StructuredTemplateOutput, StructuredTemplateOutput)? {
        guard let index = output.sections.indices.max(by: { lhs, rhs in
            wordCount(output.sections[lhs].markdown) < wordCount(output.sections[rhs].markdown)
        }) else { return nil }
        let blankSections = output.sections.map {
            StructuredTemplateSection(sectionID: $0.sectionID, markdown: "")
        }
        let nonempty = output.sections.indices.filter {
            !output.sections[$0].markdown.isEmpty
        }
        if nonempty.count > 1 {
            let middle = nonempty.count / 2
            let leftIndices = Set(nonempty[..<middle])
            var left = blankSections
            var right = blankSections
            for sectionIndex in nonempty {
                if leftIndices.contains(sectionIndex) {
                    left[sectionIndex] = output.sections[sectionIndex]
                } else {
                    right[sectionIndex] = output.sections[sectionIndex]
                }
            }
            return (
                StructuredTemplateOutput(sections: left),
                StructuredTemplateOutput(sections: right)
            )
        }

        let section = output.sections[index]
        if let split = TemplateTextSplitter.splitPreservingSource(section.markdown) {
            var left = blankSections
            var right = blankSections
            left[index] = StructuredTemplateSection(
                sectionID: section.sectionID,
                markdown: split.0
            )
            right[index] = StructuredTemplateSection(
                sectionID: section.sectionID,
                markdown: split.1
            )
            for other in output.sections.indices where other != index {
                left[other] = output.sections[other]
            }
            return (
                StructuredTemplateOutput(sections: left),
                StructuredTemplateOutput(sections: right)
            )
        }

        return nil
    }

    private func requestFits(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Bool {
        try await inputTokens(
            template: template,
            request: request,
            context: context
        ) <= effectiveInputLimit
    }

    private func inputTokens(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        try Task.checkCancellation()
        let count = try await provider.inputTokenCount(
            template: template,
            request: request,
            context: context
        )
        try Task.checkCancellation()
        return count
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

    private func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        diagnosticTracker: TextModelDiagnosticTracker
    ) async throws -> StructuredTemplateOutput {
        try Task.checkCancellation()
        await diagnosticTracker.begin(request)
        do {
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
        } catch {
            await diagnosticTracker.record(error)
            throw error
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).count
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
