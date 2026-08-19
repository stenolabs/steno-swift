import Foundation
import StenoDomain
import StenoIdentity
import StenoIntelligence
@testable import StenoLibrary
@testable import StenoPipeline
import Synchronization
import Testing

@Suite("Template render pipeline")
struct TemplateRenderPipelineTests {
    @Test("concurrent enqueue returns one job pinned to the visible preflight")
    func concurrentEnqueueReturnsOnePinnedJob() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let preflight = try await TemplateRenderInputAssembler.preflight(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )

            async let first = enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID,
                preflight: preflight
            )
            async let second = enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID,
                preflight: preflight
            )
            let jobs = try await [first, second]
            let persisted = try await fixture.jobStore.list()

            #expect(jobs[0].id == jobs[1].id)
            #expect(persisted.count == 1)
            #expect(persisted.first?.revisionID == preflight.revisionID)
            #expect(persisted.first?.textModelEndpointID == fixtureTextModelEndpointID)
            #expect(
                persisted.first?.templateRenderInputFingerprint
                    == preflight.inputFingerprint
            )
        }
    }

    @Test("input changed after validation cannot leave a template job")
    func inputChangedAfterValidationDoesNotEnqueue() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let preflight = try await TemplateRenderInputAssembler.preflight(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            let resolver = ResolverRecorder { _ in provider }

            await #expect(throws: TemplateRenderPreflightError.inputChanged) {
                _ = try await TemplateRenderRequest.enqueue(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meeting.id,
                    templateID: Template.meetingMinutes.id,
                    textModelEndpointID: fixtureTextModelEndpointID,
                    preflight: preflight,
                    checkpoint: { checkpoint in
                        guard checkpoint
                            == .afterPreflightValidationBeforeJobPersistence
                        else { return }
                        try FileManager.default.createDirectory(
                            at: fixture.library.layout.notesDirectory(fixture.meeting.id),
                            withIntermediateDirectories: true
                        )
                        try AtomicFile.write(
                            Data("Nach der Prüfung geändert".utf8),
                            to: fixture.library.layout.userNotes(fixture.meeting.id)
                        )
                    }
                )
            }

            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProviderResolver: resolver.resolve
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.list().isEmpty)
            #expect(resolver.requestedEndpointIDs.isEmpty)
            #expect(await provider.callCount() == 0)
            await coordinator.stop()
        }
    }

    @Test("an imported template request pins the current transfer generation")
    func importedEnqueuePinsGeneration() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedTemplateFixture(at: root)
            let generation = try #require(
                fixture.meeting.metadata?.transferReceipt?.importGenerationID
            )

            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )

            #expect(job.importGenerationID == generation)
            #expect(try await fixture.jobStore.load(job.id).importGenerationID == generation)
        }
    }

    @Test("a pending imported commit cannot enqueue a template job")
    func pendingImportedCommitBlocksTemplateEnqueue() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedTemplateFixture(at: root)
            let receipt = try #require(fixture.meeting.metadata?.transferReceipt)
            try MeetingTransferStateStore.writeCommitPendingGuard(
                meetingID: fixture.meeting.id,
                receipt: receipt,
                to: fixture.library.layout.transferCommitPending(fixture.meeting.id)
            )

            await #expect(throws: MeetingProcessingRequestError.commitRecoveryRequired(
                fixture.meeting.id
            )) {
                _ = try await enqueueTemplateRequest(
                    library: fixture.library,
                    jobStore: fixture.jobStore,
                    meetingID: fixture.meeting.id,
                    templateID: Template.meetingMinutes.id
                )
            }
            #expect(try await fixture.jobStore.list().isEmpty)
        }
    }

    @Test("text provider receives only the captured generation after trash and reimport")
    func textProviderUsesGenerationBoundSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedTemplateFixture(at: root)
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            let pause = TemplatePipelinePause()
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                textModelProviderResolver: { _ in provider },
                locale: Locale(identifier: "de-DE"),
                importedStateCheckpoint: { checkpoint in
                    guard checkpoint == .afterTextProviderInputCapture(job.id) else { return }
                    pause.arriveAndWait()
                }
            )
            await coordinator.start()
            try await eventually { pause.hasArrived }

            _ = try await fixture.library.trashMeeting(fixture.meeting.id)
            let replacementGeneration = MeetingTransferGenerationID()
            let replacementReceipt = MeetingTransferReceipt(
                sourceMeetingID: fixture.meeting.id,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "8", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 800),
                sourceAppVersion: nil,
                includedCapabilities: [.transcript, .notes],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: replacementGeneration
            )
            let replacementMeeting = Meeting(
                id: fixture.meeting.id,
                title: "Imported template B",
                status: .ready,
                metadata: MeetingMetadata(transferReceipt: replacementReceipt)
            )
            let replacementRevision = TranscriptRevision(
                meetingID: fixture.meeting.id,
                origin: .meetingTransfer(
                    sourceMeetingID: fixture.meeting.id,
                    sourceRevisionID: nil
                ),
                turns: [
                    TranscriptTurn(
                        speaker: .importedTextLabel(ImportedSpeakerTextLabel(
                            id: UUID(uuidString: "00000000-0000-4000-8000-000000000801")!,
                            text: "B",
                            wasConfirmedAtSource: true
                        )),
                        start: 0,
                        end: 1,
                        segments: [
                            TranscriptSegment(
                                text: "Private transcript B",
                                start: 0,
                                end: 1,
                                words: []
                            ),
                        ]
                    ),
                ]
            )
            _ = try await fixture.library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: replacementMeeting,
                media: [],
                revision: replacementRevision,
                transferState: .importedOnly
            ))
            try await MeetingNotesStore(layout: fixture.library.layout).setNotes(
                fixture.meeting.id,
                to: "Private notes B"
            )

            pause.release()
            try await coordinator.waitUntilIdle()

            let contexts = await provider.recordedContexts()
            let requests = await provider.recordedRequests()
            #expect(contexts.contains { $0.userNotes == "Private notes A" })
            #expect(!contexts.contains { $0.userNotes == "Private notes B" })
            #expect(requests.contains { request in
                guard case .map(let chunk) = request else { return false }
                return chunk.turns.contains {
                    $0.speakerName == "A" && $0.text == "Nur Generation A"
                }
            })
            #expect(!requests.contains { request in
                guard case .map(let chunk) = request else { return false }
                return chunk.turns.contains {
                    $0.speakerName == "B" || $0.text == "Private transcript B"
                }
            })
            #expect(try await fixture.jobStore.load(job.id).status == .cancelled)
            #expect(try await fixture.library.loadMeeting(fixture.meeting.id).status == .ready)
            #expect(try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == replacementRevision)
            #expect(try await MeetingNotesStore(layout: fixture.library.layout)
                .notes(fixture.meeting.id) == "Private notes B")
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id).isEmpty)
            await coordinator.stop()
        }
    }

    @Test("enqueue pins the selected endpoint together with the current revision")
    func enqueuePinsSelectedEndpoint() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)

            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID
            )

            let persisted = try await fixture.jobStore.load(job.id)
            #expect(persisted.revisionID == fixture.revision.id)
            #expect(persisted.textModelEndpointID == fixtureTextModelEndpointID)
            #expect(persisted.schemaVersion == 1)
        }
    }

    @Test("render sends only the disclosed transcript, participant, and note fields")
    func renderSendsOnlyDisclosedFields() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root, withConfirmedPerson: true)
            var confirmed = try #require(
                try await IdentityStore(layout: fixture.library.layout)
                    .listPersons()
                    .first
            )
            confirmed.organization = "ORGANIZATION_SENTINEL"
            confirmed.email = "EMAIL_SENTINEL@example.com"
            let additional = Person(displayName: "PARTICIPANT_SENTINEL")
            try await IdentityStore(layout: fixture.library.layout).replacePersons([
                confirmed,
                additional,
            ])
            _ = try await fixture.library.updateAdditionalMeetingParticipants(
                fixture.meeting.id,
                participantIDs: [additional.id]
            )
            let speaker = try #require(fixture.revision.turns.first?.speaker)
            _ = try await fixture.library.appendRevision(TranscriptRevision(
                meetingID: fixture.meeting.id,
                origin: .userEdit(fixture.revision.id),
                turns: [
                    TranscriptTurn(
                        speaker: speaker,
                        start: 0,
                        end: 1,
                        segments: [
                            TranscriptSegment(
                                text: "TRANSCRIPT_SENTINEL",
                                start: 0,
                                end: 1,
                                words: []
                            ),
                        ]
                    ),
                ]
            ))
            try await MeetingNotesStore(layout: fixture.library.layout).setNotes(
                fixture.meeting.id,
                to: "NOTES_SENTINEL"
            )
            let disclosure = try await TemplateRenderInputAssembler.preflight(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).disclosure
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            _ = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()
            await coordinator.stop()

            let seenPayload = await provider.recordedPayload()
            #expect(seenPayload.contains("TRANSCRIPT_SENTINEL"))
            #expect(seenPayload.contains("PARTICIPANT_SENTINEL"))
            #expect(seenPayload.contains("ORGANIZATION_SENTINEL"))
            #expect(seenPayload.contains("NOTES_SENTINEL"))
            #expect(!seenPayload.contains("EMAIL_SENTINEL"))
            #expect(!seenPayload.contains("AUDIO_SENTINEL"))
            #expect(disclosure.classes == [
                .transcriptWithSpeakerNames,
                .participants,
                .userNotes,
            ])
        }
    }

    @Test("a pinned endpoint selects its provider and records its engine")
    func pinnedEndpointSelectsProviderAndEngine() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let descriptor = EngineDescriptor(
                name: "Lokales Gemma",
                version: "openai-compat",
                modelVersion: "gemma-3"
            )
            let provider = FakePipelineTextModelProvider(
                behavior: .succeed,
                descriptor: descriptor
            )
            let resolver = ResolverRecorder { selection in
                guard selection.endpointID == fixtureTextModelEndpointID else {
                    throw FakeTextModelResolverError.unknownEndpoint
                }
                return provider
            }
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProviderResolver: resolver.resolve
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let run = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .templateRender })
            let artifact = try JSONDecoder().decode(
                TemplateRenderArtifact.self,
                from: Data(contentsOf: fixture.library.layout.runTemplate(
                    fixture.meeting.id,
                    runID: run.id
                ))
            )
            #expect(try await fixture.jobStore.load(job.id).status == .finished)
            #expect(resolver.requestedEndpointIDs == [fixtureTextModelEndpointID])
            #expect(run.engine == descriptor)
            #expect(artifact.result.engine == descriptor)
            await coordinator.stop()
        }
    }

    @Test("the operator name never reaches the model")
    func operatorNameNeverReachesTheModel() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            // Steht fuer das Betreiberprofil: derselbe Typ, der in den
            // Einstellungen die angezeigte Zeile bildet.
            let profile = OperatorIdentity(
                name: "Ada Lovelace",
                organization: "Stadt Musterstadt"
            )
            _ = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let contexts = await provider.recordedContexts()
            #expect(!contexts.isEmpty)
            // Kein Feld des Kontexts darf den Namen tragen. Die Teilnehmer
            // sind ausdruecklich mitgeprueft: dorthin gehoert er nur, wenn
            // der Nutzer sich selbst als Anwesenden eingetragen hat, und
            // das hat diese Fixture nicht getan.
            let name = try #require(profile.authorLine)
            for context in contexts {
                #expect(context.userNotes?.contains("Ada Lovelace") != true)
                #expect(!context.participants.contains { $0.contains("Ada Lovelace") })
            }
            // Ohne diese Zeile koennte der Test gruen sein, weil das Profil
            // leer war statt weil der Name unterdrueckt wurde.
            #expect(name == "Ada Lovelace, Stadt Musterstadt")
            await coordinator.stop()
        }
    }

    @Test("an unknown pinned endpoint fails without falling back")
    func unknownPinnedEndpointFailsWithoutFallback() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let resolver = ResolverRecorder { _ in
                throw PipelineError.unknownTextModelEndpoint(fixtureTextModelEndpointID)
            }
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProviderResolver: resolver.resolve
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let failed = try await fixture.jobStore.load(job.id)
            #expect(failed.status == .failed)
            #expect(
                failed.errorMessage
                    == "Der ausgewählte Textmodell-Endpunkt ist nicht mehr verfügbar."
            )
            #expect(resolver.requestedEndpointIDs == [fixtureTextModelEndpointID])
            #expect(try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id).isEmpty)
            await coordinator.stop()
        }
    }

    @Test(
        "legacy external jobs fail before resolver provider or URL request",
        arguments: LegacyExternalJobCase.all
    )
    func legacyExternalJobFailsClosed(testCase: LegacyExternalJobCase) async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let endpointID = UUID()
            let revision = testCase.hasSnapshotRevision ? UUID() : nil
            let snapshot = testCase.hasSnapshot
                ? TextModelEndpointSnapshot(
                    id: testCase.snapshotMatchesEndpoint ? endpointID : UUID(),
                    name: "Previously disclosed endpoint",
                    baseURL: URL(string: "https://old.example.test/v1")!,
                    modelID: "old-model",
                    requiresAPIKey: true,
                    configurationRevision: revision
                )
                : nil
            let job = Job(
                schemaVersion: 1,
                kind: .templateRender,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                revisionID: fixture.revision.id,
                textModelEndpointID: endpointID.uuidString,
                textModelEndpointSnapshot: snapshot,
                templateRenderInputFingerprint: testCase.hasFingerprint
                    ? "sha256:" + String(repeating: "a", count: 64)
                    : nil,
                status: testCase.status
            )
            try await fixture.jobStore.enqueue(job)
            try await MeetingNotesStore(layout: fixture.library.layout).setNotes(
                fixture.meeting.id,
                to: "Notes changed after this legacy job was persisted"
            )
            let execution = LegacyExternalExecutionRecorder()

            let runtime = try await startPipeline(
                at: root,
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                textModelProviderResolver: execution.resolve,
                locale: Locale(identifier: "de-DE")
            )
            try await runtime.coordinator.waitUntilIdle()

            let failed = try await runtime.jobStore.load(job.id)
            #expect(failed.status == .failed)
            #expect(failed.failureReason == .templateRenderPinsRequired)
            #expect(
                failed.errorMessage
                    == PipelineError.templateRenderPinsRequired.localizedDescription
            )
            #expect(execution.resolverCallCount == 0)
            #expect(execution.providerCallCount == 0)
            #expect(execution.urlRequestCount == 0)
            #expect(try TemplateResultStore(layout: runtime.library.layout)
                .list(meetingID: fixture.meeting.id).isEmpty)
            await runtime.coordinator.stop()
        }
    }

    @Test("the default resolver rejects a pinned endpoint instead of falling back")
    func defaultResolverRejectsPinnedEndpoint() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID
            )
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let failed = try await fixture.jobStore.load(job.id)
            #expect(failed.status == .failed)
            #expect(
                failed.errorMessage
                    == "Der ausgewählte Textmodell-Endpunkt ist nicht mehr verfügbar."
            )
            await coordinator.stop()
        }
    }

    @Test("a job without endpoint keeps using the Foundation Models route")
    func nilEndpointUsesDefaultRoute() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            let resolver = ResolverRecorder { selection in
                guard selection.endpointID == nil else {
                    throw FakeTextModelResolverError.unknownEndpoint
                }
                return provider
            }
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProviderResolver: resolver.resolve
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.load(job.id).status == .finished)
            #expect(resolver.requestedEndpointIDs == [nil])
            #expect(await provider.callCount() > 0)
            await coordinator.stop()
        }
    }

    @Test("explicit render stores an attributable report using confirmed review names")
    func successfulRenderStoresListableReport() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root, withConfirmedPerson: true)
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let newerRevision = TranscriptRevision(
                meetingID: fixture.meeting.id,
                origin: .liveProvisional,
                turns: []
            )
            _ = try await fixture.library.appendRevision(newerRevision)
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let finished = try await fixture.jobStore.load(job.id)
            let runID = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .templateRender }).id
            let artifact = try JSONDecoder().decode(
                TemplateRenderArtifact.self,
                from: Data(contentsOf: fixture.library.layout.runTemplate(
                    fixture.meeting.id,
                    runID: runID
                ))
            )
            let reports = try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id)

            #expect(finished.status == .finished)
            #expect(finished.templateID == Template.meetingMinutes.id)
            #expect(finished.revisionID == fixture.revision.id)
            #expect(artifact.jobID == job.id)
            #expect(artifact.result.revisionID == fixture.revision.id)
            #expect(artifact.result.markdown.contains("Ada Lovelace"))
            #expect(reports.count == 1)
            #expect(reports.first?.runID == runID)
            #expect(reports.first?.result == artifact.result)
            #expect(try await fixture.jobStore.list().map(\.kind) == [.templateRender])
            await coordinator.stop()
        }
    }

    @Test("a corrupt report is quarantined and restored from its committed run")
    func corruptReportIsRecovered() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let runID = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .templateRender }).id
            try AtomicFile.write(
                Data("not json".utf8),
                to: fixture.library.layout.report(fixture.meeting.id, runID: runID)
            )

            let reports = try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id)
            let entries = try FileManager.default.contentsOfDirectory(
                at: fixture.library.layout.reportsDirectory(fixture.meeting.id),
                includingPropertiesForKeys: nil
            )
            #expect(reports.count == 1)
            #expect(reports.first?.runID == runID)
            #expect(entries.contains {
                $0.lastPathComponent.hasPrefix("\(runID).json.corrupt-")
            })
            #expect(try await fixture.jobStore.load(job.id).status == .finished)
            await coordinator.stop()
        }
    }

    @Test("unavailable model fails with its availability message and preserves the meeting")
    func unavailableModelFailsSafely() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let provider = FakePipelineTextModelProvider(
                behavior: .succeed,
                availability: .unavailable(.appleIntelligenceNotEnabled)
            )
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let failed = try await fixture.jobStore.load(job.id)
            let meeting = try await fixture.library.loadMeeting(fixture.meeting.id)
            #expect(failed.status == .failed)
            #expect(failed.errorMessage == "Apple Intelligence ist nicht aktiviert.")
            #expect(meeting.status == .ready)
            #expect(try await fixture.library.listMediaAssets(
                meetingID: fixture.meeting.id
            ).count == 1)
            #expect(await provider.callCount() == 0)
            #expect(try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id).isEmpty)
            await coordinator.stop()
        }
    }

    @Test("restart publishes a committed render without invoking the model twice")
    func committedRenderReplayIsIdempotent() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let blockingProvider = FakePipelineTextModelProvider(behavior: .block)
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id,
                textModelEndpointID: fixtureTextModelEndpointID
            )
            let first = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: blockingProvider
            )
            await first.start()
            try await eventually {
                let status = try await fixture.jobStore.load(job.id).status
                let callCount = await blockingProvider.callCount()
                return status == .running && callCount == 1
            }
            await first.stop()

            #expect(try await fixture.jobStore.load(job.id).status == .running)
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 1)

            let resumedProvider = FakePipelineTextModelProvider(behavior: .succeed)
            let resumed = try await startPipeline(
                at: root,
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                textModelProviderResolver: { _ in resumedProvider },
                locale: Locale(identifier: "de-DE")
            )
            try await resumed.coordinator.waitUntilIdle()
            let resumedJob = try await resumed.jobStore.load(job.id)
            #expect(resumedJob.status == .finished)
            #expect(resumedJob.attemptCount == 2)
            #expect(try TemplateResultStore(layout: resumed.library.layout)
                .list(meetingID: fixture.meeting.id).count == 1)
            await resumed.coordinator.stop()

            let runID = try #require(processingRuns(
                library: resumed.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .templateRender }).id
            try FileManager.default.removeItem(
                at: resumed.library.layout.report(fixture.meeting.id, runID: runID)
            )
            try overwriteJob(
                resumedJob,
                status: .running,
                layout: resumed.library.layout
            )

            let replayResolver = ResolverRecorder { _ in
                throw FakeTextModelResolverError.unknownEndpoint
            }
            let runtime = try await startPipeline(
                at: root,
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                textModelProviderResolver: replayResolver.resolve,
                locale: Locale(identifier: "de-DE")
            )
            try await runtime.coordinator.waitUntilIdle()

            let reports = try TemplateResultStore(layout: runtime.library.layout)
                .list(meetingID: fixture.meeting.id)
            #expect(try await runtime.jobStore.load(job.id).status == .finished)
            #expect(replayResolver.requestedEndpointIDs.isEmpty)
            #expect(reports.count == 1)
            #expect(reports.first?.runID == runID)
            await runtime.coordinator.stop()
        }
    }

    @Test("cancelling a running report leaves meeting lifecycle status untouched")
    func cancellationCleansUp() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let provider = FakePipelineTextModelProvider(behavior: .block)
            let job = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )
            await coordinator.start()
            try await eventually {
                let status = try await fixture.jobStore.load(job.id).status
                let callCount = await provider.callCount()
                return status == .running && callCount == 1
            }
            _ = try await fixture.library.updateMeetingStatus(
                fixture.meeting.id,
                to: .processing
            )

            try await coordinator.cancel(jobID: job.id)
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.load(job.id).status == .cancelled)
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id).isEmpty)
            #expect(
                try await fixture.library.loadMeeting(fixture.meeting.id).status == .processing
            )
            #expect(try await fixture.library.listMediaAssets(
                meetingID: fixture.meeting.id
            ).count == 1)
            await coordinator.stop()
        }
    }

    @Test("repeated explicit renders remain side by side with newest first")
    func multipleResultsRemainSideBySide() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeTemplateFixture(at: root)
            let provider = FakePipelineTextModelProvider(behavior: .succeed)
            let firstJob = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            let coordinator = makeTemplateCoordinator(
                fixture: fixture,
                textModelProvider: provider
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()
            await coordinator.stop()

            try await Task.sleep(for: .milliseconds(10))
            let secondJob = try await enqueueTemplateRequest(
                library: fixture.library,
                jobStore: fixture.jobStore,
                meetingID: fixture.meeting.id,
                templateID: Template.meetingMinutes.id
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let reports = try TemplateResultStore(layout: fixture.library.layout)
                .list(meetingID: fixture.meeting.id)
            #expect(reports[0].result.createdAt > reports[1].result.createdAt)
            #expect(Set(reports.map(\.runID)).count == 2)
            #expect(try await fixture.jobStore.list().count == 2)
            #expect(try await fixture.jobStore.load(firstJob.id).status == .finished)
            #expect(try await fixture.jobStore.load(secondJob.id).status == .finished)
            await coordinator.stop()
        }
    }
}

