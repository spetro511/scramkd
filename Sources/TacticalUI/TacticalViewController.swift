import AppKit
import MetalKit
import TacticalCore

/// Primary macOS view controller hosting the tactical hypervisor viewport.
@MainActor
public final class TacticalViewController: NSViewController {
    private var viewportView: TacticalMetalViewportView?

    public override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        containerView.wantsLayer = true
        self.view = containerView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureViewport()
    }

    private func configureViewport() {
        let viewport = TacticalMetalViewportView(frame: view.bounds)
        viewport.autoresizingMask = [.width, .height]
        view.addSubview(viewport)
        self.viewportView = viewport
    }
}
