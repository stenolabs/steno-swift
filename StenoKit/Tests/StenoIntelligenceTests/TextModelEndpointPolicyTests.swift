import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Text model endpoint policy")
struct TextModelEndpointPolicyTests {
    @Test("HTTPS and local HTTP endpoints have the required transport classification")
    func classifiesHTTPSAndLocalHTTP() throws {
        #expect(try policy("https://models.example.com/v1") == .encrypted)
        #expect(try policy("http://localhost:1234/v1") == .localPlaintext)
        #expect(try policy("http://studio.local:1234/v1") == .localPlaintext)
        #expect(try policy("http://macbook:1234/v1") == .localPlaintext)
        #expect(try policy("http://192.168.1.10:1234/v1") == .localPlaintext)
        #expect(try policy("http://100.64.10.20:1234/v1") == .localPlaintext)
    }

    @Test("local IPv4 and IPv6 address ranges allow HTTP")
    func acceptsOnlyListedLocalAddressRanges() throws {
        for url in [
            "http://127.0.0.1:1234/v1",
            "http://10.1.2.3:1234/v1",
            "http://172.16.0.1:1234/v1",
            "http://172.31.255.255:1234/v1",
            "http://192.168.0.1:1234/v1",
            "http://169.254.1.1:1234/v1",
            "http://100.64.0.1:1234/v1",
            "http://[::1]:1234/v1",
            "http://[fc00::1]:1234/v1",
            "http://[fdff::1]:1234/v1",
            "http://[fe80::1]:1234/v1",
        ] {
            #expect(try policy(url) == .localPlaintext)
        }
    }

    @Test("remote HTTP and malformed endpoint parts are rejected")
    func rejectsRemoteAndMalformedEndpoints() {
        #expect(throws: TextModelEndpointPolicyError.insecureRemoteURL) {
            try policy("http://models.example.com/v1")
        }
        #expect(throws: TextModelEndpointPolicyError.embeddedCredentials) {
            try policy("https://user:secret@models.example.com/v1")
        }
        for url in [
            "http://172.32.0.1:1234/v1",
            "http://192.167.255.255:1234/v1",
            "http://100.128.0.1:1234/v1",
            "http://[2001:db8::1]:1234/v1",
            "http://134744072:1234/v1",
            "http://0x08080808:1234/v1",
            "ftp://localhost:1234/v1",
            "https:///v1",
            "https://models.example.com/v1?key=value",
            "https://models.example.com/v1#fragment",
        ] {
            #expect(throws: TextModelEndpointPolicyError.self) {
                try policy(url)
            }
        }
    }

    /// Ollama ueber seine OpenAI-Schicht anzusprechen kostet zwei Dinge, die
    /// der eigene Dialekt kann: den Denkmodus abschalten und die
    /// Kontextgroesse setzen. Gemessen an gemma4:12b war das der Unterschied
    /// zwischen einem Ergebnis in 149 Token und gar keinem.
    @Test("an Ollama port suggests the native dialect and drops the /v1 suffix")
    func ollamaPortSuggestsNativeDialect() throws {
        for value in [
            "http://192.168.1.10:11434/v1",
            "http://192.168.1.10:11434/v1/",
            "http://192.168.1.10:11434",
        ] {
            let url = try #require(URL(string: value))
            let suggestion = try #require(TextModelEndpointPolicy.nativeDialectSuggestion(
                baseURL: url,
                dialect: .openAICompatible
            ))
            #expect(suggestion.dialect == .ollama)
            #expect(suggestion.baseURL.absoluteString == "http://192.168.1.10:11434")
        }
    }

    @Test("no suggestion when the endpoint already uses the native dialect")
    func nativeDialectNeedsNoSuggestion() throws {
        let url = try #require(URL(string: "http://192.168.1.10:11434"))
        #expect(TextModelEndpointPolicy.nativeDialectSuggestion(
            baseURL: url,
            dialect: .ollama
        ) == nil)
    }

    /// Der Port ist das einzige Indiz, und es ist nur ein Indiz - deshalb
    /// bleibt es ein Vorschlag. Ohne ihn wird nichts vorgeschlagen.
    @Test("no suggestion for other ports or dialects")
    func otherEndpointsGetNoSuggestion() throws {
        for (value, dialect) in [
            ("http://localhost:8080/v1", TextModelAPIDialect.openAICompatible),
            ("http://localhost:1234/v1", TextModelAPIDialect.lmStudio),
            ("https://api.openai.com/v1", TextModelAPIDialect.openAI),
            ("https://models.example.com:11434/v1", TextModelAPIDialect.openAI),
        ] {
            let url = try #require(URL(string: value))
            #expect(TextModelEndpointPolicy.nativeDialectSuggestion(
                baseURL: url,
                dialect: dialect
            ) == nil)
        }
    }

    private func policy(_ value: String) throws -> TextModelTransportSecurity {
        try TextModelEndpointPolicy.transportSecurity(for: try #require(URL(string: value)))
    }
}