private struct TemplatePipelineFixture {
    let library: Library
    let jobStore: JobStore
    let meeting: Meeting
    let revision: TranscriptRevision
}

private let fixtureTextModelEndpointID =
    "00000000-0000-4000-8000-000000000901"

private func enqueueTemplateRequest(
    library: Library,
    jobStore: JobStore,
    meetingID: MeetingID,
    templateID: String,
    textModelEndpointID: String? = nil,
    textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
    preflight: TemplateRenderPreflight? = nil
) async throws -> Job {
    let visiblePreflight: TemplateRenderPreflight
    if let preflight {
        visiblePreflight = preflight
    } else {
        visiblePreflight = try await TemplateRenderInputAssembler.preflight(
            library: library,
            meetingID: meetingID
        )
    }
    let endpointSnapshot = textModelEndpointSnapshot ?? textModelEndpointID.map {
        TextModelEndpointSnapshot(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000901")!,
            name: $0,
            baseURL: URL(string: "https://pipeline-fixture.example.test/v1")!,
            modelID: "pipeline-fixture",
            requiresAPIKey: false,
            configurationRevision: UUID(
                uuidString: "00000000-0000-4000-8000-000000000902"
            )!
        )
    }
    return try await TemplateRenderRequest.enqueue(
        library: library,
        jobStore: jobStore,
        meetingID: meetingID,
        templateID: templateID,
        textModelEndpointID: textModelEndpointID,
        textModelEndpointSnapshot: endpointSnapshot,
        preflight: visiblePreflight
    )
}

