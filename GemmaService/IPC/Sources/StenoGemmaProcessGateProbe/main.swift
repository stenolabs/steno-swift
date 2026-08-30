import Darwin
import Foundation
import StenoGemmaProcessGate

/// UI-less process probe for manual and automated gate validation.
///
/// It prints `ready` only after the requested lease is held and releases the descriptor when
/// stdin closes or receives one line. Tests use pipes instead of timing sleeps.
@main
struct StenoGemmaProcessGateProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              let configuration = try? GemmaProcessGateConfiguration(
                directoryURL: URL(fileURLWithPath: arguments[2], isDirectory: true)
              )
        else {
            fputs(
                "usage: steno-gemma-gate-probe <model|recording|adopt-model-stdin> <gate-directory>\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }

        let gate = GemmaProcessGate(configuration: configuration)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        do {
            switch arguments[1] {
            case "model":
                let lease = try gate.acquireModelExecution()
                print("ready")
                fflush(stdout)
                _ = readLine()
                lease.close()
            case "recording":
                let lease = try await gate.acquireRecordingLease(until: deadline)
                print("ready")
                fflush(stdout)
                _ = readLine()
                lease.close()
            case "adopt-model-stdin":
                let lease = try GemmaProcessGate.adoptHelperExecutionDescriptor(STDIN_FILENO)
                print("ready")
                fflush(stdout)
                while true {
                    _ = Darwin.pause()
                }
                lease.close()
            default:
                throw GemmaProcessGateError.invalidConfiguration
            }
        } catch {
            fputs("gate acquisition failed\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
