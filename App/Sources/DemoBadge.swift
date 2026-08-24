import StenoDomain
import SwiftUI

struct DemoBadge: View {
    nonisolated static func isVisible(for meeting: Meeting) -> Bool {
        meeting.isDemo
    }

    var body: some View {
        Label(DemoDataPresentation.badgeLabel, systemImage: "sparkles")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(DemoDataPresentation.badgeAccessibilityLabel)
    }
}