private func makeTemplateFixture(
    at root: URL,
    withConfirmedPerson: Bool = false
) async throws -> TemplatePipelineFixture {
    let library = try Library.open(at: root)
    let meeting = try await library.createMeeting(title: "Template", status: .ready)
    let source = root.appendingPathComponent("template-source.caf")
    try Data("audio".utf8).write(to: source)
    let asset = try await library.registerMediaAsset(
        for: meeting.id,
        sourceURL: source,
        kind: .imported,
        sampleRate: 48_000,
        duration: 2
    )

    let speaker: SpeakerReference
    if withConfirmedPerson {
        let diarizationRunID = RunID()
        let clusterID = "\(asset.id)/SPEAKER_0"
        try await seedConfirmedReview(
            library: library,
            meetingID: meeting.id,
            asset: asset,
            runID: diarizationRunID,
            clusterID: clusterID
        )
        speaker = .cluster(runID: diarizationRunID, clusterID: clusterID)
    } else {
        speaker = .channel("Andere")
    }
    let revision = TranscriptRevision(
        meetingID: meeting.id,
        origin: .liveProvisional,
        turns: [
            TranscriptTurn(
                speaker: speaker,
                start: 0,
                end: 1,
                segments: [
                    TranscriptSegment(
                        text: "Wir beschließen den nächsten Schritt.",
                        start: 0,
                        end: 1,
                        words: []
                    ),
                ]
            ),
        ]
    )
    _ = try await library.appendRevision(revision)
    return TemplatePipelineFixture(
        library: library,
        jobStore: try JobStore(layout: library.layout),
        meeting: meeting,
        revision: revision
    )
}

