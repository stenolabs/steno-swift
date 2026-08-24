import SwiftUI

/// Keeps transcript time and content compact at ordinary text sizes, then
/// gives both their full intrinsic width at Accessibility Dynamic Type sizes.
struct IOSTranscriptRowLayout<Timestamp: View, Content: View>: View {
    let axis: Axis
    private let timestamp: Timestamp
    private let content: Content

    init(
        axis: Axis,
        @ViewBuilder timestamp: () -> Timestamp,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.timestamp = timestamp()
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if axis == .horizontal {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                timestamp
                content
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                timestamp
                content
            }
        }
    }
}
