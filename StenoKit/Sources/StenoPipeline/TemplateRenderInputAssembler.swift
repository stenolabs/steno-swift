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
        return TemplateRenderInput(
            transcript: resolvedTranscript,
            participants: participants,
            context: RenderContext(userNotes: notes, participants: participants)
        )
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
    static func loadForRendering(
        layout: LibraryLayout,
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingReviewData? {
        try load(layout: layout, meetingID: meetingID, transaction: transaction)
    }
}
