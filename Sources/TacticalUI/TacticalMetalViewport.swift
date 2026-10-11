import AppKit
import Metal
import MetalKit
import TacticalCore

/// Metal rendering delegate managing synthetic vision and tactical viewport projection.
@MainActor
public final class TacticalViewportRenderer: NSObject, MTKViewDelegate {
    public private(set) var renderedFrameCount: UInt64 = 0

    public override init() {
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle viewport dimension change
    }

    public func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandQueue = (view as? TacticalMetalViewportView)?.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        renderedFrameCount += 1
    }
}

/// AppKit Metal viewport view hosting real-time tactical overlays and HUD rendering.
@MainActor
public final class TacticalMetalViewportView: MTKView {
    public let commandQueue: (any MTLCommandQueue)?
    private let viewportRenderer: TacticalViewportRenderer

    public init(frame frameRect: CGRect = .zero) {
        let defaultDevice = MTLCreateSystemDefaultDevice()
        self.commandQueue = defaultDevice?.makeCommandQueue()
        self.viewportRenderer = TacticalViewportRenderer()

        super.init(frame: frameRect, device: defaultDevice)

        self.delegate = viewportRenderer
        self.clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1.0)
        self.enableSetNeedsDisplay = false
        self.isPaused = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported in avionics viewport")
    }
}
