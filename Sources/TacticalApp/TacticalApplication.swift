import AppKit

@main
@MainActor
struct TacticalApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = TacticalApplicationDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
