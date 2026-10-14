import AppKit
import Metal
import MetalKit
import TacticalCore

/// Metal rendering delegate managing synthetic vision and tactical viewport projection.
@MainActor
public final class TacticalViewportRenderer: NSObject, MTKViewDelegate {
    public private(set) var renderedFrameCount: UInt64 = 0
    public private(set) var latestTelemetryFrame: TelemetryFrame?

    public override init() {
        super.init()
    }

    /// Ingest real-time telemetry frame to drive viewport state rendering.
    public func updateTelemetry(_ frame: TelemetryFrame) {
        self.latestTelemetryFrame = frame
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle viewport dimension change
    }

    public func draw(in view: MTKView) {
        if let frame = latestTelemetryFrame {
            switch frame.interlockState {
            case .locked:
                view.clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1.0)
            case .armed:
                view.clearColor = MTLClearColor(red: 0.18, green: 0.12, blue: 0.02, alpha: 1.0)
            case .permissiveGranted:
                view.clearColor = MTLClearColor(red: 0.02, green: 0.15, blue: 0.05, alpha: 1.0)
            case .emergencyAbort:
                view.clearColor = MTLClearColor(red: 0.25, green: 0.02, blue: 0.02, alpha: 1.0)
            }
        }

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
    public let viewportRenderer: TacticalViewportRenderer
    private var feedObservationTask: Task<Void, Never>?

    public init(frame frameRect: CGRect = .zero) {
        let defaultDevice = MTLCreateSystemDefaultDevice()
        self.commandQueue = defaultDevice?.makeCommandQueue()
        let renderer = TacticalViewportRenderer()
        self.viewportRenderer = renderer

        super.init(frame: frameRect, device: defaultDevice)

        self.delegate = renderer
        self.clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1.0)
        self.enableSetNeedsDisplay = false
        self.isPaused = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported in avionics viewport")
    }

    /// Render telemetry frame onto viewport.
    public func ingestTelemetry(_ frame: TelemetryFrame) {
        viewportRenderer.updateTelemetry(frame)
        setNeedsDisplay(bounds)
    }

    /// Bind viewport to real-time telemetry stream.
    @discardableResult
    public func bindTelemetryStream(_ stream: AsyncStream<TelemetryFrame>) -> Task<Void, Never> {
        feedObservationTask?.cancel()
        let task = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled, let self else { break }
                self.ingestTelemetry(frame)
            }
        }
        self.feedObservationTask = task
        return task
    }

    public func unbindTelemetryStream() {
        feedObservationTask?.cancel()
        feedObservationTask = nil
    }
}
