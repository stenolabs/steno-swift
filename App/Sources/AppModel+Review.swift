import AVFAudio
import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import SwiftUI

enum SpeakerPlaybackAssetSelection {
    static func asset(
        from assets: [MediaAsset],
        channel: String
    ) -> MediaAsset? {
        if !channel.isEmpty {
            return assets.first { $0.kind.rawValue == channel }
        }
        guard assets.count == 1 else { return nil }
        return assets[0]
    }
}

private enum AppModelReportPreflightError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        "The library is not ready yet."
    }
}

extension AppModel {
    // MARK: - Sprecher-Review

    func loadReviewData(meetingID: MeetingID) async -> MeetingReviewData? {
        guard let runtime else { return nil }
        return try? await MeetingReviewAssembler.load(
            library: runtime.library,
            meetingID: meetingID
        )
    }

    // MARK: - Teilnehmer

    /// Alle bekannten Personen der Bibliothek, für die Teilnehmer-Auswahl.
    func allPersons() async -> [Person] {
        guard let runtime else { return [] }
        let layout = await runtime.library.layout
        let persons = (try? await IdentityStore(layout: layout).listPersons()) ?? []
        return persons.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// Kontaktadresse pflegen. Leere Eingabe loescht sie; eine offensichtlich
    /// kaputte wird abgelehnt, statt sie zu speichern und beim Versand zu
    /// scheitern.
    @discardableResult
    func setPersonEmail(_ personID: PersonID, to email: String?) async -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        do {
            try await IdentityStore(layout: layout).setPersonEmail(personID, to: email)
            return true
        } catch LibraryError.invalidPersonEmail {
            report("That is not a valid e-mail address.")
            return false
        } catch {
            report(AppModel.message("The e-mail address could not be saved.", error))
            return false
        }
    }

