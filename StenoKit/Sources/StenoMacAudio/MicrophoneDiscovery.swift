@preconcurrency import CoreAudio
import Foundation

public struct MicrophoneDevice: Codable, Identifiable, Hashable, Sendable {
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct ActiveMicrophoneClient: Equatable, Sendable {
    public let processID: pid_t
    public let bundleIdentifier: String?
    public let deviceUIDs: [String]

    public init(
        processID: pid_t,
        bundleIdentifier: String?,
        deviceUIDs: [String]
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.deviceUIDs = deviceUIDs
    }
}

public struct MicrophoneDiscoverySnapshot: Equatable, Sendable {
    public let availableDevices: [MicrophoneDevice]
    public let activeDevices: [MicrophoneDevice]
    public let activeClients: [ActiveMicrophoneClient]
    public let hasUnresolvedActiveDevices: Bool

    public static let empty = MicrophoneDiscoverySnapshot(
        availableDevices: [],
        activeDevices: [],
        activeClients: [],
        hasUnresolvedActiveDevices: false
    )

    public init(
        availableDevices: [MicrophoneDevice],
        activeDevices: [MicrophoneDevice],
        activeClients: [ActiveMicrophoneClient],
        hasUnresolvedActiveDevices: Bool
    ) {
        self.availableDevices = availableDevices
        self.activeDevices = activeDevices
        self.activeClients = activeClients
        self.hasUnresolvedActiveDevices = hasUnresolvedActiveDevices
    }

    public var automaticDevice: MicrophoneDevice? {
        guard !hasUnresolvedActiveDevices, activeDevices.count == 1 else {
            return nil
        }
        return activeDevices[0]
    }

    public static func current(
        excludingProcessID: pid_t = getpid(),
        excludingBundleIdentifier: String? = nil
    ) throws -> MicrophoneDiscoverySnapshot {
        let availableDevices = try CoreAudioInputDevice.availableDevices()
        do {
            return try make(
                availableDevices: availableDevices,
                activeClients: CoreAudioProcessReader.activeInputClients(),
                excludingProcessID: excludingProcessID,
                excludingBundleIdentifier: excludingBundleIdentifier
            )
        } catch {
            return makeUnresolved(availableDevices: availableDevices)
        }
    }
}

struct CoreAudioInputClient: Equatable, Sendable {
    let processID: pid_t
    let bundleIdentifier: String?
    let deviceIDs: [AudioObjectID]
    let hasUnresolvedDevices: Bool

    init(
        processID: pid_t,
        bundleIdentifier: String?,
        deviceIDs: [AudioObjectID],
        hasUnresolvedDevices: Bool = false
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.deviceIDs = deviceIDs
        self.hasUnresolvedDevices = hasUnresolvedDevices
    }
}

extension MicrophoneDiscoverySnapshot {
    static func makeUnresolved(
        availableDevices: [CoreAudioInputDevice]
    ) -> MicrophoneDiscoverySnapshot {
        MicrophoneDiscoverySnapshot(
            availableDevices: selectableDevices(from: availableDevices),
            activeDevices: [],
            activeClients: [],
            hasUnresolvedActiveDevices: true
        )
    }

    static func make(
        availableDevices: [CoreAudioInputDevice],
        activeClients: [CoreAudioInputClient],
        excludingProcessID: pid_t? = nil,
        excludingBundleIdentifier: String? = nil
    ) -> MicrophoneDiscoverySnapshot {
        let devicesByID = Dictionary(
            uniqueKeysWithValues: availableDevices.map { ($0.id, $0) }
        )
        let publicDevices = selectableDevices(from: availableDevices)
        let publicDeviceUIDs = Set(publicDevices.map(\.uid))
        var unresolved = false
        let clients = activeClients
            .filter {
                $0.processID != excludingProcessID
                    && (excludingBundleIdentifier == nil
                        || $0.bundleIdentifier != excludingBundleIdentifier)
            }
            .map { client in
                if client.hasUnresolvedDevices { unresolved = true }
                if !MeetingAudioClient.isRecognized(
                    bundleIdentifier: client.bundleIdentifier
                ) {
                    unresolved = true
                }
                var uids: Set<String> = []
                for deviceID in client.deviceIDs {
                    guard let device = devicesByID[deviceID] else {
                        unresolved = true
                        continue
                    }
                    if device.isAggregate {
                        guard let routedUIDs = device.activeInputSubdeviceUIDs,
                              routedUIDs.count == 1,
                              let routedUID = routedUIDs.first,
                              publicDeviceUIDs.contains(routedUID) else {
                            unresolved = true
                            continue
                        }
                        uids.insert(routedUID)
                    } else {
                        uids.insert(device.uid)
                    }
                }
                return ActiveMicrophoneClient(
                    processID: client.processID,
                    bundleIdentifier: client.bundleIdentifier,
                    deviceUIDs: uids.sorted()
                )
            }
        let activeUIDs = Set(clients.flatMap(\.deviceUIDs))
        return MicrophoneDiscoverySnapshot(
            availableDevices: publicDevices,
            activeDevices: publicDevices.filter { activeUIDs.contains($0.uid) },
            activeClients: clients,
            hasUnresolvedActiveDevices: unresolved
        )
    }

