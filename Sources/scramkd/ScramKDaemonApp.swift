import AppKit

@main
@MainActor
struct ScramKDaemonApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = ScramKApplicationDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
