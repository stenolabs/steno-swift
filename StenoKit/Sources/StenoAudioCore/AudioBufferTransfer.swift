@preconcurrency import AVFAudio
import Darwin

/// Takes ownership of a buffer the audio engine is about to reclaim.
///
/// Public only because the recorders that call it now live in another module
/// after the split; it was internal before and the behaviour is unchanged.
public enum AudioBufferTransfer {
    public static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            guard byteCount == 0 || (
                sourceBuffers[index].mData != nil
                    && destinationBuffers[index].mData != nil
            ) else {
                return nil
            }
            if byteCount > 0 {
                memcpy(
                    destinationBuffers[index].mData!,
                    sourceBuffers[index].mData!,
                    byteCount
                )
                destinationBuffers[index].mDataByteSize = UInt32(byteCount)
            }
        }
        return destination
    }
}
