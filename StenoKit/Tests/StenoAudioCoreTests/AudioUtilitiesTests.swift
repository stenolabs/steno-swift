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

    @Test("zero available bytes is a measured capacity, not an unknown value")
    func preservesZeroAvailableCapacity() throws {
        let available = try DiskSpaceChecker.resolveAvailableBytes(
            importantUsage: 0,
            general: nil
        )

        #expect(available == 0)
        do {
            try DiskSpaceChecker.validate(availableBytes: available)
            Issue.record("Expected insufficientDiskSpace")
        } catch let error as AudioRecordingError {
            #expect(error == .insufficientDiskSpace(
                requiredBytes: DiskSpaceChecker.minimumRecordingBytes,
                availableBytes: 0
            ))
        }
    }
}
