import Foundation
import Testing
@testable import StenoExchange

@Suite("Meeting transfer progress presentation")
struct MeetingTransferProgressPresentationTests {
    @Test("unknown totals stay indeterminate")
    func unknownTotalsStayIndeterminate() {
        #expect(MeetingTransferProgressPresentation.make(nil) == .indeterminate)
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .enumerating, processedBytes: 1, totalBytes: 0)
            ) == .indeterminate
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .hashing, processedBytes: 1, totalBytes: -1)
            ) == .indeterminate
        )
    }

    @Test("positive totals produce a clamped fraction")
    func positiveTotalsProduceClampedFraction() {
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .writing, processedBytes: -1, totalBytes: 10)
            ) == .determinate(0)
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .writing, processedBytes: 5, totalBytes: 10)
            ) == .determinate(0.5)
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .writing, processedBytes: 11, totalBytes: 10)
            ) == .determinate(1)
        )
    }

    @Test("progress has a localized accessibility label")
    func progressHasLocalizedAccessibilityLabel() {
        #expect(
            String(localized: MeetingTransferProgressPresentation.indeterminate.accessibilityLabel)
                == "Import progress"
        )
    }
}
