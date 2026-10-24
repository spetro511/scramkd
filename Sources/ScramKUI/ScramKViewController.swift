import AppKit
import MetalKit
import ScramKCore

/// Primary macOS view controller hosting the ScramK supervisor viewport.
@MainActor
public final class ScramKViewController: NSViewController {
    private var viewportView: ScramKMetalViewportView?

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
        let viewport = ScramKMetalViewportView(frame: view.bounds)
        viewport.autoresizingMask = [.width, .height]
        view.addSubview(viewport)
        self.viewportView = viewport
    }
}
