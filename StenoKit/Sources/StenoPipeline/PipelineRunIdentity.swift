import StenoDomain

public enum PipelineRunIdentity {
    public static func runID(for job: Job) -> RunID {
        StablePipelineIdentifiers.runID(for: job)
    }
}
