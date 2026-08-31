import Darwin
import Foundation
import StenoGemmaModelStore
import StenoGemmaPrototypeCLI
import StenoGemmaRuntime

@main
enum StenoGemmaServiceCommand {
    static func main() {
        do {
            switch try Command.parse(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                print(Command.usage)
            case .selfCheck:
                try writeResponse(.selfCheck)
            case .verify(let options):
                let requirements = try GemmaModelRequirements(
                    modelIdentifier: options.modelIdentifier,
                    checkpointRevision: options.checkpointRevision,
                    adapterRevision: GemmaServiceBuildInfo.adapterRevision,
                    licenseIdentifier: options.licenseIdentifier,
                    manifestFileName: options.manifestFileName,
                    expectedManifestSHA256: options.manifestSHA256
                )
                let verified = try GemmaModelVerifier(requirements: requirements).verify(
                    directory: options.modelDirectory
                )

                // Constructing the adapter proves the Foundation Models bridge and local-only
                // source wiring without loading weights or running Metal inference.
                _ = try GemmaLanguageModelFactory.makePrototypePathBackedLanguageModel(
                    from: verified
                )

                try writeResponse(.verified(verified))
            }
        } catch {
            let response = ServiceResponse.failure(error.localizedDescription)
            try? writeResponse(response, to: .standardError)
            exit(EXIT_FAILURE)
        }
    }

    private static func writeResponse(
        _ response: ServiceResponse,
        to handle: FileHandle = .standardOutput
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(response)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private enum Command {
    case help
    case selfCheck
    case verify(VerificationOptions)

    static let usage = """
    Usage:
      steno-gemma-service --self-check
      steno-gemma-service --verify-model MODEL_DIRECTORY \\
        --model-identifier MODEL_IDENTIFIER \\
        --checkpoint-revision CHECKPOINT_REVISION \\
        --license-identifier LICENSE_IDENTIFIER \\
        --manifest-sha256 EXPECTED_MANIFEST_SHA256 \\
        [--manifest-file-name FILE_NAME]

    Verification constructs the local Foundation Models adapter but does not load or run the model.
    """

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else {
            throw CommandError.missingCommand
        }
        switch first {
        case "--help", "-h":
            guard arguments.count == 1 else { throw CommandError.unexpectedArguments }
            return .help
        case "--self-check":
            guard arguments.count == 1 else { throw CommandError.unexpectedArguments }
            return .selfCheck
        case "--verify-model":
            return .verify(try VerificationOptions.parse(arguments))
        default:
            throw CommandError.unknownCommand(first)
        }
    }
}

private struct VerificationOptions {
    let modelDirectory: URL
    let modelIdentifier: String
    let checkpointRevision: String
    let licenseIdentifier: String
    let manifestSHA256: String
    let manifestFileName: String

    static func parse(_ arguments: [String]) throws -> VerificationOptions {
        guard arguments.count >= 2 else {
            throw CommandError.missingValue("--verify-model")
        }

        guard !arguments[1].hasPrefix("--") else {
            throw CommandError.missingValue("--verify-model")
        }
        let modelDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        var values: [String: String] = [:]
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            guard supportedOptions.contains(option) else {
                throw CommandError.unknownOption(option)
            }
            guard values[option] == nil else {
                throw CommandError.duplicateOption(option)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
                throw CommandError.missingValue(option)
            }
            values[option] = arguments[valueIndex]
            index += 2
        }

        return VerificationOptions(
            modelDirectory: modelDirectory,
            modelIdentifier: try requiredValue("--model-identifier", in: values),
            checkpointRevision: try requiredValue("--checkpoint-revision", in: values),
            licenseIdentifier: try requiredValue("--license-identifier", in: values),
            manifestSHA256: try requiredValue("--manifest-sha256", in: values),
            manifestFileName: values["--manifest-file-name"] ?? "gemma-model-manifest.json"
        )
    }

    private static let supportedOptions: Set<String> = [
        "--model-identifier",
        "--checkpoint-revision",
        "--license-identifier",
        "--manifest-sha256",
        "--manifest-file-name",
    ]

    private static func requiredValue(
        _ option: String,
        in values: [String: String]
    ) throws -> String {
        guard let value = values[option] else {
            throw CommandError.missingOption(option)
        }
        return value
    }
}

private enum CommandError: Error, LocalizedError {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(String)
    case duplicateOption(String)
    case missingOption(String)
    case missingValue(String)
    case unexpectedArguments

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            "A command is required. Run with --help for usage."
        case .unknownCommand(let command):
            "Unknown command: \(command)."
        case .unknownOption(let option):
            "Unknown option: \(option)."
        case .duplicateOption(let option):
            "Option supplied more than once: \(option)."
        case .missingOption(let option):
            "Required option is missing: \(option)."
        case .missingValue(let option):
            "Option requires a value: \(option)."
        case .unexpectedArguments:
            "This command does not accept additional arguments."
        }
    }
}

private struct ServiceResponse: Codable {
    let status: String
    let protocolVersion: Int
    let adapterRevision: String
    let modelIdentifier: String?
    let checkpointRevision: String?
    let licenseIdentifier: String?
    let message: String?

    static let selfCheck = ServiceResponse(
        status: "ok",
        protocolVersion: GemmaServiceBuildInfo.protocolVersion,
        adapterRevision: GemmaServiceBuildInfo.adapterRevision,
        modelIdentifier: nil,
        checkpointRevision: nil,
        licenseIdentifier: nil,
        message: nil
    )

    static func verified(_ model: VerifiedGemmaModel) -> ServiceResponse {
        ServiceResponse(
            status: "verified",
            protocolVersion: GemmaServiceBuildInfo.protocolVersion,
            adapterRevision: GemmaServiceBuildInfo.adapterRevision,
            modelIdentifier: model.modelIdentifier,
            checkpointRevision: model.checkpointRevision,
            licenseIdentifier: model.licenseIdentifier,
            message: nil
        )
    }

    static func failure(_ message: String) -> ServiceResponse {
        ServiceResponse(
            status: "error",
            protocolVersion: GemmaServiceBuildInfo.protocolVersion,
            adapterRevision: GemmaServiceBuildInfo.adapterRevision,
            modelIdentifier: nil,
            checkpointRevision: nil,
            licenseIdentifier: nil,
            message: message
        )
    }
}
