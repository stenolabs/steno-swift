@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import Testing
@testable import StenoDiarization

@Suite("Diarization infrastructure")
struct DiarizationInfrastructureTests {
    @Test("AVAudioFile decoding resamples stereo input to 16 kHz mono Float")
    func decodesAudioWithoutFfmpeg() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stereo.caf")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 40_000))
        buffer.frameLength = 40_000
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<40_000 {
            channels[0][frame] = 0.2
            channels[1][frame] = 0.4
        }
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        var outputFile: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile?.write(from: buffer)
        outputFile = nil

        let samples = try AVAudioSampleLoader.load(from: url)

        #expect(samples.count >= 79_990 && samples.count <= 80_010)
        #expect(abs(samples[samples.count / 2] - 0.3) < 0.02)
    }

    @Test("missing models point at the installer instead of a developer switch")
    func missingModelsExplainWhereToInstall() throws {
        let provider = FluidSortformerProvider()
        #expect(provider.computeUnits == .cpuAndNeuralEngine)

        let error = DiarizationError.modelsNotInstalled(missing: [
            "Sortformer.mlmodelc",
            "wespeaker_v2.mlmodelc",
        ])

        #expect(error.localizedDescription.contains("Install them in Steno's settings."))
        #expect(!error.localizedDescription.contains("allowModelDownload"))
    }

    @Test("the model query reports only the missing assets")
    func reportsOnlyMissingModelAssets() throws {
        let present = URL(fileURLWithPath: "/models/present.mlmodelc")
        let missing = URL(fileURLWithPath: "/models/missing.mlmodelc")

        let result = missingModelURLs(
            required: [present, missing],
            fileExists: { $0 == present }
        )

        #expect(result == [missing])
    }

    @Test("diarization output retains engine provenance and cluster embeddings")
    func outputRoundTrips() throws {
        let output = DiarizationOutput(
            segments: [DiarizationSegment(clusterID: "SPEAKER_0", start: 1, end: 2)],
            embeddings: ["SPEAKER_0": Array(repeating: 0.125, count: 256)],
            engine: EngineDescriptor(
                name: "FluidAudio Sortformer",
                version: "0.15.2",
                modelVersion: "Sortformer_v2.1 + wespeaker_v2"
            )
        )

        let decoded = try JSONDecoder().decode(
            DiarizationOutput.self,
            from: JSONEncoder().encode(output)
        )

        #expect(decoded == output)
        #expect(decoded.embeddings["SPEAKER_0"]?.count == 256)
    }
}
