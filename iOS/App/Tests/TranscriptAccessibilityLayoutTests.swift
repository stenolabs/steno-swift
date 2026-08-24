import SwiftUI
import Testing
import UIKit
@testable import Steno

@Suite("iOS transcript accessibility layout", .serialized)
@MainActor
struct TranscriptAccessibilityLayoutTests {
    @Test("transcript content moves below its timestamp at AX5", arguments: [
        (DynamicTypeSize.large, false),
        (.accessibility5, true),
    ])
    func transcriptContentUsesExpectedRow(
        size: DynamicTypeSize,
        expectsVerticalLayout: Bool
    ) async throws {
        let measurements = TranscriptLayoutMeasurements()
        let controller = UIHostingController(
            rootView: IOSTranscriptRowLayout(
                axis: IOSAdaptiveStackAxis.axis(for: size)
            ) {
                TranscriptFrameProbe(identifier: "timestamp", width: 84, height: 20)
            } content: {
                TranscriptFrameProbe(identifier: "content", width: 260, height: 80)
            }
            .coordinateSpace(name: TranscriptLayoutCoordinateSpace.name)
            .onPreferenceChange(TranscriptFramePreferenceKey.self) {
                measurements.frames = $0
            }
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let timestamp = try #require(measurements.frames["timestamp"])
        let content = try #require(measurements.frames["content"])
        let sameRowTolerance: CGFloat = 2

        #expect(timestamp.width >= 80)
        if expectsVerticalLayout {
            #expect(content.minY > timestamp.maxY)
        } else {
            #expect(content.minX > timestamp.maxX)
            #expect(timestamp.maxY + sameRowTolerance >= content.minY)
            #expect(content.maxY + sameRowTolerance >= timestamp.minY)
        }
    }
}

@MainActor
private final class TranscriptLayoutMeasurements {
    var frames: [String: CGRect] = [:]
}

private enum TranscriptLayoutCoordinateSpace {
    static let name = "transcript-layout-test"
}

private struct TranscriptFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct TranscriptFrameProbe: View {
    let identifier: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TranscriptFramePreferenceKey.self,
                        value: [
                            identifier: proxy.frame(
                                in: .named(TranscriptLayoutCoordinateSpace.name)
                            ),
                        ]
                    )
                }
            }
    }
}
