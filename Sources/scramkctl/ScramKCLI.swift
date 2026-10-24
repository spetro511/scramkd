import Foundation
import ScramKCore

@main
struct ScramKCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "status"
        let gate = HardwareInterlockGate(initialStatus: .armed)

        switch command {
        case "status":
            let current = await gate.currentStatus
            let label = formatStatus(current)
            print("scramkctl status: \(label) [schema: .armed | .locked | .permissiveGranted]")
        case "grant":
            do {
                try await gate.grantPermissive()
                let current = await gate.currentStatus
                print("scramkctl grant: \(formatStatus(current))")
            } catch {
                fputs("scramkctl grant failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        case "abort", "scram", "trip":
            await gate.tripEmergencyAbort(reason: "SCRAMKCTL_ABORT")
            let current = await gate.currentStatus
            print("scramkctl abort: \(formatStatus(current))")
        case "--help", "-h", "help":
            printUsage()
        default:
            fputs("scramkctl: unknown command '\(command)'\n", stderr)
            printUsage()
            Foundation.exit(64)
        }
    }

    private static func formatStatus(_ status: InterlockStatus) -> String {
        switch status {
        case .armed:
            return ".armed"
        case .locked:
            return ".locked"
        case .permissiveGranted:
            return ".permissiveGranted"
        case .emergencyAbort:
            return ".emergencyAbort"
        }
    }

    private static func printUsage() {
        print(
            """
            scramkctl — ScramK Supervisor Interlock Control CLI
            Usage:
              scramkctl status   Query current supervisor interlock state (.armed | .locked | .permissiveGranted)
              scramkctl grant    Grant bounded permissive execution window (.permissiveGranted)
              scramkctl abort    Trigger immediate hardware interlock SCRAM trip (.emergencyAbort)
              scramkctl --help   Display this usage summary
            """
        )
    }
}