    private static func selectableDevices(
        from availableDevices: [CoreAudioInputDevice]
    ) -> [MicrophoneDevice] {
        var devicesByUID: [String: MicrophoneDevice] = [:]
        for device in availableDevices where !device.isAggregate {
            let candidate = MicrophoneDevice(uid: device.uid, name: device.name)
            if let current = devicesByUID[device.uid],
               !deviceSort(candidate, current) {
                continue
            }
            devicesByUID[device.uid] = candidate
        }
        return devicesByUID.values.sorted(by: deviceSort)
    }

    fileprivate static func deviceSort(
        _ lhs: MicrophoneDevice,
        _ rhs: MicrophoneDevice
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder == .orderedSame { return lhs.uid < rhs.uid }
        return nameOrder == .orderedAscending
    }
}

private enum MeetingAudioClient {
    private static let bundleIdentifierPrefixes = [
        "cisco-systems.spark",
        "com.apple.facetime",
        "com.apple.safari",
        "com.apple.webkit.",
        "com.brave.browser",
        "com.cisco.webex",
        "com.google.chrome",
        "com.hnc.discord",
        "com.microsoft.edgemac",
        "com.microsoft.teams",
        "com.operasoftware.opera",
        "com.tinyspeck.slackmacgap",
        "com.vivaldi.vivaldi",
        "com.webex.",
        "company.thebrowser.browser",
        "org.jitsi.",
        "org.mozilla.",
        "us.zoom.",
    ]

    static func isRecognized(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalized = bundleIdentifier.lowercased()
        return bundleIdentifierPrefixes.contains(where: normalized.hasPrefix)
    }
}

private enum CoreAudioProcessReader {
    static func activeInputClients() throws -> [CoreAudioInputClient] {
        let processObjectIDs = try objectIDs(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )
        return processObjectIDs.compactMap { processObjectID in
            let processID = (try? processID(of: processObjectID)) ?? 0
            let bundleIdentifier = try? bundleIdentifier(of: processObjectID)
            do {
                guard try uint32(
                    of: processObjectID,
                    selector: kAudioProcessPropertyIsRunningInput
                ) == 1 else { return nil }
                let deviceIDs = try objectIDs(
                    of: processObjectID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                )
                return CoreAudioInputClient(
                    processID: processID,
                    bundleIdentifier: bundleIdentifier,
                    deviceIDs: deviceIDs,
                    hasUnresolvedDevices: processID == 0 || deviceIDs.isEmpty
                )
            } catch {
                return CoreAudioInputClient(
                    processID: processID,
                    bundleIdentifier: bundleIdentifier,
                    deviceIDs: [],
                    hasUnresolvedDevices: true
                )
            }
        }
    }

    private static func objectIDs(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            throw MicrophoneDiscoveryError.cannotReadAudioProcesses
        }
        guard size > 0 else { return [] }
        var values = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw MicrophoneDiscoveryError.cannotReadAudioProcesses
        }
        return values
    }

    private static func uint32(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw MicrophoneDiscoveryError.cannotReadAudioProcesses
        }
        return value
    }

    private static func processID(
        of processObjectID: AudioObjectID
    ) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw MicrophoneDiscoveryError.cannotReadAudioProcesses
        }
        return value
    }

    private static func bundleIdentifier(
        of processObjectID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else {
            throw MicrophoneDiscoveryError.cannotReadAudioProcesses
        }
        return value.takeRetainedValue() as String
    }
}

private enum MicrophoneDiscoveryError: Error {
    case cannotReadAudioProcesses
}
