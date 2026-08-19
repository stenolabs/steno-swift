@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech
import Testing
@testable import StenoTranscription

@Suite("Speech input and result conversion")
struct SpeechConversionTests {
    @Test("converts native stereo buffers to a Speech-compatible mono format")
    func convertsPCMBufferFormat() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try #require(AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: 4_800
        ))
        source.frameLength = 4_800
        for channel in 0..<Int(sourceFormat.channelCount) {
            let samples = try #require(source.floatChannelData?[channel])
            for frame in 0..<Int(source.frameLength) {
                samples[frame] = sin(Float(frame) * 0.01)
            }
        }
        let converter = PCMBufferConverter(targetFormat: targetFormat)

        let converted = try converter.convert(source) + converter.flush()

        #expect(!converted.isEmpty)
        #expect(converted.allSatisfy { $0.format == targetFormat })
        let frameCount = converted.reduce(0) { $0 + Int($1.frameLength) }
        #expect(frameCount >= 1_590 && frameCount <= 1_610)
    }

    @Test("extracts audioTimeRange attributes as word timestamps")
    func extractsTimedWords() {
        var text = AttributedString("Hallo Welt")
        let helloEnd = text.characters.index(
            text.startIndex,
            offsetBy: 5
        )
        let worldStart = text.characters.index(after: helloEnd)
        text[text.startIndex..<helloEnd].audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.4, preferredTimescale: 1_000)
        )
        text[worldStart..<text.endIndex].audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 1.6, preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.5, preferredTimescale: 1_000)
        )

        let block = SpeechResultConverter.block(
            text: text,
            range: CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 1_000),
                duration: CMTime(seconds: 1.1, preferredTimescale: 1_000)
            ),
            channel: .system
        )

        #expect(block.text == "Hallo Welt")
        #expect(block.channel == .system)
        #expect(block.words == [
            TranscriptionWord(text: "Hallo", start: 1, end: 1.4),
            TranscriptionWord(text: "Welt", start: 1.6, end: 2.1),
        ])
    }
}

@Suite("Mono downmix")
struct MonoDownmixTests {
    @Test("stereo with speech only on the right survives the downmix")
    func rightOnlyStereo() throws {
        let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downmix-test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(
            forWriting: url,
            settings: stereo.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames: AVAudioFrameCount = 16_000
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: frames)!
        buffer.frameLength = frames
        // Links Stille, rechts ein 440-Hz-Ton.
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0
            buffer.floatChannelData![1][i] = sinf(Float(i) * 2 * .pi * 440 / 16_000) * 0.5
        }
        try file.write(from: buffer)

        let monoURL = try SpeechAnalyzerProvider.downmixToMono(
            AVAudioFile(forReading: url)
        )
        defer { try? FileManager.default.removeItem(at: monoURL) }
        let mono = try AVAudioFile(forReading: monoURL)
        #expect(mono.processingFormat.channelCount == 1)
        #expect(mono.length > 15_000)

        let check = AVAudioPCMBuffer(
            pcmFormat: mono.processingFormat,
            frameCapacity: AVAudioFrameCount(mono.length)
        )!
        try mono.read(into: check)
        var peak: Float = 0
        for i in 0..<Int(check.frameLength) {
            peak = max(peak, abs(check.floatChannelData![0][i]))
        }
        // Der rechte Kanal darf im Mixdown nicht verloren gehen.
        #expect(peak > 0.1)
    }
}
