import StenoiOSAudio
import SwiftUI

/// Horizontal input level in dBFS.
///
/// Hand-drawn rather than a `Gauge`: `.accessoryLinear` tints its whole track,
/// so at silence it reads as full scale, which is the opposite of the truth.
/// On a screen whose job includes catching a dead microphone, that is not a
/// cosmetic difference.
///
/// Clipping is called out in words as well as colour, because losing headroom
/// is the one input problem the user can still fix while recording.
struct LevelMeter: View {
    let level: AudioLevel
    var isActive: Bool = true
    /// The recording strip has no room for the dBFS line and does not need it:
    /// there it is a sign of life, not a reading.
    var showsCaption: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(level.isClipping ? Color.red : Color.accentColor)
                        .frame(
                            width: geometry.size.width * (isActive ? level.meterFraction : 0)
                        )
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.05), value: level)

            if showsCaption {
                HStack {
                    Text(RecordingAccessibilityPresentation.microphoneLevelCaption(
                        for: level,
                        isActive: isActive
                    ))
                    Spacer()
                    if isActive && level.isClipping {
                        Text("clipping").foregroundStyle(.red)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(RecordingAccessibilityPresentation.microphoneLevelLabel))
        .accessibilityValue(Text(
            RecordingAccessibilityPresentation.microphoneLevelValue(
                for: level,
                isActive: isActive
            )
        ))
    }
}
