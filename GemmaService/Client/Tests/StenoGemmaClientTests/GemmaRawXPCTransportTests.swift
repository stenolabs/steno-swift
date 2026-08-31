import Darwin
import Foundation
@testable import StenoGemmaClient
import StenoGemmaIPC
import Testing
import XPC

@Suite("Gemma raw XPC execution-gate framing")
struct GemmaRawXPCTransportTests {
    @Test("prepared exit identity must exactly match the authenticated bind identity")
    func preparedIdentityMatchesBindIdentity() {
        let helperInstanceID = UUID()
        let bound = GemmaIPCBoundHelperIdentity(
            helperInstanceID: helperInstanceID,
            processIdentifier: 42
        )
        #expect(GemmaRawXPCIdentityValidation.matches(
            prepared: .init(helperInstanceID: helperInstanceID, processIdentifier: 42),
            bound: bound
        ))
        #expect(!GemmaRawXPCIdentityValidation.matches(
            prepared: .init(helperInstanceID: UUID(), processIdentifier: 42),
            bound: bound
        ))
        #expect(!GemmaRawXPCIdentityValidation.matches(
            prepared: .init(helperInstanceID: helperInstanceID, processIdentifier: 43),
            bound: bound
        ))
    }

    @Test("ordinary outer frames have exactly three keys")
    func ordinaryOuterFrameKeys() throws {
        let requestID = UUID()
        let message = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data("frame".utf8),
            requestID: requestID,
            channel: .model
        ))

        #expect(keys(of: message) == Set(["channel", "frame", "requestID"]))
        let decoded = try #require(GemmaRawXPCOuterFrame.decode(message))
        #expect(decoded.requestID == requestID)
        #expect(decoded.channel == .model)
        #expect(decoded.frame == Data("frame".utf8))
    }

    @Test("the bind outer frame adds only one typed descriptor key")
    func bindOuterFrameDescriptor() throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&descriptors) == 0)
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }

        let message = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data("bind-json".utf8),
            requestID: UUID(),
            channel: .control,
            executionGateDescriptor: descriptors[0]
        ))
        #expect(keys(of: message) == Set([
            "channel", "executionGateFD", "frame", "requestID",
        ]))
        let descriptorObject = try #require(
            xpc_dictionary_get_value(message, GemmaRawXPCOuterFrame.executionGateFDKey)
        )
        #expect(xpc_get_type(descriptorObject) == XPC_TYPE_FD)

        let duplicated = xpc_fd_dup(descriptorObject)
        #expect(duplicated >= 0)
        if duplicated >= 0 {
            _ = Darwin.close(duplicated)
        }

        // Client replies must remain ordinary three-key frames.
        #expect(GemmaRawXPCOuterFrame.decode(message) == nil)
    }

    @Test("reply decoding rejects every extra outer key")
    func replyRejectsExtraOuterKey() throws {
        let message = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data(),
            requestID: UUID(),
            channel: .control
        ))
        xpc_dictionary_set_bool(message, "unexpected", true)
        #expect(GemmaRawXPCOuterFrame.decode(message) == nil)
    }

    private func keys(of dictionary: xpc_object_t) -> Set<String> {
        var result = Set<String>()
        _ = xpc_dictionary_apply(dictionary) { key, _ in
            result.insert(String(cString: key))
            return true
        }
        return result
    }
}