private func makeImportedTemplateFixture(
    at root: URL
) async throws -> TemplatePipelineFixture {
    let library = try Library.open(at: root)
    let meetingID = MeetingID()
    let generationID = MeetingTransferGenerationID()
    let receipt = MeetingTransferReceipt(
        sourceMeetingID: meetingID,
        sourceRevisionID: nil,
        sourcePackageContentDigest: String(repeating: "7", count: 64),
        importedAt: Date(timeIntervalSinceReferenceDate: 700),
        sourceAppVersion: nil,
        includedCapabilities: [.transcript, .notes],
        sourceLocaleIdentifier: "de-DE",
        sourceLocaleOrigin: .explicit,
        importGenerationID: generationID
    )
    let meeting = Meeting(
        id: meetingID,
        title: "Imported template A",
        status: .ready,
        metadata: MeetingMetadata(transferReceipt: receipt)
    )
    let revision = TranscriptRevision(
        meetingID: meetingID,
        origin: .meetingTransfer(
            sourceMeetingID: meetingID,
            sourceRevisionID: nil
        ),
        turns: [
            TranscriptTurn(
                speaker: .importedTextLabel(ImportedSpeakerTextLabel(
                    id: UUID(uuidString: "00000000-0000-4000-8000-000000000701")!,
                    text: "A",
                    wasConfirmedAtSource: true
                )),
                start: 0,
                end: 1,
                segments: [
                    TranscriptSegment(
                        text: "Nur Generation A",
                        start: 0,
                        end: 1,
                        words: []
                    ),
                ]
            ),
        ]
    )
    _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
        meeting: meeting,
        media: [],
        revision: revision,
        transferState: .importedOnly
    ))
    try await MeetingNotesStore(layout: library.layout).setNotes(
        meetingID,
        to: "Private notes A"
    )
    return TemplatePipelineFixture(
        library: library,
        jobStore: try JobStore(layout: library.layout),
        meeting: meeting,
        revision: revision
    )
}

