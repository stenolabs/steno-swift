import Testing
@testable import StenoGemmaIPC

@Suite("Gemma code security profile")
struct GemmaCodeSecurityProfileTests {
    private let hardenedRuntime: UInt32 = 0x0001_0000

    @Test("Release helper requires runtime, sandbox, no network, and no debugging")
    func releaseHelperProfile() {
        let sandboxed: [String: Any] = [
            "com.apple.security.app-sandbox": true,
        ]
        #expect(isSafe(
            sandboxed,
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            sandboxed,
            flags: 0,
            role: .helper,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            ["com.apple.security.app-sandbox": false],
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.network.client": true,
            ],
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.network.server": true,
            ],
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.get-task-allow": true,
            ],
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: false
        ))
    }

    @Test("Debug policy permits app debugging but never an unhardened helper")
    func debugProfile() {
        let debuggableApp = ["com.apple.security.get-task-allow": true]
        #expect(isSafe(
            debuggableApp,
            flags: 0,
            role: .application,
            allowsDebugging: true
        ))
        #expect(!isSafe(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.get-task-allow": true,
            ],
            flags: 0,
            role: .helper,
            allowsDebugging: true
        ))
        #expect(isSafe(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.get-task-allow": true,
            ],
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: true
        ))
    }

    @Test("Release app accepts only hardened non-debuggable code")
    func releaseApplicationProfile() {
        let resourceEntitlements: [String: Any] = [
            "com.apple.security.device.audio-input": true,
            "com.apple.security.personal-information.calendars": true,
        ]
        #expect(isSafe(
            resourceEntitlements,
            flags: hardenedRuntime,
            role: .application,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            resourceEntitlements,
            flags: 0,
            role: .application,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            ["com.apple.security.get-task-allow": true],
            flags: hardenedRuntime,
            role: .application,
            allowsDebugging: false
        ))
    }

    @Test(
        "Hardened Runtime exception entitlements are always rejected",
        arguments: [
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.disable-executable-page-protection",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.debugger",
        ]
    )
    func rejectsHardenedRuntimeException(_ key: String) {
        let entitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            key: true,
        ]
        #expect(!isSafe(
            entitlements,
            flags: hardenedRuntime,
            role: .helper,
            allowsDebugging: false
        ))
        #expect(!isSafe(
            entitlements,
            flags: hardenedRuntime,
            role: .application,
            allowsDebugging: false
        ))
    }

    private func isSafe(
        _ entitlements: [String: Any]?,
        flags: UInt32,
        role: GemmaCodeRole,
        allowsDebugging: Bool
    ) -> Bool {
        GemmaCodeSecurityProfile.isSafe(
            entitlements: entitlements,
            codeDirectoryFlags: flags,
            role: role,
            allowsDebugging: allowsDebugging
        )
    }
}
