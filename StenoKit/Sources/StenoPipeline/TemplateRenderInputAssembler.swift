import CryptoKit
import Foundation
import StenoDomain
import StenoIntelligence
import StenoLibrary

struct TemplateRenderInput: Sendable {
    let transcript: TranscriptRevision
    let participants: [String]
    let context: RenderContext

    var disclosure: OutboundDisclosure {
        OutboundDisclosure(transcript: transcript, context: context)
    }
}

public struct TemplateRenderPreflight: Equatable, Sendable {
    public let meetingID: MeetingID
    public let revisionID: RevisionID
    public let disclosure: OutboundDisclosure
    public let inputFingerprint: String

    init(
        meetingID: MeetingID,
        revisionID: RevisionID,
        disclosure: OutboundDisclosure,
        inputFingerprint: String
    ) {
        self.meetingID = meetingID
        self.revisionID = revisionID
        self.disclosure = disclosure
        self.inputFingerprint = inputFingerprint
    }
}

public enum TemplateRenderPreflightError: Error, Equatable, Sendable {
    case inputChanged
}

public enum TemplateRenderInputAssembler {
    public static func preflight(
        library: Library,
        meetingID: MeetingID
    ) async throws -> TemplateRenderPreflight {
        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            try preflight(
                library: library,
                meetingID: meetingID,
                transaction: transaction
            )
        }
    }

    static func preflight(
        library: Library,
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> TemplateRenderPreflight {
        let input = try assemble(
            library: library,
            meetingID: meetingID,
            revisionID: nil,
            transaction: transaction
        )
        return TemplateRenderPreflight(
            meetingID: meetingID,
            revisionID: input.transcript.id,
            disclosure: input.disclosure,
            inputFingerprint: try fingerprint(for: input)
        )
    }

    public static func validate(
        _ preflight: TemplateRenderPreflight,
        library: Library
    ) async throws {
        let current = try await Self.preflight(
            library: library,
            meetingID: preflight.meetingID
        )
        guard current == preflight else {
            throw TemplateRenderPreflightError.inputChanged
        }
    }

    static func assemble(
        library: Library,
        meetingID: MeetingID,
        revisionID: RevisionID?,
        transaction: LibraryMutationTransaction
    ) throws -> TemplateRenderInput {
        let revision: TranscriptRevision
        if let revisionID {
            revision = try library.loadRevision(
                revisionID,
                meetingID: meetingID,
                transaction: transaction
            )
        } else {
            revision = try library.loadCurrentRevision(
                meetingID: meetingID,
                transaction: transaction
            )
        }
        let review = try MeetingReviewAssembler.loadForRendering(
            layout: library.layout,
            meetingID: meetingID,
            revision: revision,
            transaction: transaction
        )
        let meeting = try library.loadMeeting(meetingID, transaction: transaction)
        let resolvedTranscript = review?.resolvingConfirmedNames(in: revision) ?? revision
        let additional = review.map { review in
            meeting.additionalParticipantIDs.compactMap { personID in
                review.persons.first { $0.id == personID }
                    .map(TemplateParticipants.label(for:))
            }
        } ?? []
        let participants = review.map {
            TemplateParticipants.list(
                revision: revision,
                review: $0,
                additional: additional
            )
        } ?? []
        let notes = try MeetingNotesStore(layout: library.layout).notes(
            meetingID,
            transaction: transaction
        )
        let outputLocaleIdentifier = outputLocaleIdentifier(
            library: library,
            meeting: meeting,
            revision: revision
        )
        return TemplateRenderInput(
            transcript: resolvedTranscript,
            participants: participants,
            context: RenderContext(
                userNotes: notes,
                participants: participants,
                outputLocaleIdentifier: outputLocaleIdentifier
            )
        )
    }

    /// Die Sprache des Protokolls kommt aus der gespeicherten Wahl, nie aus
    /// `Locale.current`. Eine neue Aufnahme traegt sie ausdruecklich in
    /// `Meeting.sourceLocale` (Ursprung `.explicit`, siehe
    /// `Job.localeIdentifier`); importierte oder zusammengefuehrte Meetings
    /// koennen ungepinnt sein, dann ist die tatsaechlich verwendete Locale im
    /// unveraenderlichen Final-ASR-Artefakt die verlaesslichste Quelle. Bei
    /// widerspruechlichen Spuren (mehrere Locales im selben Lauf) liefert
    /// diese Funktion nil statt zu raten - das Modell bestimmt dann die
    /// Sprache selbst aus dem Transkript, wie ohne gespeicherte Wahl auch.
    ///
    /// Der Blick auf Diarisierungs- und Final-ASR-Artefakt ist bewusst rein
    /// lesend und nicht `RunArtifactStore.loadFinished`: dessen
    /// Validierung quarantaent ein Artefakt bei jedem Mismatch, richtig fuer
    /// die Pipeline, die ihr eigenes committetes Ergebnis nachlaedt, falsch
    /// fuer einen beilaeufigen Sprachhinweis. Ein unerwarteter Zustand
    /// bedeutet hier nur "kein Hinweis", nie "beschaedigt".
    static func outputLocaleIdentifier(
        library: Library,
        meeting: Meeting,
        revision: TranscriptRevision
    ) -> String? {
        if let sourceLocale = meeting.sourceLocale, sourceLocale.origin == .explicit {
            return normalizedLocaleIdentifier(sourceLocale.localeIdentifier)
        }
        guard let diarizationRunID = diarizationRunID(in: revision),
              let diarization = peekFinishedArtifact(
                  DiarizationArtifact.self,
                  layout: library.layout,
                  meetingID: meeting.id,
                  runID: diarizationRunID,
                  expectedKind: .diarization,
                  artifactPath: LibraryLayout.runDiarization
              ),
              let finalASR = peekFinishedArtifact(
                  FinalASRArtifact.self,
                  layout: library.layout,
                  meetingID: meeting.id,
                  runID: diarization.sourceRunID,
                  expectedKind: .finalASR,
                  artifactPath: LibraryLayout.runTranscript
              )
        else {
            return nil
        }

        let locales = Set(finalASR.tracks.map {
            normalizedLocaleIdentifier($0.output.localeIdentifier)
        })
        return locales.count == 1 ? locales.first : nil
    }

    private static func peekFinishedArtifact<Artifact: Decodable>(
        _ type: Artifact.Type,
        layout: LibraryLayout,
        meetingID: MeetingID,
        runID: RunID,
        expectedKind: ProcessingRun.Kind,
        artifactPath: (LibraryLayout) -> (MeetingID, RunID) -> URL
    ) -> Artifact? {
        guard let runData = try? Data(contentsOf: layout.runMetadata(meetingID, runID: runID)),
              let run = try? JSONDecoder().decode(ProcessingRun.self, from: runData),
              run.id == runID, run.meetingID == meetingID, run.kind == expectedKind,
              run.status == .finished
        else { return nil }
        guard let data = try? Data(contentsOf: artifactPath(layout)(meetingID, runID)) else {
            return nil
        }
        return try? JSONDecoder().decode(Artifact.self, from: data)
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    static func fingerprint(for input: TemplateRenderInput) throws -> String {
        let payload = FingerprintPayload(
            transcript: input.transcript,
            participants: input.participants,
            contextParticipants: input.context.participants,
            userNotes: input.context.userNotes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct FingerprintPayload: Codable {
    let transcript: TranscriptRevision
    let participants: [String]
    let contextParticipants: [String]
    let userNotes: String?
}

private extension MeetingReviewAssembler {
    /// Laedt den Review-Stand fuer eine gepinnte Revision. Ein Report wird
    /// aus genau der Revision gerendert, die in job.revisionID pinnt; das
    /// Review daneben darf deshalb nicht den juengsten Diarisierungslauf
    /// nehmen, sondern nur den, der diese Revision erzeugt hat. Laesst
    /// sich der Lauf nicht ableiten, oder passt kein Vorschlagsartefakt zu
    /// ihm, wird ohne Review gerendert (Kanal-Labels statt Namen) statt mit
    /// dem Review eines anderen Laufs.
    static func loadForRendering(
        layout: LibraryLayout,
        meetingID: MeetingID,
        revision: TranscriptRevision,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingReviewData? {
        guard let pinnedDiarizationRunID = diarizationRunID(in: revision) else {
            return nil
        }
        return try load(
            layout: layout,
            meetingID: meetingID,
            diarizationRunID: pinnedDiarizationRunID,
            transaction: transaction
        )
    }
}