    @discardableResult
    func setPersonOrganization(_ personID: PersonID, to organization: String?) async -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        do {
            try await IdentityStore(layout: layout)
                .setPersonOrganization(personID, to: organization)
            return true
        } catch {
            report(AppModel.message("The organization could not be saved.", error))
            return false
        }
    }

    func meeting(_ meetingID: MeetingID) async -> Meeting? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadMeeting(meetingID)
    }

    // MARK: - Notizen

    func notesSession(for meetingID: MeetingID) async -> MeetingNotesEditingSession? {
        if let session = notesSessions[meetingID] {
            await session.load()
            return session
        }
        guard let runtime else { return nil }
        let store = MeetingNotesStore(layout: runtime.library.layout)
        let session = MeetingNotesEditingSession(meetingID: meetingID, store: store)
        notesSessions[meetingID] = session
        await session.load()
        return session
    }

    func notes(for meetingID: MeetingID) async -> String {
        await notesSession(for: meetingID)?.text ?? ""
    }

    /// Haelt die laufende Aufnahmezeit in der Notiz fest. Der haeufigste
    /// Impuls im Gespraech ist nicht "ich will etwas notieren", sondern "das
    /// eben war wichtig" - dafuer ist selbst ein Stichwort zu teuer.
    ///
    /// Bewusst in der Notizdatei statt in einem eigenen Datenmodell: So
    /// fliesst die Marke ohne Zutun in den Protokoll-Prompt, und sie
    /// ueberlebt jeden Neulauf der Erkennung.
    func markMoment() async {
        guard isRecording,
              let meetingID = recordingMeetingID,
              let start = recordingStartedAt
        else { return }
        guard let session = await notesSession(for: meetingID) else { return }
        await session.appendMarker(elapsed: Date().timeIntervalSince(start))
        if let error = session.errorMessage {
            report("The marker could not be saved. (\(error))")
        } else {
            report("Moment marked.", isError: false)
        }
    }

    /// Ein Meeting ohne Aufnahme, um vor dem Termin Notizen zu schreiben.
    /// Es zaehlt bewusst nicht als gestrandete Aufnahme.
    @discardableResult
    func createDraftMeeting() async -> MeetingID? {
        guard let runtime else { return nil }
        do {
            let meeting = try await runtime.library.createMeeting(
                title: Self.draftTitle(),
                status: .draft
            )
            await refreshMeetings()
            selectedMeetingID = meeting.id
            return meeting.id
        } catch {
            report(AppModel.message("The draft could not be created.", error))
            return nil
        }
    }

    private static func draftTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Notes \(formatter.string(from: Date()))"
    }

    /// Ergänzt eine Person als Anwesende ohne Redebeitrag. `name` legt bei
    /// Bedarf eine neue Person an, damit stille Teilnehmer nicht erst über
    /// die Sprecherprüfung entstehen müssen.
    func addAdditionalParticipant(
        _ personID: PersonID?,
        name: String?,
        meetingID: MeetingID
    ) async {
        guard let runtime else { return }
        do {
            reviewError = nil
            let layout = await runtime.library.layout
            let store = try IdentityStore(layout: layout)
            let resolvedID: PersonID
            if let personID {
                resolvedID = personID
            } else {
                let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                resolvedID = try await store.createPerson(displayName: trimmed).id
            }
            let meeting = try await runtime.library.loadMeeting(meetingID)
            guard !meeting.participantIDs.contains(resolvedID),
                  !meeting.additionalParticipantIDs.contains(resolvedID)
            else { return }
            try await runtime.library.updateAdditionalMeetingParticipants(
                meetingID,
                participantIDs: meeting.additionalParticipantIDs + [resolvedID]
            )
        } catch let LibraryError.duplicatePersonName(name) {
            reviewError = "A person named \(name) already exists."
        } catch {
            reviewError = AppModel.message("The participant could not be added.", error)
        }
    }

    func removeAdditionalParticipant(
        _ personID: PersonID,
        meetingID: MeetingID
    ) async {
        guard let runtime else { return }
        do {
            let meeting = try await runtime.library.loadMeeting(meetingID)
            try await runtime.library.updateAdditionalMeetingParticipants(
                meetingID,
                participantIDs: meeting.additionalParticipantIDs.filter { $0 != personID }
            )
        } catch {
            reviewError = AppModel.message("The participant could not be removed.", error)
        }
    }

    func performReview(
        _ action: MeetingReviewController.Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData,
        meetingID: MeetingID
    ) async -> MeetingReviewData? {
        guard let runtime else { return nil }
        do {
            reviewError = nil
            return try await MeetingReviewController(library: runtime.library)
                .perform(action, on: cluster, data: data, meetingID: meetingID)
        } catch MeetingReviewController.ReviewActionError.stale {
            reviewError = "The review state belongs to a superseded run; the view has been reloaded."
            return await loadReviewData(meetingID: meetingID)
        } catch let LibraryError.duplicatePersonName(name) {
            reviewError = "A person named \(name) already exists."
            return nil
        } catch let error as IdentityReviewError {
            reviewError = Self.message(for: error)
            return nil
        } catch {
            reviewError = "Assigning the speaker failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Rohe Fehlernamen gehören nicht in die Oberfläche.
    private static func message(for error: IdentityReviewError) -> String {
        switch error {
        case .clusterNotFound:
            "This speaker belongs to a superseded run. Please reload the view."
        case .personNotFound:
            "The selected person no longer exists."
        case .mixedClusterCannotBeNamed:
            "This section is marked as \u{201C}multiple people\u{201D} and cannot be assigned to one person."
        case .selfClusterCannotBeNamed:
            "Your own microphone track is not named as a person."
        case .noAssignmentToReassign:
            "There is no assignment here that could be changed."
        }
    }

    // MARK: - Hörproben

    /// Spielt einen Ausschnitt der Originalspur ab (Toggle). Text und Audio
    /// stammen aus demselben Turn; abgespielt wird direkt aus dem
    /// unveränderten Original, nichts wird extrahiert oder kopiert.
    func toggleSample(_ sample: SpeakerSample, meetingID: MeetingID) async {
        if playingSampleID == sample.id {
            stopSamplePlayback()
            return
        }
        stopSamplePlayback()
        guard !isRecordingSoDoNotPlay else { return }
        guard let runtime else { return }
        do {
            let assets = try await runtime.library.listMediaAssets(meetingID: meetingID)
            guard let asset = SpeakerPlaybackAssetSelection.asset(
                from: assets,
                channel: sample.channel
            ) else {
                reviewError = "No original track found for the voice sample."
                return
            }
            let url = await runtime.library.layout.mediaFile(
                meetingID,
                fileName: asset.fileName
            )
            // Der Ausschnitt wird herausgelesen und als eigene Datei
            // abgespielt. Zwei Gruende: AVAudioPlayer kann in Opus-in-CAF
            // nicht springen (gemessen), und AVAudioEngine fasst auf macOS die
            // Eingangsseite an, was eine Mikrofon-Abfrage ausloest - fuer
            // reines Abspielen inakzeptabel.
            let clipURL = try Self.extractClip(
                from: url,
                start: sample.clipStart,
                // Nulllange Turns (Altimporte) bekommen eine hoerbare Mindestlaenge.
                duration: max(0.5, sample.duration)
            )
            let player = try AVAudioPlayer(contentsOf: clipURL)
            guard player.play() else {
                try? FileManager.default.removeItem(at: clipURL)
                reviewError = "Playback could not be started."
                return
            }
            samplePlayer = player
            sampleClipURL = clipURL
            setPlayingSample(sample.id)
            samplePlaybackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.2))
                guard !Task.isCancelled else { return }
                self?.stopSamplePlayback()
            }
        } catch {
            reviewError = "Playback failed: \(error.localizedDescription)"
        }
    }

    /// Beendet jede laufende Hoerprobe, gleich aus welcher Ansicht sie
    /// gestartet wurde. Es gibt genau einen Abspieler.
    /// Waehrend einer Aufnahme wird nichts abgespielt.
    ///
    /// Der Systemaudio-Tap nimmt auf, was der Mac ausgibt - eine Hoerprobe
    /// landete also mitten in der laufenden Aufnahme, mit der Stimme eines
    /// anderen Meetings. Das faellt frueh niemandem auf und ist hinterher
    /// nicht mehr herauszurechnen. Seit die Aufnahme die App nicht mehr
    /// sperrt, ist das ein erreichbarer Zustand und muss hier zu bleiben.
    var isRecordingSoDoNotPlay: Bool {
        guard isRecording else { return false }
        report(
            "Playback is off while recording: it would be captured into the recording.",
            isError: false
        )
        return true
    }

    func stopSamplePlayback() {
        samplePlaybackTask?.cancel()
        samplePlaybackTask = nil
        samplePlayer?.stop()
        samplePlayer = nil
        if let sampleClipURL {
            try? FileManager.default.removeItem(at: sampleClipURL)
        }
        sampleClipURL = nil
        setPlayingSample(nil)
        setPlayingPersonSample(nil)
    }

    /// Liest den Bereich framegenau aus dem Original und schreibt ihn als
    /// unkomprimierte Kopie in den Temp-Ordner. Das Original bleibt
    /// unangetastet; die Kopie verschwindet mit dem Ende der Wiedergabe.
    nonisolated static func extractClip(
        from url: URL,
        start: TimeInterval,
        duration: TimeInterval
    ) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(max(0, start) * format.sampleRate)
        guard startFrame < file.length else {
            throw SamplePlaybackError.clipBeyondEnd
        }
        let wanted = AVAudioFramePosition(duration * format.sampleRate)
        let frameCount = AVAudioFrameCount(min(wanted, file.length - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: frameCount
              )
        else {
            throw SamplePlaybackError.clipBeyondEnd
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-sample-\(UUID().uuidString).caf")
        let output = try AVAudioFile(
            forWriting: clipURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try output.write(from: buffer)
        return clipURL
    }

    enum SamplePlaybackError: Error {
        case clipBeyondEnd
    }

    /// Stößt die Sprechererkennung nachträglich an (Meetings von vor der
    /// Diarisierungs-Pipeline oder erneuter Lauf nach Modellwechsel).
    func requestDiarization(meetingID: MeetingID) async -> Bool {
        guard let runtime else { return false }
        do {
            let jobs = try await runtime.jobStore.list().filter {
                $0.meetingID == meetingID
            }
            guard !SpeakerProcessingJobSelection.hasActiveJob(in: jobs) else {
                return false
            }
            if try await DiarizationRequest.enqueueMissingIdentitySuggestion(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID
            ) {
                return true
            }
            if try await DiarizationRequest.enqueue(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID
            ) {
                return true
            }
            if let retry = SpeakerProcessingJobSelection.retryJob(in: jobs) {
                return try await runtime.jobStore.enqueueIfNoEquivalentJob(
                    retry,
                    blockingStatuses: [.queued, .running]
                )
            }
            // Importierte Alt-Meetings haben keinen eigenen ASR-Lauf: Ihr
            // Transkript stammt aus der alten App. Die Sprechererkennung
            // braucht aber einen Lauf mit Wortzeitstempeln als Grundlage,
            // deshalb wird hier zuerst neu transkribiert; die Kette
            // finalASR -> Diarisierung -> Vorschläge läuft dann von selbst.
            guard await hasPlayableAudio(meetingID),
                  try await !hasFinalASRRun(meetingID)
            else { return false }
            return try await runtime.jobStore.enqueueIfNoEquivalentJob(
                Job(kind: .finalASR, meetingID: meetingID),
                blockingStatuses: [.queued, .running]
            )
        } catch {
            reviewError = AppModel.message("Speaker recognition could not be started.", error)
            return false
        }
    }

    /// Transkribiert ein Meeting neu. Die Kette finalASR -> Diarisierung ->
    /// Vorschlaege laeuft danach von selbst.
    ///
    /// Das bisherige Transkript wird nicht ueberschrieben: jeder Lauf schreibt
    /// eine neue Revision, die alten bleiben stehen. Was der Lauf sehr wohl
    /// entwertet, ist die Sprecher-Zuordnung - eine neue Diarisierung vergibt
    /// die Cluster-Kennungen neu, und Bestaetigungen gegen den alten Lauf
    /// gelten danach nicht mehr. Deshalb sagt der Aufrufer das vorher.
    func requestRetranscription(meetingID: MeetingID) async -> Bool {
        guard let runtime else { return false }
        do {
            try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
                library: runtime.library,
                meetingID: meetingID
            )
            guard await hasPlayableAudio(meetingID) else {
                report("This meeting has no original audio to transcribe again.")
                return false
            }
            let pending = try await runtime.jobStore.list().contains {
                $0.meetingID == meetingID
                    && $0.kind == .finalASR
                    && ($0.status == .queued || $0.status == .running)
            }
            guard !pending else {
                report("A transcription for this meeting is already running.", isError: false)
                return false
            }
            try await runtime.jobStore.enqueue(
                Job(kind: .finalASR, meetingID: meetingID)
            )
            report("Transcribing again. The previous transcript stays available.", isError: false)
            return true
        } catch {
            report(AppModel.message("Transcription could not be started.", error))
            return false
        }
    }

    /// Ein abgeschlossener finalASR-Lauf ist die Alignment-Grundlage der
    /// Diarisierung; ohne ihn muss zuerst transkribiert werden.
    func hasFinalASRRun(_ meetingID: MeetingID) async throws -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: layout.runsDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        for entry in entries {
            guard let data = try? Data(
                contentsOf: entry.appendingPathComponent("run.json")
            ),
                let run = try? decoder.decode(ProcessingRun.self, from: data)
            else { continue }
            if run.kind == .finalASR, run.status == .finished { return true }
        }
        return false
    }

    // MARK: - Protokolle

    func reportPreflight(
        for meetingID: MeetingID
    ) async throws -> TemplateRenderPreflight {
        guard let runtime else {
            throw AppModelReportPreflightError.runtimeUnavailable
        }
        return try await TemplateRenderInputAssembler.preflight(
            library: runtime.library,
            meetingID: meetingID
        )
    }

    func reports(for meetingID: MeetingID) async -> [StoredTemplateResult] {
        guard let runtime else { return [] }
        let layout = await runtime.library.layout
        return (try? TemplateResultStore(layout: layout)
            .list(meetingID: meetingID)) ?? []
    }

    /// Liefert den eingereihten Render samt sichtbarem Endpunkt-Snapshot,
    /// damit die UI Erfolg, Fehler und Offenlegung demselben Lauf zuordnet.
    func requestMeetingMinutes(
        meetingID: MeetingID,
        textModelEndpointID: String? = nil,
        textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
        preflight: TemplateRenderPreflight
    ) async throws -> Job {
        guard let runtime else {
            throw AppModelReportPreflightError.runtimeUnavailable
        }
        let job = try await TemplateRenderRequest.enqueue(
            library: runtime.library,
            jobStore: runtime.jobStore,
            meetingID: meetingID,
            templateID: Template.meetingMinutes.id,
            textModelEndpointID: textModelEndpointID,
            textModelEndpointSnapshot: textModelEndpointSnapshot,
            preflight: preflight
        )
        return job
    }

    /// Bricht einen eingereihten oder laufenden Job ab. In der Commit-Phase
    /// lehnt die Pipeline das bewusst ab: Ein halb geschriebenes Ergebnis
    /// waere schlimmer als ein Lauf, der noch zu Ende geht.
    func cancelJob(_ jobID: JobID) async {
        guard let runtime else { return }
        do {
            try await runtime.coordinator.cancel(jobID: jobID)
        } catch PipelineError.cancellationTooLate {
            report(
                "The run is already saving its result and can no longer be cancelled.",
                isError: false
            )
        } catch {
            report(AppModel.message("The run could not be cancelled.", error))
        }
    }

    // MARK: - Meeting verwalten

    func deleteMeeting(_ meetingID: MeetingID) async {
        guard let runtime else { return }
        do {
            let jobs = (try? await runtime.jobStore.list())?
                .filter { $0.meetingID == meetingID } ?? []
            for job in jobs where job.status == .queued || job.status == .running {
                try? await runtime.coordinator.cancel(jobID: job.id)
            }
            try await runtime.jobStore.removeJobs(meetingID: meetingID)
            try await runtime.library.trashMeeting(meetingID)
            if selectedMeetingID == meetingID { selectedMeetingID = nil }
            await refreshMeetings()
        } catch {
            // Loeschen wird aus dem Kontextmenue der Seitenleiste
            // ausgeloest; die Review-Sektion ist dann meist gar nicht sichtbar.
            report(AppModel.message("The meeting could not be moved to the trash.", error))
        }
    }

    func renameMeeting(_ meetingID: MeetingID, to title: String) async {
        guard let runtime else { return }
        do {
            _ = try await runtime.library.renameMeeting(meetingID, to: title)
            await refreshMeetings()
        } catch LibraryError.invalidMeetingTitle {
            report("The title must not be empty.")
        } catch {
            report(AppModel.message("Renaming failed.", error))
        }
    }
}
