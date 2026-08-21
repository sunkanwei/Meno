import Darwin
import Foundation
import OSLog

@main
struct MenoPowerHelperMain {
    private static let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "PowerHelper"
    )

    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "--install":
            runInstaller()
        case "--diagnose":
            runDiagnostics()
        case nil:
            runDaemon()
        default:
            fputs("Unsupported argument.\n", stderr)
            exit(EX_USAGE)
        }
    }

    private static func runInstaller() {
        guard geteuid() == 0 else {
            fputs("Administrator privileges are required.\n", stderr)
            exit(EX_NOPERM)
        }
        do {
            try PowerHelperInstaller.install()
            print("Meno power helper installed.")
        } catch {
            fputs("Installation failed: \(error.localizedDescription)\n", stderr)
            exit(EX_SOFTWARE)
        }
    }

    private static func runDiagnostics() {
        let configuration = PowerModeConfiguration.current()
        print("mode=\(configuration?.mode ?? "unavailable")")
        print("lid=\(PowerHelperLidMonitor.currentStateDescription())")
    }

    private static func runDaemon() {
        guard geteuid() == 0 else {
            logger.error("Power helper refused to run without root privileges")
            exit(EX_NOPERM)
        }

        let daemon = PowerHelperDaemon()
        guard daemon.start() else {
            logger.error("Power helper could not start and will remain stopped")
            exit(EX_UNAVAILABLE)
        }
        withExtendedLifetime(daemon) {
            dispatchMain()
        }
    }
}
