import Foundation
import StenoiOSAudio
import SwiftUI

/// Chooses the one stack direction that remains readable at every Dynamic Type size.
enum IOSAdaptiveStackAxis {
    static func axis(for size: DynamicTypeSize) -> Axis {
        size.isAccessibilitySize ? .vertical : .horizontal
    }
}

/// A stack whose axis is chosen by the shared Dynamic Type policy.
struct IOSAdaptiveStack<Content: View>: View {
    let axis: Axis
    let spacing: CGFloat
    let verticalAlignment: HorizontalAlignment
    private let content: Content

    init(
        axis: Axis,
        spacing: CGFloat = 8,
        verticalAlignment: HorizontalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.spacing = spacing
        self.verticalAlignment = verticalAlignment
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if axis == .horizontal {
            HStack(spacing: spacing) { content }
        } else {
            VStack(alignment: verticalAlignment, spacing: spacing) { content }
        }
    }
}

/// Stable VoiceOver semantics for volatile recording values.
///
/// Values update with the recording, but their vocabulary deliberately stays
/// small. This keeps a microphone level useful when it is queried without
/// turning its frequent updates into announcements.
enum RecordingAccessibilityPresentation {
    static let durationLabel: LocalizedStringResource = "Recording time"
    static let microphoneLevelLabel: LocalizedStringResource = "Microphone level"
    static let backLabel: LocalizedStringResource = "Back"
    static let backHint: LocalizedStringResource = "Returns to the recording screen."
    static let recordLabel: LocalizedStringResource = "Record"
    static let recordHint: LocalizedStringResource = "Starts a new recording."
    static let stopLabel: LocalizedStringResource = "Stop"
    static let stopHint: LocalizedStringResource = "Ends the recording and saves it."

    static func durationValue(
        for interval: TimeInterval,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        return Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes, .seconds],
            width: .wide,
            maximumUnitCount: 3,
            zeroValueUnits: .hide
        )
        .locale(locale)
        .format(.seconds(totalSeconds))
    }

    static func microphoneLevelValue(
        for level: AudioLevel,
        isActive: Bool
    ) -> LocalizedStringResource {
        guard isActive else { return "idle" }
        if level.isClipping { return "clipping" }
        if level.peak <= SilenceMonitor.defaultThreshold { return "silent" }
        if level.peak <= -36 { return "low" }
        if level.peak <= -12 { return "normal" }
        return "high"
    }

    static func microphoneLevelCaption(
        for level: AudioLevel,
        isActive: Bool
    ) -> LocalizedStringResource {
        guard isActive else { return "idle" }
        guard level.average > AudioLevel.floor else { return "silence" }
        let average = Int(level.average.rounded())
        let peak = Int(level.peak.rounded())
        return "\(average) dBFS, peak \(peak)"
    }
}
