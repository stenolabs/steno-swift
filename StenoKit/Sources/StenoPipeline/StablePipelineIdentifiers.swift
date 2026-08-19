import CryptoKit
import Foundation
import StenoDomain

enum StablePipelineIdentifiers {
    static func runID(for job: Job) -> RunID {
        runID(for: job.id, kind: job.kind)
    }

    static func runID(for jobID: JobID, kind: Job.Kind) -> RunID {
        let domain = switch kind {
        case .finalASR: "steno.final-asr.run"
        case .diarization: "steno.diarization.run"
        case .identitySuggestion: "steno.identity-suggestion.run"
        case .templateRender: "steno.template-render.run"
        case .export: "steno.export.run"
        }
        return RunID(rawValue: derive(from: jobID.rawValue, domain: domain))
    }

    static func revisionID(for job: Job) -> RevisionID {
        revisionID(for: job.id, kind: job.kind)
    }

    static func revisionID(for jobID: JobID, kind: Job.Kind) -> RevisionID {
        let domain = kind == .diarization
            ? "steno.diarization.revision"
            : "steno.final-asr.revision"
        return RevisionID(rawValue: derive(from: jobID.rawValue, domain: domain))
    }

    static func downstreamJobID(
        after jobID: JobID,
        kind: Job.Kind
    ) -> JobID {
        JobID(rawValue: derive(
            from: jobID.rawValue,
            domain: "steno.downstream-job.\(kind.rawValue)"
        ))
    }

    private static func derive(from source: UUID, domain: String) -> UUID {
        var sourceUUID = source.uuid
        let sourceBytes = withUnsafeBytes(of: &sourceUUID) { Array($0) }
        var input = Data(domain.utf8)
        input.append(contentsOf: sourceBytes)
        let digest = Array(SHA256.hash(data: input))
        let bytes: uuid_t = (
            sourceBytes[0], sourceBytes[1], sourceBytes[2], sourceBytes[3],
            sourceBytes[4], sourceBytes[5],
            0x70 | (digest[6] & 0x0f), digest[7],
            0x80 | (digest[8] & 0x3f), digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }
}
