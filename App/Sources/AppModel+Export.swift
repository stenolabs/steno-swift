import AppKit
import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import UniformTypeIdentifiers

/// Markdown-Export eines Meetings.
///
/// Bisher kam man an ein Transkript nur ueber das Dateisystem heran. Der
/// Export nimmt alles mit, was ohne Raten zusammengehoert - Notiz, Berichte,
/// Transkript samt aufgeloesten Namen - und schreibt nichts in die Bibliothek.
@MainActor
extension AppModel {
    func performStereoAudioExport(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        meetingID: MeetingID,
        fileName: String
    ) async {
        guard audioExportActivity == nil else {
            report("Another audio export is already running.")
            return
        }
        let activity = AudioExportActivity(
            meetingID: meetingID,
            fileName: fileName,
            fraction: 0
        )
        audioExportActivity = activity
        defer {
            if audioExportActivity?.id == activity.id {
                audioExportActivity = nil
            }
        }

        do {
            try await stereoAudioExportPerformer(
                microphoneURL,
                systemURL,
                destinationURL
            ) { [weak self] update in
                guard let self,
                      let current = self.audioExportActivity,
                      current.id == activity.id
                else { return }
                self.audioExportActivity = current.withFraction(
                    max(current.fraction, update.fraction)
                )
            }
            try Task.checkCancellation()
            report("Saved \(fileName).", isError: false)
        } catch is CancellationError {
            return
        } catch {
            report(AppModel.message(
                "The stereo M4A could not be saved. The originals remain in Steno.",
                error
            ))
        }
    }

    func exportStereoAudio(
        microphone: MediaAsset,
        system: MediaAsset,
        of meetingID: MeetingID
    ) async {
        guard let runtime else { return }
        guard let meeting = await meeting(meetingID) else {
            report("This meeting no longer exists.")
            return
        }
        let layout = await runtime.library.layout
        let microphoneURL = layout.mediaFile(
            meetingID,
            fileName: microphone.fileName
        )
        let systemURL = layout.mediaFile(meetingID, fileName: system.fileName)
        guard FileManager.default.fileExists(atPath: microphoneURL.path),
              FileManager.default.fileExists(atPath: systemURL.path)
        else {
            report("One of the selected original tracks is no longer available.")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = AudioExportPresentation.stereoFileName(
            for: meeting
        )
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.message =
            "Microphone is left; system audio is right. The originals stay in Steno."
        guard await panel.begin() == .OK, let destinationURL = panel.url else {
            return
        }
        await performStereoAudioExport(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationURL: destinationURL,
            meetingID: meetingID,
            fileName: destinationURL.lastPathComponent
        )
    }

    /// Baut das Dokument. Getrennt vom Speichern, damit der Aufrufer den
    /// Ablageort erst erfragt, wenn es wirklich etwas zu speichern gibt.
    func exportMarkdown(for meetingID: MeetingID) async -> (name: String, text: String)? {
        guard let runtime else { return nil }
        guard let meeting = await meeting(meetingID) else {
            report("This meeting no longer exists.")
            return nil
        }
        let review = await loadReviewData(meetingID: meetingID)
        let revision = await transcript(for: meetingID)
        let notes = await notes(for: meetingID)
        let reports = await reports(for: meetingID).map(\.result)

        let persons = (try? await IdentityStore(layout: runtime.library.layout)
            .listPersons()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0) })

        var names: [SpeakerReference: String] = [:]
        for person in persons {
            names[.person(person.id)] = person.displayName
        }
        // Cluster bekommen ihren Namen nur, wenn er bestaetigt ist. Ein
        // Vorschlag ist kein Name, und in einem Dokument, das jemand
        // weitergibt, waere er nicht mehr als solcher erkennbar.
        for cluster in review?.clusters ?? [] {
            guard case .confirmed(let personID) = cluster.reviewState,
                  let person = byID[personID]
            else { continue }
            names[.cluster(runID: cluster.runID, clusterID: cluster.clusterID)] =
                person.displayName
            for fragment in cluster.mergedFrom {
                names[.cluster(runID: cluster.runID, clusterID: fragment)] =
                    person.displayName
            }
        }

        // Dieselbe Person kann in beiden Listen stehen (still ergaenzt, spaeter
        // als Sprecherin bestaetigt). In einem Dokument, das jemand
        // weitergibt, stuende ihr Name dann zweimal.
        var seen: Set<PersonID> = []
        let participants = (meeting.participantIDs + meeting.additionalParticipantIDs)
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0]?.displayName }

        let text = MeetingMarkdown.render(MeetingMarkdown.Input(
            meeting: meeting,
            revision: revision,
            authorLine: OperatorProfile.shared.authorLine,
            speakerNames: names,
            participants: participants,
            notes: notes,
            reports: reports
        ))
        return (MeetingMarkdown.fileName(for: meeting), text)
    }

    /// Lesbare Originalspuren und, bei einem eindeutigen Paar, ein gemeinsamer
    /// Stereoexport. Fehlende Dateien werden nie als Auswahl angeboten.
    func audioExportOptions(for meetingID: MeetingID) async -> [AudioExportOption] {
        guard let runtime else { return [] }
        let assets = (try? await runtime.library.listMediaAssets(meetingID: meetingID)) ?? []
        let layout = await runtime.library.layout
        return await AudioExportPresentation.options(
            for: assets,
            resolvingURLWith: { asset in
                layout.mediaFile(meetingID, fileName: asset.fileName)
            }
        )
    }

    /// Kopiert eine Originalspur heraus. Bewusst kopieren und nicht
    /// konvertieren: das Original ist die Referenz, an der jede Zeitmarke
    /// haengt, und es verlaesst die Bibliothek unveraendert.
    func exportAudioTrack(_ asset: MediaAsset, of meetingID: MeetingID) async {
        guard let runtime else { return }
        guard let meeting = await meeting(meetingID) else { return }
        let source = await runtime.library.layout.mediaFile(
            meetingID,
            fileName: asset.fileName
        )
        let stem = MeetingMarkdown.fileName(for: meeting)
            .replacingOccurrences(of: ".md", with: "")
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "\(stem) - \(ChannelLabel.trackName(asset.kind.rawValue))"
            + ".\(source.pathExtension)"
        panel.canCreateDirectories = true
        panel.message = "Save a copy of this original track."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
            report("Saved \(url.lastPathComponent).", isError: false)
        } catch {
            report(AppModel.message("The track could not be saved.", error))
        }
    }

    /// Fragt den Ablageort und schreibt. Der Speicherdialog gehoert hierher
    /// und nicht in die Ansicht, damit der Weg vom Menue und aus dem
    /// Kontextmenue derselbe ist.
    func exportMeetingToFile(_ meetingID: MeetingID) async {
        guard let document = await exportMarkdown(for: meetingID) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.message = "Save this meeting as Markdown."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            try Data(document.text.utf8).write(to: url, options: .atomic)
            report("Saved \(url.lastPathComponent).", isError: false)
        } catch {
            report(AppModel.message("The file could not be written.", error))
        }
    }
}

struct AudioExportActivity: Equatable, Identifiable {
    let id: UUID
    let meetingID: MeetingID
    let fileName: String
    let fraction: Double

    init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        fileName: String,
        fraction: Double
    ) {
        self.id = id
        self.meetingID = meetingID
        self.fileName = fileName
        self.fraction = fraction
    }

    func withFraction(_ fraction: Double) -> AudioExportActivity {
        AudioExportActivity(
            id: id,
            meetingID: meetingID,
            fileName: fileName,
            fraction: min(1, max(0, fraction))
        )
    }
}
