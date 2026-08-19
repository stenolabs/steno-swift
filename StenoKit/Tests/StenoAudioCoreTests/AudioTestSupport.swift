import AVFAudio
import Foundation

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoMacAudioTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

func syntheticBuffer(
    sampleRate: Double = 8_000,
    channels: AVAudioChannelCount = 1,
    frames: AVAudioFrameCount = 4_000,
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(frames) {
            samples[frame] = frame.isMultiple(of: 2) ? amplitude : -amplitude
        }
    }
    return buffer
}
