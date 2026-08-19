struct TranscriptionAccumulator: Sendable {
    let localeIdentifier: String
    private(set) var finalBlocks: [TranscriptionBlock] = []

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    mutating func record(
        _ block: TranscriptionBlock,
        isFinal: Bool
    ) -> TranscriptionEvent {
        if isFinal {
            finalBlocks.append(block)
            return .final(output)
        }
        return .volatile(TranscriptOutput(
            localeIdentifier: localeIdentifier,
            blocks: finalBlocks + [block]
        ))
    }

    var output: TranscriptOutput {
        TranscriptOutput(
            localeIdentifier: localeIdentifier,
            blocks: finalBlocks
        )
    }
}