private func seedConfirmedReview(
    library: Library,
    meetingID: MeetingID,
    asset: MediaAsset,
    runID: RunID,
    clusterID: String
) async throws {
    let person = Person(displayName: "Ada Lovelace")
    try await IdentityStore(layout: library.layout).replacePersons([person])
    let cluster = IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: asset.kind.rawValue,
        clusterID: clusterID,
        recordingType: .imported,
        embedding: [1, 0],
        speechDurationSeconds: 1,
        segmentCount: 1,
        reviewState: .confirmed(person.id)
    )
    let diarization = DiarizationArtifact(
        jobID: JobID(),
        sourceRunID: RunID(),
        revisionID: RevisionID(),
        tracks: [
            DiarizationTrackResult(
                assetID: asset.id,
                assetKind: asset.kind,
                engine: EngineDescriptor(name: "FakeDiarization", version: "1"),
                segments: [DiarizationRunSegment(clusterID: clusterID, start: 0, end: 1)],
                clusters: [
                    DiarizationClusterResult(
                        clusterID: clusterID,
                        embedding: [1, 0],
                        speechDurationSeconds: 1,
                        segmentCount: 1
                    ),
                ]
            ),
        ]
    )
    try writeFinishedRun(
        ProcessingRun(
            id: runID,
            meetingID: meetingID,
            kind: .diarization,
            engine: EngineDescriptor(name: "FakeDiarization", version: "1"),
            status: .finished
        ),
        artifact: diarization,
        artifactName: "diarization.json",
        layout: library.layout
    )
    let suggestionRunID = RunID()
    try writeFinishedRun(
        ProcessingRun(
            id: suggestionRunID,
            meetingID: meetingID,
            kind: .identitySuggestion,
            engine: EngineDescriptor(name: "FakeIdentity", version: "1"),
            status: .finished
        ),
        artifact: IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: runID,
            clusterResolutions: [
                IdentityClusterResolution(
                    channel: asset.kind.rawValue,
                    sourceClusterID: clusterID,
                    primaryClusterID: clusterID
                ),
            ],
            identityEvidenceFingerprint: "fixture",
            suggestions: []
        ),
        artifactName: "suggestions.json",
        layout: library.layout
    )
    try MeetingReviewStore(layout: library.layout).save(
        MeetingReviewDocument(runID: runID, clusters: [cluster]),
        meetingID: meetingID
    )
}

