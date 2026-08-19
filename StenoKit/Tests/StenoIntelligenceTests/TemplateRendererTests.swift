import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Map-reduce template rendering")
struct TemplateRendererTests {
    @Test("chunking keeps whole turns exactly once and in order")
    func chunkingKeepsWholeTurnsExactlyOnce() async throws {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(targetInputWordCount: 3)
        )
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
            ["eins zwei", "drei"],
            ["vier fünf", "sechs"],
        ])
        #expect(requests.flatMap(\.turns).map(\.text) == revision.turns.map(turnText))
    }

    @Test("oversized intermediate results are reduced recursively")
    func oversizedIntermediateResultsAreReducedRecursively() async throws {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(targetInputWordCount: 2)
        )
        let revision = makeRevision(texts: ["a", "b", "c", "d", "e", "f"])

        let result = try await renderer.render(
            template: .meetingMinutes,
            transcript: revision
        )

        let reductions = await provider.reduceRequests()
        #expect(reductions.count == 2)
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
        let provider = FakeTextModelProvider(mapOutputWordCount: 2)
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(targetInputWordCount: 3)
        )
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

    @Test("a turn larger than the configured context target fails before model invocation")
    func oversizedTurnFailsBeforeModelInvocation() async {
        let provider = FakeTextModelProvider()
        let renderer = TemplateRenderer(
            provider: provider,
            configuration: TemplateRenderingConfiguration(targetInputWordCount: 3)
        )
        let revision = makeRevision(texts: ["eins zwei drei vier"])

        await #expect(
            throws: TemplateRendererError.turnExceedsTargetWordCount(actual: 4, limit: 3)
        ) {
            _ = try await renderer.render(
                template: .meetingMinutes,
                transcript: revision
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
}

private actor FakeTextModelProvider: StructuredTextModelProvider {
    nonisolated let descriptor = EngineDescriptor(
        name: "FakeTextModel",
        version: "1"
    )
    nonisolated let availability: TextModelAvailability

    private var maps: [TranscriptChunk] = []
    private var reductions: [[StructuredTemplateOutput]] = []
    private var contexts: [RenderContext] = []
    private let mapOutputWordCount: Int
    private let returnsValidSections: Bool

    init(
        availability: TextModelAvailability = .available,
        mapOutputWordCount: Int = 1,
        returnsValidSections: Bool = true
    ) {
        self.availability = availability
        self.mapOutputWordCount = mapOutputWordCount
        self.returnsValidSections = returnsValidSections
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
            let word = "map-\(maps.count)"
            return output(
                template: template,
                markdown: Array(repeating: word, count: mapOutputWordCount)
                    .joined(separator: " ")
            )
        case .reduce(let inputs):
            reductions.append(inputs)
            return output(
                template: template,
                markdown: "reduce-\(reductions.count)"
            )
        }
    }

    func mapRequests() -> [TranscriptChunk] {
        maps
    }

    func reduceRequests() -> [[StructuredTemplateOutput]] {
        reductions
    }

    private func output(
        template: Template,
        markdown: String
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
                    markdown: index == 0 ? markdown : ""
                )
            }
        )
    }
}
