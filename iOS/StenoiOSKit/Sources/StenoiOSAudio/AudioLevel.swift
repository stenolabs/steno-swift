@preconcurrency import AVFAudio
import Foundation
import StenoAudioCore

/// Peak and average level of one buffer, in dBFS.
///
/// dBFS rather than a 0...1 fraction, because the useful information for a
/// recording screen is headroom and silence, and both live in the top and
/// bottom few decibels where a linear scale has no resolution.
public struct AudioLevel: Equatable, Sendable {
    /// Level of the loudest sample, at most 0.
    public let peak: Float
    /// Root mean square across the buffer, at most 0.
    public let average: Float

    public static let silence = AudioLevel(peak: floor, average: floor)

    /// Anything quieter than this is reported as silence. -80 dBFS is well
    /// below the noise floor of any usable microphone, so a reading at the
    /// floor means no signal rather than a quiet room.
    public static let floor: Float = -80

    public init(peak: Float, average: Float) {
        self.peak = max(Self.floor, min(0, peak))
        self.average = max(Self.floor, min(0, average))
    }

    /// Converts the shared session's linear levels into dBFS.
    ///
    /// `RecordingSession` reports amplitudes between 0 and 1 because that is
    /// what its meter computes. Converting here rather than tapping the input
    /// a second time matters: two taps on one input node is a well known way
    /// to end up with a silent recording.
    public init(_ levels: AudioLevels) {
        self.init(
            peak: AudioLevelCalculator.decibels(fromAmplitude: levels.peak),
            average: AudioLevelCalculator.decibels(fromAmplitude: levels.rms)
        )
    }

    /// Whether the input is clipping and the recording is losing information.
    public var isClipping: Bool { peak >= -0.1 }

    /// Position on a meter, 0 at the floor and 1 at full scale.
    public var meterFraction: Double {
        Double((average - Self.floor) / -Self.floor)
    }
}

public enum AudioLevelCalculator {
    /// Level of a float PCM buffer, averaged across all channels.
    ///
    /// Returns silence for a non-float or empty buffer rather than guessing;
    /// `AVAudioEngine` input is float32 on every device this app supports.
    public static func level(of buffer: AVAudioPCMBuffer) -> AudioLevel {
        guard
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0,
            buffer.format.channelCount > 0
        else {
            return .silence
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var peak: Float = 0
        var sumOfSquares: Float = 0

        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                peak = max(peak, abs(sample))
                sumOfSquares += sample * sample
            }
        }

        let meanSquare = sumOfSquares / Float(frameCount * channelCount)
        return AudioLevel(
            peak: decibels(fromAmplitude: peak),
            average: decibels(fromAmplitude: meanSquare.squareRoot())
        )
    }

    public static func decibels(fromAmplitude amplitude: Float) -> Float {
        guard amplitude > 0 else { return AudioLevel.floor }
        return 20 * log10(amplitude)
    }
}
