@preconcurrency import CoreAudio
import Foundation
import StenoAudioCore

struct CoreAudioInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isAggregate: Bool
    let activeInputSubdeviceUIDs: Set<String>?

    init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        isAggregate: Bool = false,
        activeInputSubdeviceUIDs: Set<String>? = nil
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isAggregate = isAggregate
        self.activeInputSubdeviceUIDs = activeInputSubdeviceUIDs
    }

    static func availableDevices() throws -> [CoreAudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else {
            throw AudioRecordingError.audioSourceUnavailable(
                "cannot read the Core Audio device list"
            )
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: count
        )
        let listStatus = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard listStatus == noErr else {
            throw AudioRecordingError.audioSourceUnavailable(
                "cannot read the Core Audio devices"
            )
        }
        return deviceIDs.compactMap { deviceID in
            guard isAlive(deviceID), hasInputStreams(deviceID) else { return nil }
            return try? device(id: deviceID)
        }
    }

    static func input(uid: String) throws -> CoreAudioInputDevice {
        try input(uid: uid, from: availableDevices())
    }

    static func input(
        uid: String,
        from devices: [CoreAudioInputDevice]
    ) throws -> CoreAudioInputDevice {
        guard let device = devices.first(where: {
            $0.uid == uid
        }) else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone selected before audio setup is no longer available"
            )
        }
        return device
    }

    /// Liefert nur Eingabe-Subdevices eines Aggregats. Kann die Route nicht
    /// vollstaendig belegt werden, ist nil das absichtliche Fail-closed-Signal.
    static func activeInputSubdeviceUIDs(
        of deviceID: AudioDeviceID
    ) -> Set<String>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var subdeviceIDs = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: count
        )
        let readStatus = subdeviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard readStatus == noErr else { return nil }

        var inputUIDs: Set<String> = []
        for subdeviceID in subdeviceIDs {
            guard subdeviceID != kAudioObjectUnknown,
                  let hasInput = inputStreamPresence(subdeviceID) else {
                return nil
            }
            guard hasInput else { continue }
            guard let uid = try? stringProperty(
                kAudioDevicePropertyDeviceUID,
                deviceID: subdeviceID
            ) else { return nil }
            inputUIDs.insert(uid)
        }
        return inputUIDs
    }

    private static func device(
        id: AudioDeviceID
    ) throws -> CoreAudioInputDevice {
        let uid = try stringProperty(
            kAudioDevicePropertyDeviceUID,
            deviceID: id
        )
        let name = try stringProperty(
            kAudioObjectPropertyName,
            deviceID: id
        )
        let isAggregate = try objectClass(of: id)
            == kAudioAggregateDeviceClassID
        return CoreAudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            isAggregate: isAggregate,
            activeInputSubdeviceUIDs: isAggregate
                ? activeInputSubdeviceUIDs(of: id)
                : nil
        )
    }

    private static func objectClass(
        of deviceID: AudioDeviceID
    ) throws -> AudioClassID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioClassID(0)
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw AudioRecordingError.audioSourceUnavailable(
                "cannot classify the selected microphone"
            )
        }
        return value
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else {
            throw AudioRecordingError.audioSourceUnavailable(
                "cannot identify the selected microphone"
            )
        }
        return value.takeRetainedValue() as String
    }

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr && value != 0
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        inputStreamPresence(deviceID) == true
    }

    private static func inputStreamPresence(
        _ deviceID: AudioDeviceID
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else { return nil }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }
}

struct PinnedEngineInputRoute: Sendable {
    let deviceID: AudioDeviceID
    let deviceUID: String

    func accepts(
        reportedDeviceID: AudioDeviceID,
        activeInputUIDs: Set<String>?
    ) -> Bool {
        if reportedDeviceID == deviceID { return true }
        return activeInputUIDs == Set([deviceUID])
    }
}

struct PinnedInputDeviceState: Sendable {
    let pinnedUID: String
    let deviceName: String
    private(set) var currentDeviceID: AudioDeviceID?
    private var isAvailable = true
    private var availableSince: ContinuousClock.Instant?

    init(
        device: CoreAudioInputDevice,
        observedAt: ContinuousClock.Instant = .now
    ) {
        pinnedUID = device.uid
        deviceName = device.name
        currentDeviceID = device.id
        availableSince = observedAt
    }

    mutating func observe(
        _ devices: [CoreAudioInputDevice],
        at instant: ContinuousClock.Instant = .now
    ) -> AudioSourceEvent? {
        if let matching = devices.first(where: { $0.uid == pinnedUID }) {
            if currentDeviceID != matching.id {
                availableSince = instant
            }
            currentDeviceID = matching.id
            guard !isAvailable else { return nil }
            isAvailable = true
            return .available(deviceName: deviceName)
        }
        currentDeviceID = nil
        availableSince = nil
        guard isAvailable else { return nil }
        isAvailable = false
        return .unavailable(deviceName: deviceName)
    }

    func isStable(
        at instant: ContinuousClock.Instant,
        for duration: Duration
    ) -> Bool {
        guard currentDeviceID != nil, let availableSince else { return false }
        return availableSince.duration(to: instant) >= duration
    }

    mutating func markUnstable(at instant: ContinuousClock.Instant) {
        guard currentDeviceID != nil else { return }
        availableSince = instant
    }
}

struct InputLivenessState: Sendable {
    private var lastBufferAt: ContinuousClock.Instant
    private var isStalled = false

    init(startedAt: ContinuousClock.Instant) {
        lastBufferAt = startedAt
    }

    mutating func begin(at instant: ContinuousClock.Instant) {
        lastBufferAt = instant
        isStalled = false
    }

    mutating func markUnavailable(at instant: ContinuousClock.Instant) {
        lastBufferAt = instant
        isStalled = true
    }

    mutating func noteBuffer(
        at instant: ContinuousClock.Instant,
        deviceName: String?
    ) -> AudioSourceEvent? {
        lastBufferAt = instant
        guard isStalled else { return nil }
        isStalled = false
        return .available(deviceName: deviceName)
    }

    mutating func poll(
        at instant: ContinuousClock.Instant,
        timeout: Duration,
        deviceName: String?
    ) -> AudioSourceEvent? {
        guard !isStalled,
              lastBufferAt.duration(to: instant) >= timeout else { return nil }
        isStalled = true
        return .unavailable(deviceName: deviceName)
    }
}
