import SwiftUI
import Testing
import UIKit
@testable import Steno

@Suite("iOS accessibility layout policy", .serialized)
@MainActor
struct IOSAccessibilityLayoutTests {
    @Test("ordinary Dynamic Type sizes retain horizontal layouts", arguments: [
        DynamicTypeSize.xSmall,
        .medium,
        .xxxLarge,
    ])
    func ordinarySizesUseHorizontalLayout(size: DynamicTypeSize) {
        #expect(IOSAdaptiveStackAxis.axis(for: size) == .horizontal)
    }

    @Test("all accessibility Dynamic Type sizes use vertical layouts", arguments: [
        DynamicTypeSize.accessibility1,
        .accessibility2,
        .accessibility3,
        .accessibility4,
        .accessibility5,
    ])
    func accessibilitySizesUseVerticalLayout(size: DynamicTypeSize) {
        #expect(IOSAdaptiveStackAxis.axis(for: size) == .vertical)
    }

    @Test("the recording strip action stack uses distinct rows at AX5", arguments: [
        (DynamicTypeSize.large, false),
        (.accessibility5, true),
    ])
    func recordingStripActionStackUsesExpectedRows(
        size: DynamicTypeSize,
        expectsVerticalActions: Bool
    ) async throws {
        let measurements = RecordingStripLayoutMeasurements()
        let controller = UIHostingController(
            rootView: IOSAdaptiveStack(
                axis: IOSAdaptiveStackAxis.axis(for: size),
                spacing: 8,
                verticalAlignment: .leading
            ) {
                RecordingStripFrameProbe(identifier: "back")
                RecordingStripFrameProbe(identifier: "stop")
            }
            .coordinateSpace(name: RecordingStripLayoutCoordinateSpace.name)
            .onPreferenceChange(RecordingStripFramePreferenceKey.self) {
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

        let backFrame = try #require(measurements.frames["back"])
        let stopFrame = try #require(measurements.frames["stop"])
        let sameRowTolerance: CGFloat = 2

        #expect(backFrame.height > 0)
        #expect(stopFrame.height > 0)
        if expectsVerticalActions {
            #expect(abs(backFrame.midY - stopFrame.midY) > sameRowTolerance)
        } else {
            #expect(abs(backFrame.midY - stopFrame.midY) <= sameRowTolerance)
        }
    }
}

@MainActor
private final class RecordingStripLayoutMeasurements {
    var frames: [String: CGRect] = [:]
}

private enum RecordingStripLayoutCoordinateSpace {
    static let name = "recording-strip-layout-test"
}

private struct RecordingStripFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct RecordingStripFrameProbe: View {
    let identifier: String

    var body: some View {
        Color.clear
            .frame(width: 80, height: 32)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RecordingStripFramePreferenceKey.self,
                        value: [
                            identifier: proxy.frame(
                                in: .named(RecordingStripLayoutCoordinateSpace.name)
                            ),
                        ]
                    )
                }
            }
    }
}