private func writeFinishedRun<Artifact: Encodable>(
    _ run: ProcessingRun,
    artifact: Artifact,
    artifactName: String,
    layout: LibraryLayout
) throws {
    let directory = layout.runDirectory(run.meetingID, runID: run.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try AtomicFile.write(
        encoder.encode(run),
        to: directory.appendingPathComponent("run.json")
    )
    try AtomicFile.write(
        encoder.encode(artifact),
        to: directory.appendingPathComponent(artifactName)
    )
}

private func makeTemplateCoordinator(
    fixture: TemplatePipelineFixture,
    textModelProvider: any TextModelProvider
) -> PipelineCoordinator {
    makeTemplateCoordinator(
        fixture: fixture,
        textModelProviderResolver: { _ in textModelProvider }
    )
}

private func makeTemplateCoordinator(
    fixture: TemplatePipelineFixture,
    textModelProviderResolver: @escaping TextModelProviderResolver
) -> PipelineCoordinator {
    PipelineCoordinator(
        library: fixture.library,
        jobStore: fixture.jobStore,
        providers: [:],
        diarizationProvider: FakeDiarizationProvider(behavior: .fail),
        textModelProviderResolver: textModelProviderResolver,
        locale: Locale(identifier: "de-DE")
    )
}

private enum FakePipelineTextModelError: Error {
    case failed
}

private final class TemplatePipelinePause: @unchecked Sendable {
    private let arrived = Mutex(false)
    private let resume = DispatchSemaphore(value: 0)

    var hasArrived: Bool { arrived.withLock { $0 } }

    func arriveAndWait() {
        arrived.withLock { $0 = true }
        resume.wait()
    }

    func release() {
        resume.signal()
    }
}

private enum FakeTextModelResolverError: Error {
    case unknownEndpoint
}

struct LegacyExternalJobCase: Sendable, CustomTestStringConvertible {
    let status: Job.Status
    let hasFingerprint: Bool
    let hasSnapshot: Bool
    let hasSnapshotRevision: Bool
    let snapshotMatchesEndpoint: Bool
    let testDescription: String

    init(
        status: Job.Status,
        hasFingerprint: Bool,
        hasSnapshot: Bool,
        hasSnapshotRevision: Bool,
        snapshotMatchesEndpoint: Bool = true,
        testDescription: String
    ) {
        self.status = status
        self.hasFingerprint = hasFingerprint
        self.hasSnapshot = hasSnapshot
        self.hasSnapshotRevision = hasSnapshotRevision
        self.snapshotMatchesEndpoint = snapshotMatchesEndpoint
        self.testDescription = testDescription
    }

    static let all: [Self] = [
        .init(
            status: .queued,
            hasFingerprint: true,
            hasSnapshot: true,
            hasSnapshotRevision: true,
            snapshotMatchesEndpoint: false,
            testDescription: "queued mismatched snapshot identity"
        ),
        .init(
            status: .queued,
            hasFingerprint: false,
            hasSnapshot: true,
            hasSnapshotRevision: true,
            testDescription: "queued missing fingerprint"
        ),
        .init(
            status: .queued,
            hasFingerprint: true,
            hasSnapshot: false,
            hasSnapshotRevision: false,
            testDescription: "queued missing snapshot"
        ),
        .init(
            status: .queued,
            hasFingerprint: true,
            hasSnapshot: true,
            hasSnapshotRevision: false,
            testDescription: "queued missing snapshot revision"
        ),
        .init(
            status: .queued,
            hasFingerprint: false,
            hasSnapshot: false,
            hasSnapshotRevision: false,
            testDescription: "queued missing both pins"
        ),
        .init(
            status: .running,
            hasFingerprint: true,
            hasSnapshot: true,
            hasSnapshotRevision: true,
            snapshotMatchesEndpoint: false,
            testDescription: "recovered running mismatched snapshot identity"
        ),
        .init(
            status: .running,
            hasFingerprint: false,
            hasSnapshot: true,
            hasSnapshotRevision: true,
            testDescription: "recovered running missing fingerprint"
        ),
        .init(
            status: .running,
            hasFingerprint: true,
            hasSnapshot: false,
            hasSnapshotRevision: false,
            testDescription: "recovered running missing snapshot"
        ),
        .init(
            status: .running,
            hasFingerprint: true,
            hasSnapshot: true,
            hasSnapshotRevision: false,
            testDescription: "recovered running missing snapshot revision"
        ),
        .init(
            status: .running,
            hasFingerprint: false,
            hasSnapshot: false,
            hasSnapshotRevision: false,
            testDescription: "recovered running missing both pins"
        ),
    ]
}

private final class LegacyExternalExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var resolverCalls = 0
    private var providerCalls = 0
    private var urlRequests = 0

    var resolverCallCount: Int { lock.withLock { resolverCalls } }
    var providerCallCount: Int { lock.withLock { providerCalls } }
    var urlRequestCount: Int { lock.withLock { urlRequests } }

    func resolve(_ selection: TextModelProviderSelection) throws -> any TextModelProvider {
        lock.withLock { resolverCalls += 1 }
        return LegacyExternalCountingProvider(recorder: self)
    }

    func recordProviderAndURLRequest() {
        lock.withLock {
            providerCalls += 1
            urlRequests += 1
        }
    }
}

