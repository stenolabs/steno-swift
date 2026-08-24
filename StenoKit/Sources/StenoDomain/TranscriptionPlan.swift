/// Die ausdrücklich gewählten ASR-Provider für Live- und Final-Transkription.
///
/// Die gesprochene Sprache gehört bewusst nicht hierher: sie lebt bereits in
/// `Meeting.sourceLocale` (mit Herkunft) und `Job.localeIdentifier`. Ein
/// zweites Sprachfeld hier wäre eine konkurrierende, herkunftslose Wahrheit.
public struct TranscriptionPlan: Codable, Equatable, Sendable {
    public let liveProviderID: TranscriptionProviderID
    public let finalProviderID: TranscriptionProviderID

    public init(
        liveProviderID: TranscriptionProviderID,
        finalProviderID: TranscriptionProviderID
    ) {
        self.liveProviderID = liveProviderID
        self.finalProviderID = finalProviderID
    }
}
