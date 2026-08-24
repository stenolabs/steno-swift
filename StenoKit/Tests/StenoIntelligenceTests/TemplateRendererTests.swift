import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Map-reduce template rendering")
struct TemplateRendererTests {
    @Test("chunking uses the provider token budget and keeps content in order")
    func chunkingUsesProviderTokenBudget() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 5)
        let renderer = TemplateRenderer(provider: provider)
        let revision = makeRevision(texts: [
            "eins zwei",
            "drei",
            "vier fünf",
            "sechs",
        ])

        _ = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision
        )

        let requests = await provider.mapRequests()
        #expect(requests.map { $0.turns.map(\.text) } == [
            ["eins zwei", "drei", "vier fünf"],
            ["sechs"],
        ])
        #expect(requests.flatMap(\.turns).map(\.text) == revision.turns.map(turnText))
    }

    @Test("oversized intermediate results are reduced recursively")
    func oversizedIntermediateResultsAreReducedRecursively() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 2)
        let renderer = TemplateRenderer(provider: provider)
        let revision = makeRevision(texts: ["a", "b", "c", "d", "e", "f"])

        let result = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision
        )

        let reductions = await provider.reduceRequests()
        #expect(reductions.count >= 2)
        #expect(reductions.last?.contains { output in
            output.sections.contains { $0.markdown.hasPrefix("reduce-") }
        } == true)
        #expect(result.markdown.contains("reduce-"))
    }

    @Test("a single mapped chunk still receives the final reduce prompt")
    func singleChunkReceivesFinalReduce() async throws {
        let provider = FakeTextModelProvider()
        let revision = makeRevision(texts: ["kurzes Meeting"])

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        let reductions = await provider.reduceRequests()
        #expect(reductions.count == 1)
        #expect(reductions[0].count == 1)
    }

    @Test("singleton batches are compressed until they fit one final reduction")
    func singletonBatchesAreCompressed() async throws {
        let provider = FakeTextModelProvider(mapOutputWordCount: 2, maximumInputTokens: 3)
        let renderer = TemplateRenderer(provider: provider)
        let revision = makeRevision(texts: ["a", "b", "c", "d"])

        _ = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision
        )

        let reductions = await provider.reduceRequests()
        #expect(reductions.count == 3)
        #expect(reductions[0].count == 1)
        #expect(reductions[1].count == 1)
        #expect(reductions[2].count == 2)
    }

    @Test("a long speaker contribution is split without dropping text")
    func longTurnIsSplitWithoutDroppingText() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 4)
        let revision = makeRevision(texts: ["eins zwei drei vier fünf sechs sieben"])

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        let pieces = await provider.mapRequests().flatMap(\.turns).map(\.text)
        #expect(pieces.count > 1)
        #expect(pieces.flatMap(words) == words("eins zwei drei vier fünf sechs sieben"))
    }

    @Test("long contributions prefer transcript segment boundaries")
    func longTurnPrefersSegmentBoundaries() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 2)
        let revision = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: [
                TranscriptTurn(
                    speaker: .channel("Kanal"),
                    start: 0,
                    end: 2,
                    segments: [
                        TranscriptSegment(text: "eins zwei", start: 0, end: 1, words: []),
                        TranscriptSegment(text: "drei vier", start: 1, end: 2, words: []),
                    ]
                ),
            ]
        )

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        let pieces = await provider.mapRequests().flatMap(\.turns).map(\.text)
        #expect(pieces == ["eins zwei", "drei vier"])
    }

    @Test("chunk search does not recount every growing transcript prefix")
    func chunkSearchUsesLogarithmicPrefixChecks() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 16, reduceTokenMultiplier: 0)
        let revision = makeRevision(texts: (0..<64).map { "wort-\($0)" })

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        #expect(await provider.mapTokenCountRequestCount() < 100)
    }

    @Test("chunk search keeps total counted transcript volume near linear")
    func chunkSearchBoundsCountedVolume() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 16, reduceTokenMultiplier: 0)
        let turns = (0..<1_024).map { "wort-\($0)" }

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: makeRevision(texts: turns)
        )

        #expect(await provider.totalMapTurnsCounted() < turns.count * 12)
    }

    @Test("cancellation during token counting prevents generation")
    func cancellationStopsBeforeGeneration() async {
        let provider = FakeTextModelProvider(cancelAtMapTokenCountCall: 2)

        let task = Task {
            try await TemplateRenderer(provider: provider).render(
                template: .meetingMinutes,
                transcript: makeRevision(texts: ["eins", "zwei"])
            )
        }
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("Expected cancellation")
            return
        }
        #expect(error is CancellationError)
        #expect(await provider.mapRequests().isEmpty)
        #expect(await provider.reduceRequests().isEmpty)
    }

    @Test("adaptive context retries share one render-wide limit")
    func adaptiveRetriesAreGloballyBounded() async {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 1_000,
            overflowMapRequestsLargerThan: 0
        )
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(
                maximumReductionDepth: 100,
                maximumAdaptiveRetries: 4
            )
        )

        await #expect(throws: TemplateRendererError.adaptiveRetryLimitExceeded) {
            _ = try await renderer.render(
                template: .meetingMinutes,
                transcript: makeRevision(texts: [
                    "eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf "
                        + "dreizehn vierzehn fünfzehn sechzehn siebzehn achtzehn "
                        + "neunzehn zwanzig einundzwanzig zweiundzwanzig dreiundzwanzig "
                        + "vierundzwanzig fünfundzwanzig sechsundzwanzig siebenundzwanzig "
                        + "achtundzwanzig neunundzwanzig dreißig einunddreißig zweiunddreißig "
                        + "dreiunddreißig vierunddreißig fünfunddreißig sechsunddreißig "
                        + "siebenunddreißig achtunddreißig neununddreißig vierzig "
                        + "einundvierzig zweiundvierzig dreiundvierzig vierundvierzig "
                        + "fünfundvierzig sechsundvierzig siebenundvierzig achtundvierzig "
                        + "neunundvierzig fünfzig einundfünfzig zweiundfünfzig dreiundfünfzig "
                        + "vierundfünfzig fünfundfünfzig sechsundfünfzig siebenundfünfzig "
                        + "achtundfünfzig neunundfünfzig sechzig einundsechzig zweiundsechzig "
                        + "dreiundsechzig vierundsechzig",
                ])
            )
        }

        #expect(await provider.mapRequests().count == 5)
    }

    @Test("preferred text splitting preserves Markdown bytes exactly")
    func markdownSplitPreservesSource() throws {
        let markdown = "# Titel\n\nErster Satz.  Zweiter Satz.\n- Eins\n- Zwei\n"
        let split = try #require(TemplateTextSplitter.splitPreservingSource(markdown))

        #expect(split.0 + split.1 == markdown)
        #expect(!split.0.isEmpty)
        #expect(!split.1.isEmpty)
    }

    @Test("unbroken text falls back to grapheme boundaries without losing source")
    func unbrokenTextSplitPreservesSource() throws {
        let source = "漢字仮名交じり文文字列"
        let split = try #require(TemplateTextSplitter.splitPreservingSource(source))

        #expect(split.0 + split.1 == source)
        #expect(!split.0.isEmpty)
        #expect(!split.1.isEmpty)
    }

    @Test("context overflow retries with smaller map requests")
    func contextOverflowRetriesWithSmallerMapRequests() async throws {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 20,
            overflowMapRequestsLargerThan: 2
        )
        let revision = makeRevision(texts: ["eins", "zwei", "drei", "vier"])

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        let sizes = await provider.mapRequests().map(\.turns.count)
        #expect(sizes.first == 4)
        #expect(sizes.dropFirst().allSatisfy { $0 <= 2 })
    }

    @Test("truncated map responses retry with smaller source chunks")
    func truncatedMapResponseRetriesWithSmallerChunks() async throws {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 20,
            truncateMapRequestsLargerThan: 2
        )
        let revision = makeRevision(texts: ["eins", "zwei", "drei", "vier"])

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        let sizes = await provider.mapRequests().map(\.turns.count)
        #expect(sizes.first == 4)
        #expect(sizes.dropFirst().allSatisfy { $0 <= 2 })
    }

    /// Die Gegenprobe zum Test darueber. Ein Modell, das gar keinen Inhalt
    /// liefert, wird auch bei einem halb so grossen Abschnitt keinen liefern.
    /// Trotzdem zu teilen kostete an einem echten Lauf 171 Aufrufe und
    /// zweieinhalb Stunden, weil jede Teilung beide Haelften erneut versucht.
    /// Der Fehler muss deshalb bis zum Aufrufer durchkommen.
    @Test("empty map responses are not retried with smaller chunks")
    func emptyMapResponseDoesNotSplit() async throws {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 20,
            emptyMapResponses: true
        )
        let revision = makeRevision(texts: ["eins", "zwei", "drei", "vier"])

        let error = await #expect(throws: (any Error).self) {
            _ = try await TemplateRenderer(provider: provider).render(
                template: .meetingMinutes,
                transcript: revision
            )
        }

        // Der Renderer ergaenzt Phase und Index, der Befund selbst bleibt.
        let diagnostic = try #require(
            (error as? (any TextModelDiagnosticProviding))?.textModelDiagnostic
        )
        #expect(diagnostic.providerCode == "response_empty")
        #expect(diagnostic.stage == "map")
        #expect(await provider.mapRequests().count == 1)
    }

    @Test("reduce context overflow retries with smaller batches")
    func reduceOverflowRetriesWithSmallerBatches() async throws {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 100,
            overflowReduceRequestsLargerThan: 2
        )
        let longTurn = Array(repeating: "wort", count: 60).joined(separator: " ")
        let revision = makeRevision(texts: [longTurn, longTurn, longTurn, longTurn])

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: revision
        )

        let sizes = await provider.reduceRequests().map(\.count)
        #expect(sizes.first == 4)
        #expect(sizes.dropFirst().allSatisfy { $0 <= 2 })
    }

    @Test("truncated reduce responses retry with smaller batches")
    func truncatedReduceRetriesWithSmallerBatches() async throws {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 100,
            truncateReduceRequestsLargerThan: 2
        )
        let longTurn = Array(repeating: "wort", count: 60).joined(separator: " ")

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: makeRevision(texts: [longTurn, longTurn, longTurn, longTurn])
        )

        let requests = await provider.reduceRequests()
        let sizes = requests.map(\.count)
        #expect(sizes.first == 4)
        #expect(sizes.dropFirst().allSatisfy { $0 <= 2 })
        #expect(Set(requests.map(reduceSignature)).count == requests.count)
    }

    @Test("truncated reduce retries use the render-wide adaptive budget")
    func truncatedReduceRetriesUseGlobalBudget() async {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 100,
            truncateReduceRequestsLargerThan: 0
        )
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(
                maximumReductionDepth: 100,
                maximumAdaptiveRetries: 2
            )
        )

        await #expect(throws: TemplateRendererError.adaptiveRetryLimitExceeded) {
            _ = try await renderer.render(
                template: .meetingMinutes,
                transcript: makeRevision(texts: ["eins", "zwei", "drei", "vier"])
            )
        }
        #expect(await provider.reduceRequests().count == 3)
    }

    @Test("reduce batches use provider token counts instead of output word counts")
    func reduceBatchesUseProviderTokens() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 6, reduceTokenMultiplier: 3)
        let turn = "eins zwei drei vier fünf"

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: makeRevision(texts: [turn, turn, turn])
        )

        let sizes = await provider.reduceRequests().map(\.count)
        #expect(sizes.prefix(2) == [2, 1])
        #expect(sizes.allSatisfy { $0 <= 2 })
    }

    @Test("three or more reduce batches advance by batch length")
    func threeReduceBatchesAdvanceCorrectly() async throws {
        let provider = FakeTextModelProvider(maximumInputTokens: 100)
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(targetInputTokenCount: 2)
        )

        _ = try await renderer.render(
            template: .meetingMinutes,
            transcript: makeRevision(texts: (0..<10).map { "turn-\($0)" })
        )

        let reductions = await provider.reduceRequests()
        #expect(reductions.prefix(3).map(\.count) == [2, 2, 1])
    }

    @Test("oversized structured outputs split across section boundaries")
    func oversizedOutputsSplitAcrossSections() async throws {
        let provider = FakeTextModelProvider(
            mapOutputInEverySection: true,
            maximumInputTokens: 2
        )

        _ = try await TemplateRenderer(provider: provider).render(
            template: .meetingMinutes,
            transcript: makeRevision(texts: ["inhalt"])
        )

        let reductions = await provider.reduceRequests()
        #expect(!reductions.isEmpty)
        #expect(reductions.allSatisfy { request in
            request.flatMap(\.sections).filter { !$0.markdown.isEmpty }.count <= 2
        })
    }

    @Test("static prompt overhead that cannot fit fails before generation")
    func staticPromptOverheadFailsBeforeGeneration() async {
        let provider = FakeTextModelProvider(maximumInputTokens: 2, fixedInputTokens: 3)

        await #expect(throws: TemplateRendererError.fixedPromptExceedsContextWindow) {
            _ = try await TemplateRenderer(provider: provider).render(
                template: .meetingMinutes,
                transcript: makeRevision(texts: [])
            )
        }
        #expect(await provider.mapRequests().isEmpty)
    }

    @Test("static reduce prompt overhead fails before generation")
    func staticReducePromptOverheadFailsBeforeGeneration() async {
        let provider = FakeTextModelProvider(
            maximumInputTokens: 2,
            fixedInputTokens: 1,
            fixedReduceInputTokens: 3
        )

        await #expect(throws: TemplateRendererError.fixedPromptExceedsContextWindow) {
            _ = try await TemplateRenderer(provider: provider).render(
                template: .meetingMinutes,
                transcript: makeRevision(texts: [])
            )
        }
        #expect(await provider.mapRequests().isEmpty)
    }

    @Test("missing guided sections fail explicitly instead of disappearing")
    func missingGuidedSectionsFailExplicitly() async {
        let provider = FakeTextModelProvider(returnsValidSections: false)
        let revision = makeRevision(texts: ["Inhalt"])

        await #expect(throws: TemplateRendererError.invalidStructuredOutput) {
            _ = try await TemplateRenderer(provider: provider).render(
                template: .meetingMinutes,
                transcript: revision
            )
        }
    }

    @Test("terminal provider failures expose content-safe request diagnostics")
    func terminalFailureDiagnostic() async throws {
        let provider = DiagnosticFailureProvider()
        let renderer = TemplateRenderer(provider: provider)
        let revision = makeRevision(texts: ["PROMPT_SENTINEL"])

        do {
            _ = try await renderer.render(
                template: .meetingMinutes,
                transcript: revision,
                participants: ["PARTICIPANT_SENTINEL"],
                context: RenderContext(userNotes: "NOTE_SENTINEL")
            )
            Issue.record("Expected the provider failure")
        } catch let error as any TextModelDiagnosticProviding {
            let diagnostic = error.textModelDiagnostic
            #expect(diagnostic.dialect == TextModelAPIDialect.ollama.rawValue)
            #expect(diagnostic.stage == "map")
            #expect(diagnostic.requestIndex == 1)
            #expect(diagnostic.httpStatus == 503)
            #expect(diagnostic.providerCode == "server_error")
            let encoded = String(
                decoding: try JSONEncoder().encode(diagnostic),
                as: UTF8.self
            )
            #expect(!encoded.contains("PROMPT_SENTINEL"))
            #expect(!encoded.contains("PARTICIPANT_SENTINEL"))
            #expect(!encoded.contains("NOTE_SENTINEL"))
            #expect(!encoded.contains("RESPONSE_SENTINEL"))
            #expect(!encoded.contains("SECRET_SENTINEL"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("speaker resolver supplies person and cluster labels without review dependencies")
    func speakerResolverSuppliesNames() async throws {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(provider: provider)
        let personID = PersonID()
        let runID = RunID()
        let revision = makeRevision(
            speakers: [
                .person(personID),
                .cluster(runID: runID, clusterID: "SPEAKER_7"),
            ],
            texts: ["Willkommen", "Danke"]
        )

        _ = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision,
            resolvingSpeakerName: { speaker in
                switch speaker {
                case .person(let id) where id == personID:
                    "Ada Lovelace"
                case .cluster(let id, let clusterID)
                    where id == runID && clusterID == "SPEAKER_7":
                    "Gast"
                default:
                    nil
                }
            }
        )

        let chunks = await provider.mapRequests()
        #expect(chunks.flatMap(\.turns).map(\.speakerName) == ["Ada Lovelace", "Gast"])
    }

    @Test("imported labels override local resolvers and hide unconfirmed source text")
    func importedLabelsKeepSourceConfirmation() async throws {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(provider: provider)
        let confirmed = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000030")!,
                text: "Ada",
                wasConfirmedAtSource: true
            )
        )
        let unconfirmed = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000031")!,
                text: "Ada",
                wasConfirmedAtSource: false
            )
        )

        _ = try await renderer.render(
            template: .meetingMinutes,
            transcript: makeRevision(
                speakers: [confirmed, unconfirmed],
                texts: ["Confirmed words", "Unconfirmed words"]
            ),
            resolvingSpeakerName: { _ in "Mallory" }
        )

        #expect(await provider.mapRequests().flatMap(\.turns).map(\.speakerName) == ["Ada", "Speaker 1"])
    }

    @Test("participants section is rendered from speaker data, not by the model")
    func participantsAreDeterministic() async throws {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(provider: provider)
        let personID = PersonID()
        let revision = makeRevision(
            speakers: [.person(personID), .channel("System"), .person(personID)],
            texts: ["Hallo", "Guten Tag", "Weiter im Text"]
        )

        let result = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision,
            resolvingSpeakerName: { speaker in
                if case .person(let id) = speaker, id == personID {
                    return "Ada Lovelace"
                }
                return nil
            }
        )

        // Verbindliche Liste aus der Revision, dedupliziert, in Reihenfolge
        // des ersten Auftretens; das Modell hat die Sektion nie gesehen.
        #expect(result.markdown.contains("## Participants\n\nAda Lovelace, System"))
        let requestedIDs = await provider.mapRequests().isEmpty
            ? []
            : Template.meetingMinutes.generatedSections.map(\.id)
        #expect(!requestedIDs.contains("participants"))
    }

    @Test("render result records template, provider, and source revision")
    func resultRecordsProvenance() async throws {
        let provider = FakeTextModelProvider()
        let revision = makeRevision(texts: ["Ein kurzer Beitrag"])

        let result = try await provider.render(
            template: .meetingMinutes,
            transcript: revision
        )

        #expect(result.template == .meetingMinutes)
        #expect(result.engine == provider.descriptor)
        #expect(result.revisionID == revision.id)
        #expect(result.markdown.hasPrefix("## Summary"))
    }

    @Test("the stored output locale reaches the provider unchanged")
    func outputLocaleReachesTheProvider() async throws {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(provider: provider)
        let revision = makeRevision(texts: ["Hallo"])

        _ = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision,
            context: RenderContext(outputLocaleIdentifier: "de-DE")
        )

        let contexts = await provider.recordedContexts()
        #expect(contexts.allSatisfy { $0.outputLocaleIdentifier == "de-DE" })
    }

    @Test("availability exposes Apple Intelligence disabled as a named state")
    func unavailableIsNamedState() {
        let provider = FakeTextModelProvider(
            availability: .unavailable(.appleIntelligenceNotEnabled)
        )

        #expect(provider.availability == .unavailable(.appleIntelligenceNotEnabled))
    }

    private func makeRevision(
        speakers: [SpeakerReference?] = [],
        texts: [String]
    ) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: texts.enumerated().map { index, text in
                TranscriptTurn(
                    speaker: index < speakers.count ? speakers[index] : .channel("Kanal"),
                    start: TimeInterval(index),
                    end: TimeInterval(index + 1),
                    segments: [
                        TranscriptSegment(
                            text: text,
                            start: TimeInterval(index),
                            end: TimeInterval(index + 1),
                            words: []
                        ),
                    ]
                )
            }
        )
    }

    private func turnText(_ turn: TranscriptTurn) -> String {
        turn.segments.map(\.text).joined(separator: " ")
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isWhitespace).map(String.init)
    }

    private func reduceSignature(_ outputs: [StructuredTemplateOutput]) -> String {
        outputs.flatMap(\.sections).map {
            "\($0.sectionID):\($0.markdown)"
        }.joined(separator: "|")
    }
}

