import Foundation
import Security
import StenoAudioCore
import StenoDomain
import StenoMacAudio

struct CodeSigningIdentity: Equatable, Sendable {
    let teamIdentifier: String?
    let signingIdentifier: String
    let cdHash: String?

    var cacheKey: String? {
        if let teamIdentifier, !teamIdentifier.isEmpty {
            return "team:\(teamIdentifier)|identifier:\(signingIdentifier)"
        }
        guard let cdHash, !cdHash.isEmpty else { return nil }
        return "adhoc:\(signingIdentifier)|cdhash:\(cdHash)"
    }
}

enum CurrentCodeSigningIdentity {
    static func cacheKey() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            code,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            staticCode,
            flags,
            &information
        ) == errSecSuccess,
              let dictionary = information as NSDictionary?,
              let signingIdentifier = dictionary[kSecCodeInfoIdentifier] as? String
        else { return nil }
        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String
        let cdHash = (dictionary[kSecCodeInfoUnique] as? Data)?.map {
            String(format: "%02x", $0)
        }.joined()
        return CodeSigningIdentity(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            cdHash: cdHash
        ).cacheKey
    }
}

enum RecordingPermissionCache {
    static func reusableStatus(
        rawStatus: String?,
        cachedIdentity: String?,
        currentIdentity: String?
    ) -> AudioPermissionStatus? {
        guard let currentIdentity,
              cachedIdentity == currentIdentity,
              let rawStatus,
              let status = AudioPermissionStatus(rawValue: rawStatus),
              status == .authorized || status == .denied
        else { return nil }
        return status
    }
}

enum MeetingListSnapshot {
    static func replacing(_ latest: Meeting, in meetings: [Meeting]) -> [Meeting] {
        guard let index = meetings.firstIndex(where: { $0.id == latest.id }) else {
            return meetings
        }
        var result = meetings
        result[index] = latest
        return result
    }
}

struct RecordingStartState {
    private(set) var isStarting = false
    private var createdMeetingID: MeetingID?

    mutating func begin() -> Bool {
        guard !isStarting else { return false }
        isStarting = true
        createdMeetingID = nil
        return true
    }

    mutating func didCreateMeeting(_ meetingID: MeetingID) {
        guard isStarting else { return }
        createdMeetingID = meetingID
    }

    mutating func succeed() {
        isStarting = false
        createdMeetingID = nil
    }

    mutating func fail() -> MeetingID? {
        let meetingID = createdMeetingID
        isStarting = false
        createdMeetingID = nil
        return meetingID
    }
}
