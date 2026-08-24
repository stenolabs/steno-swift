import Foundation
import StenoDomain

/// Der satzfeste, synthetische Testtext fuer Factory.probe. Er ist bewusst
/// kein Meeting-Inhalt: ein Verbindungstest darf niemals echten
/// Besprechungstext an einen fremden Server schicken, auch nicht bei einem
/// Endpunkt, den der Nutzer selbst konfiguriert hat.
private let syntheticProbeText = "Synthetic connection test"

/// Die einzige Konstruktionsstelle fuer externe (nicht-Apple) Textmodell-
/// Provider. Validiert den Endpunkt per TextModelEndpointPolicy und waehlt
/// anhand des Dialekts den passenden Provider. openAICompatible, ollama und
/// lmStudio sind konfigurierbar; jeder andere Dialekt wirft
/// unsupportedDialect, auch wenn die Policy ihn irgendwann zulaesst, bevor
/// diese Datei den passenden Fall bekommen hat.
public enum ExternalTextModelProviderFactory {
    public static func makeProvider(
        for endpoint: TextModelEndpoint,
        resolvingSecret: @escaping TextModelSecretResolving = { _ in nil },
        sessionConfiguration: URLSessionConfiguration = .default
    ) throws -> any StructuredTextModelProvider {
        try makeValidatedProvider(
            for: endpoint,
            resolvingSecret: resolvingSecret,
            sessionConfiguration: sessionConfiguration
        )
    }

    /// Prueft erst die Modellliste und, wenn der Endpunkt erreichbar ist und
    /// das konfigurierte Modell fuehrt, danach eine synthetische
    /// strukturierte Generierung. Es verlaesst kein Meeting-Inhalt das
    /// Geraet: der gesendete Satz ist fest verdrahtet. Ollama und LM Studio
    /// fuehren beide Schritte bereits in ihrem eigenen probe() zusammen;
    /// nur der generische openAICompatible-Pfad braucht die zweistufige
    /// Verdrahtung hier.
    public static func probe(
        endpoint: TextModelEndpoint,
        resolvingSecret: @escaping TextModelSecretResolving = { _ in nil },
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> TextModelProbeResult {
        let provider = try makeValidatedProvider(
            for: endpoint,
            resolvingSecret: resolvingSecret,
            sessionConfiguration: sessionConfiguration
        )
        if let ollama = provider as? OllamaProvider {
            return try await ollama.probe()
        }
        if let lmStudio = provider as? LMStudioProvider {
            return try await lmStudio.probe()
        }
        if let generic = provider as? OpenAICompatibleProvider {
            return try await probeGeneric(generic, endpoint: endpoint)
        }
        // openAI, anthropic und amazonBedrock kennen keine separate
        // Modellliste; die synthetische strukturierte Generierung ist hier
        // gleichzeitig der Erreichbarkeits- und der Faehigkeitstest. Ein
        // Fehlschlag wirft, statt einen Teilzustand vorzutaeuschen.
        let start = ContinuousClock.now
        _ = try await provider.generate(
            template: .meetingMinutes,
            request: .map(TranscriptChunk(turns: [
                TranscriptChunkTurn(
                    speakerName: "Steno",
                    start: 0,
                    end: 0,
                    text: syntheticProbeText
                ),
            ])),
            context: .empty
        )
        let elapsed = start.duration(to: .now).components
        let elapsedMilliseconds = Int(
            elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        )
        return TextModelProbeResult(
            isReachable: true,
            isModelAvailable: true,
            supportsStructuredGeneration: true,
            configuredContextWindowTokens: endpoint.contextWindowTokens,
            durationMilliseconds: elapsedMilliseconds
        )
    }

    private static func probeGeneric(
        _ generic: OpenAICompatibleProvider,
        endpoint: TextModelEndpoint
    ) async throws -> TextModelProbeResult {
        let start = ContinuousClock.now
        let reachability = try await generic.probe(endpoint: endpoint)
        guard reachability.isReachable, reachability.isModelAvailable else {
            return reachability
        }
        var supportsStructuredGeneration = false
        do {
            _ = try await generic.generate(
                template: .meetingMinutes,
                request: .map(TranscriptChunk(turns: [
                    TranscriptChunkTurn(
                        speakerName: "Steno",
                        start: 0,
                        end: 0,
                        text: syntheticProbeText
                    ),
                ])),
                context: .empty
            )
            supportsStructuredGeneration = true
        } catch {
            supportsStructuredGeneration = false
        }
        let elapsed = start.duration(to: .now).components
        let elapsedMilliseconds = Int(
            elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        )
        return TextModelProbeResult(
            isReachable: reachability.isReachable,
            isModelAvailable: reachability.isModelAvailable,
            supportsStructuredGeneration: supportsStructuredGeneration,
            configuredContextWindowTokens: endpoint.contextWindowTokens,
            durationMilliseconds: elapsedMilliseconds
        )
    }

    /// Die tatsaechliche Validierung und der Dialekt-Switch, geteilt von
    /// makeProvider und probe: beide sollen denselben Endpunkt auf dieselbe
    /// Weise ablehnen. S6 ergaenzt hier die drei Cloud-Faelle.
    private static func makeValidatedProvider(
        for endpoint: TextModelEndpoint,
        resolvingSecret: @escaping TextModelSecretResolving,
        sessionConfiguration: URLSessionConfiguration
    ) throws -> any StructuredTextModelProvider {
        let validated = try TextModelEndpointPolicy.validate(endpoint)
        switch validated.dialect {
        case .openAICompatible:
            return OpenAICompatibleProvider(
                endpoint: validated,
                resolvingSecret: resolvingSecret,
                sessionConfiguration: sessionConfiguration
            )
        case .ollama:
            return OllamaProvider(
                endpoint: validated,
                resolvingSecret: resolvingSecret,
                sessionConfiguration: sessionConfiguration
            )
        case .lmStudio:
            return LMStudioProvider(
                endpoint: validated,
                resolvingSecret: resolvingSecret,
                sessionConfiguration: sessionConfiguration
            )
        case .openAI:
            return OpenAIResponsesProvider(
                endpoint: validated,
                resolvingSecret: resolvingSecret,
                sessionConfiguration: sessionConfiguration
            )
        case .anthropic:
            return AnthropicMessagesProvider(
                endpoint: validated,
                resolvingSecret: resolvingSecret,
                sessionConfiguration: sessionConfiguration
            )
        case .amazonBedrock:
            return AmazonBedrockProvider(
                endpoint: validated,
                resolvingSecret: resolvingSecret,
                sessionConfiguration: sessionConfiguration
            )
        }
    }
}