private struct DiagnosticFailureProvider: StructuredTextModelProvider {
    let descriptor = EngineDescriptor(
        name: "Ollama fixture",
        version: "ollama-native",
        modelVersion: "fixture"
    )
    let availability: TextModelAvailability = .available
    let contextWindow = TextModelContextWindow(
        maximumTokens: 1_000_000,
        reservedResponseTokens: 0,
        safetyTokens: 0
    )

    func inputTokenCount(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        1
    }

    func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        throw OllamaProviderError.serverError(statusCode: 503)
    }
}

private actor FakeTextModelProvider: StructuredTextModelProvider {
    nonisolated let descriptor = EngineDescriptor(
        name: "FakeTextModel",
        version: "1"
    )
    nonisolated let availability: TextModelAvailability
    nonisolated let contextWindow: TextModelContextWindow

    private var maps: [TranscriptChunk] = []
    private var reductions: [[StructuredTemplateOutput]] = []
    private var contexts: [RenderContext] = []
    private var mapTokenCountCalls = 0
    private var mapTurnsCounted = 0
    private let mapOutputWordCount: Int
    private let mapOutputInEverySection: Bool
    private let returnsValidSections: Bool
    private let fixedInputTokens: Int
    private let fixedReduceInputTokens: Int?
    private let overflowMapRequestsLargerThan: Int?
    private let truncateMapRequestsLargerThan: Int?
    private let emptyMapResponses: Bool
    private let overflowReduceRequestsLargerThan: Int?
    private let truncateReduceRequestsLargerThan: Int?
    private let reduceTokenMultiplier: Int
    private let cancelAtMapTokenCountCall: Int?

    init(
        availability: TextModelAvailability = .available,
        mapOutputWordCount: Int = 1,
        mapOutputInEverySection: Bool = false,
        returnsValidSections: Bool = true,
        maximumInputTokens: Int = 1_000_000,
        fixedInputTokens: Int = 0,
        fixedReduceInputTokens: Int? = nil,
        overflowMapRequestsLargerThan: Int? = nil,
        emptyMapResponses: Bool = false,
        truncateMapRequestsLargerThan: Int? = nil,
        overflowReduceRequestsLargerThan: Int? = nil,
        truncateReduceRequestsLargerThan: Int? = nil,
        reduceTokenMultiplier: Int = 1,
        cancelAtMapTokenCountCall: Int? = nil
    ) {
        self.availability = availability
        self.mapOutputWordCount = mapOutputWordCount
        self.mapOutputInEverySection = mapOutputInEverySection
        self.returnsValidSections = returnsValidSections
        self.contextWindow = TextModelContextWindow(
            maximumTokens: maximumInputTokens,
            reservedResponseTokens: 0,
            safetyTokens: 0
        )
        self.fixedInputTokens = fixedInputTokens
        self.fixedReduceInputTokens = fixedReduceInputTokens
        self.overflowMapRequestsLargerThan = overflowMapRequestsLargerThan
        self.truncateMapRequestsLargerThan = truncateMapRequestsLargerThan
        self.emptyMapResponses = emptyMapResponses
        self.overflowReduceRequestsLargerThan = overflowReduceRequestsLargerThan
        self.truncateReduceRequestsLargerThan = truncateReduceRequestsLargerThan
        self.reduceTokenMultiplier = reduceTokenMultiplier
        self.cancelAtMapTokenCountCall = cancelAtMapTokenCountCall
    }

    func inputTokenCount(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        switch request {
        case .map(let chunk):
            mapTokenCountCalls += 1
            mapTurnsCounted += chunk.turns.count
            if mapTokenCountCalls == cancelAtMapTokenCountCall {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
            return fixedInputTokens + chunk.turns.flatMap { words($0.text) }.count
        case .reduce(let outputs):
            return (fixedReduceInputTokens ?? fixedInputTokens)
                + outputs.flatMap(\.sections).flatMap { words($0.markdown) }.count
                    * reduceTokenMultiplier
        }
    }

    func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        contexts.append(context)
        switch request {
        case .map(let chunk):
            maps.append(chunk)
            if let overflowMapRequestsLargerThan,
               chunk.turns.count > overflowMapRequestsLargerThan
            {
                throw TextModelProviderError.contextWindowExceeded
            }
            if emptyMapResponses {
                throw TextModelProviderError.responseEmpty
            }
            if let truncateMapRequestsLargerThan,
               chunk.turns.count > truncateMapRequestsLargerThan
            {
                throw TextModelProviderError.responseTruncated
            }
            let word = "map-\(maps.count)"
            return output(
                template: template,
                markdown: Array(repeating: word, count: mapOutputWordCount)
                    .joined(separator: " "),
                inEverySection: mapOutputInEverySection
            )
        case .reduce(let inputs):
            reductions.append(inputs)
            if let overflowReduceRequestsLargerThan,
               inputs.count > overflowReduceRequestsLargerThan
            {
                throw TextModelProviderError.contextWindowExceeded
            }
            if let truncateReduceRequestsLargerThan,
               inputs.count > truncateReduceRequestsLargerThan
            {
                throw TextModelProviderError.responseTruncated
            }
            return output(
                template: template,
                markdown: "reduce-\(reductions.count)",
                inEverySection: false
            )
        }
    }

    func mapRequests() -> [TranscriptChunk] {
        maps
    }

    func reduceRequests() -> [[StructuredTemplateOutput]] {
        reductions
    }

    func recordedContexts() -> [RenderContext] {
        contexts
    }

    func mapTokenCountRequestCount() -> Int {
        mapTokenCountCalls
    }

    func totalMapTurnsCounted() -> Int {
        mapTurnsCounted
    }

    private func output(
        template: Template,
        markdown: String,
        inEverySection: Bool
    ) -> StructuredTemplateOutput {
        guard returnsValidSections else {
            return StructuredTemplateOutput(
                sections: [
                    StructuredTemplateSection(
                        sectionID: template.generatedSections[0].id,
                        markdown: markdown
                    ),
                ]
            )
        }
        return StructuredTemplateOutput(
            sections: template.generatedSections.enumerated().map { index, section in
                StructuredTemplateSection(
                    sectionID: section.id,
                    markdown: inEverySection || index == 0 ? markdown : ""
                )
            }
        )
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isWhitespace).map(String.init)
    }
}
