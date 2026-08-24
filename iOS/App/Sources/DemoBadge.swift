import StenoDomain
import SwiftUI

struct DemoBadge: View {
    let meeting: Meeting

    static let accessibilityLabel = DemoDataPresentation.badgeAccessibilityLabel

    var body: some View {
        if Self.shouldShow(for: meeting) {
            Text(DemoDataPresentation.badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel(Self.accessibilityLabel)
        }
    }

    static func shouldShow(for meeting: Meeting) -> Bool {
        meeting.isDemo
    }
}
