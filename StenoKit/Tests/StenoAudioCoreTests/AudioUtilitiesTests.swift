import Testing
@testable import StenoAudioCore

@Suite("Audio utilities")
struct AudioUtilitiesTests {
    @Test("measures peak and RMS across every sample")
    func measuresLevels() {
        let buffer = syntheticBuffer(amplitude: 0.5)

        let levels = AudioLevelMeter.measure(buffer)

        #expect(abs(levels.peak - 0.5) < 0.000_1)
        #expect(abs(levels.rms - 0.5) < 0.000_1)
    }

    @Test("accepts exactly two decimal gigabytes and rejects one byte less")
    func enforcesDiskThreshold() throws {
        try DiskSpaceChecker.validate(availableBytes: 2_000_000_000)

        #expect(throws: AudioRecordingError.self) {
            try DiskSpaceChecker.validate(availableBytes: 1_999_999_999)
        }
    }
}
