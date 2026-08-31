import Foundation
import StenoDomain

public enum StructuredTextModelJSONContractError: Error, Equatable, Sendable {
    case invalidOutput
}

/// A transport-neutral, strict JSON contract for local text-model adapters.
///
/// The returned prompt is the complete text that must be counted and generated. Keeping this
/// assembly in `StenoIntelligence` prevents an app-specific adapter from approximating a different
/// prompt during token budgeting. The decoder accepts no prose or code fence around the JSON.
public enum StructuredTextModelJSONContract {
    public static func prompt(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) -> String {
        """
        System instructions:
        \(StructuredTemplatePrompt.instructions(for: template, context: context))

        User request:
        \(StructuredTemplatePrompt.prompt(for: request, template: template, context: context))

        Required JSON shape example:
        \(StructuredTemplateCodec.stringJSONShapeExample(for: template))
        """
    }

    public static func decode(
        _ text: String,
        template: Template
    ) throws -> StructuredTemplateOutput {
        do {
            return try StructuredTemplateCodec.decode(
                Data(text.utf8),
                template: template,
                allowsOuterJSONCodeFence: false
            )
        } catch {
            throw StructuredTextModelJSONContractError.invalidOutput
        }
    }
}
