@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import StenoiOSAudio

@Suite("Audio level")
struct AudioLevelTests {

    private func buffer(
        filledWith samples: [Float],
        channelCount: UInt32 = 1
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: channelCount,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channelCount) {
            for (index, sample) in samples.enumerated() {
                channels[channel][index] = sample
            }
        }
        return buffer
    }

    @Test("Digital silence reads as the floor, not as a quiet room")
    func silence() throws {
        let level = AudioLevelCalculator.level(
            of: try buffer(filledWith: Array(repeating: 0, count: 512))
        )

        #expect(level == .silence)
        #expect(level.meterFraction == 0)
        #expect(!level.isClipping)
    }

    @Test("Full scale reads as 0 dBFS and counts as clipping")
    func fullScale() throws {
        let level = AudioLevelCalculator.level(
            of: try buffer(filledWith: Array(repeating: 1, count: 512))
        )

        #expect(level.peak == 0)
        #expect(level.average == 0)
        #expect(level.isClipping)
        #expect(level.meterFraction == 1)
    }

    @Test("Half amplitude is about -6 dBFS")
    func halfAmplitude() throws {
        let level = AudioLevelCalculator.level(
            of: try buffer(filledWith: Array(repeating: 0.5, count: 512))
        )

        #expect(abs(level.peak - -6.02) < 0.05)
        #expect(!level.isClipping)
    }

    @Test("Peak follows the loudest sample while the average stays below it")
    func peakVersusAverage() throws {
        var samples = Array(repeating: Float(0.01), count: 512)
        samples[100] = 0.9

        let level = AudioLevelCalculator.level(of: try buffer(filledWith: samples))

        #expect(abs(level.peak - -0.92) < 0.05)
        #expect(level.average < level.peak)
    }

    @Test("Both channels contribute to the level")
    func stereoIsAveraged() throws {
        let level = AudioLevelCalculator.level(
            of: try buffer(
                filledWith: Array(repeating: 0.5, count: 512),
                channelCount: 2
            )
        )

        #expect(abs(level.average - -6.02) < 0.05)
    }

    @Test("An empty buffer is silence rather than a crash")
    func emptyBuffer() throws {
        let level = AudioLevelCalculator.level(of: try buffer(filledWith: []))

        #expect(level == .silence)
    }

    @Test("Levels are clamped into the reportable range")
    func clamping() {
        #expect(AudioLevel(peak: 12, average: 12).peak == 0)
        #expect(AudioLevel(peak: -400, average: -400).average == AudioLevel.floor)
    }

    @Test("Amplitudes at or below zero map to the floor")
    func decibelsOfZero() {
        #expect(AudioLevelCalculator.decibels(fromAmplitude: 0) == AudioLevel.floor)
        #expect(AudioLevelCalculator.decibels(fromAmplitude: -1) == AudioLevel.floor)
    }
}
