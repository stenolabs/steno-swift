import Foundation

public enum GemmaCodeRole: Sendable {
    case application
    case helper
}

/// Pure policy for the code-signing properties accepted by native Gemma peers.
public enum GemmaCodeSecurityProfile {
    // Security.framework does not import kSecCodeSignatureRuntime into Swift.
    // This is its documented SecCodeSignatureFlags value from CSCommon.h.
    private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000

    private static let hardenedRuntimeExceptionEntitlements = [
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.debugger",
    ]

    public static func isSafe(
        entitlements: [String: Any]?,
        codeDirectoryFlags: UInt32,
        role: GemmaCodeRole,
        allowsDebugging: Bool
    ) -> Bool {
        let values = entitlements ?? [:]
        let requiresHardenedRuntime: Bool
        switch role {
        case .application:
            requiresHardenedRuntime = !allowsDebugging
        case .helper:
            requiresHardenedRuntime = true
        }
        guard !requiresHardenedRuntime
                || codeDirectoryFlags & hardenedRuntimeFlag != 0,
              allowsDebugging
                || (values["com.apple.security.get-task-allow"] as? Bool) != true,
              !hardenedRuntimeExceptionEntitlements.contains(where: {
                  (values[$0] as? Bool) == true
              })
        else {
            return false
        }

        switch role {
        case .application:
            return true
        case .helper:
            return (values["com.apple.security.app-sandbox"] as? Bool) == true
                && (values["com.apple.security.network.client"] as? Bool) != true
                && (values["com.apple.security.network.server"] as? Bool) != true
        }
    }
}
