import AppKit
import SwiftUI
import TacticalUI

@MainActor
final class TacticalConsoleWindow: NSWindow {
    static let canvasSize = NSSize(width: 1440, height: 900)

    init(controller: ConsoleStateController) {
        let canvas = Self.canvasSize
        super.init(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "MOSDEF // TACTICAL HYPERVISOR"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isRestorable = false
        collectionBehavior = [.fullScreenNone]
        colorSpace = .displayP3
        // Reference sRGB #030508; AppKit color management converts for the P3 window.
        backgroundColor = NSColor(srgbRed: 3.0 / 255, green: 5.0 / 255, blue: 8.0 / 255, alpha: 1)

        let root = TacticalConsoleView(controller: controller)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .ignoresSafeArea()
        let hostingView = ConsoleHostingView(rootView: root)
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: canvas)
        contentView = hostingView
        setContentSize(canvas)
        contentMinSize = canvas
        contentMaxSize = canvas

        // Static node-label portion of the custom 44-point header only. Native
        // controls occupy x < 78; no workspace, audit text, or button is draggable.
        let dragRegion = ConsoleWindowDragRegion(
            frame: NSRect(
                x: 84,
                y: hostingView.isFlipped ? 0 : canvas.height - 44,
                width: 240,
                height: 44
            )
        )
        dragRegion.autoresizingMask = hostingView.isFlipped ? [.maxYMargin] : [.minYMargin]
        hostingView.addSubview(dragRegion)
    }
}

@MainActor
private final class ConsoleHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class ConsoleWindowDragRegion: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