private struct LegacyExternalCountingProvider: TextModelProvider {
    let recorder: LegacyExternalExecutionRecorder
    let descriptor = EngineDescriptor(name: "MUST_NOT_RUN", version: "1")
    let availability = TextModelAvailability.available

    func render(
        template: Template,
        transcript: TranscriptRevision
    ) async throws -> TemplateResult {
        recorder.recordProviderAndURLRequest()
        return TemplateResult(
            markdown: "MUST_NOT_RUN",
            template: template,
            engine: descriptor,
            revisionID: transcript.id
        )
    }
}

private final class ResolverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSelections: [TextModelProviderSelection] = []
    private let implementation: TextModelProviderResolver

    init(
        implementation: @escaping TextModelProviderResolver
    ) {
        self.implementation = implementation
    }

    var requestedEndpointIDs: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storedSelections.map(\.endpointID)
    }

    func resolve(_ selection: TextModelProviderSelection) throws -> any TextModelProvider {
        lock.lock()
        storedSelections.append(selection)
        lock.unlock()
        return try implementation(selection)
    }
}

private actor FakePipelineTextModelProvider: StructuredTextModelProvider {
    enum Behavior: Sendable {
        case succeed
        case fail
        case block
    }

    nonisolated let descriptor: EngineDescriptor
    nonisolated let availability: TextModelAvailability

    private let behavior: Behavior
    private var requests: [TextModelRequest] = []
    private var contexts: [RenderContext] = []

    init(
        behavior: Behavior,
        descriptor: EngineDescriptor = EngineDescriptor(
            name: "FakeTextModel",
            version: "1",
            modelVersion: "fixture"
        ),
        availability: TextModelAvailability = .available
    ) {
        self.behavior = behavior
        self.descriptor = descriptor
        self.availability = availability
    }

    func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        contexts.append(context)
        requests.append(request)
        switch behavior {
        case .fail:
            throw FakePipelineTextModelError.failed
        case .block:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case .succeed:
            let input: String
            switch request {
            case .map(let chunk):
                input = chunk.turns.map { "\($0.speakerName): \($0.text)" }
                    .joined(separator: "\n")
            case .reduce(let outputs):
                input = outputs.flatMap(\.sections).map(\.markdown)
                    .joined(separator: "\n")
            }
            return StructuredTemplateOutput(
                sections: template.generatedSections.map {
                    StructuredTemplateSection(sectionID: $0.id, markdown: input)
                }
            )
        }
    }

    func callCount() -> Int {
        requests.count
    }

    func recordedContexts() -> [RenderContext] {
        contexts
    }

    func recordedRequests() -> [TextModelRequest] {
        requests
    }

    func recordedPayload() -> String {
        let requests = requests.map { request -> String in
            switch request {
            case .map(let chunk):
                chunk.turns.map { "\($0.speakerName): \($0.text)" }
                    .joined(separator: "\n")
            case .reduce(let outputs):
                outputs.flatMap(\.sections).map(\.markdown).joined(separator: "\n")
            }
        }
        let contexts = contexts.flatMap { context in
            context.participants + [context.userNotes].compactMap { $0 }
        }
        return (requests + contexts).joined(separator: "\n")
    }
}
