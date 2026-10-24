import AppKit
import CoreGraphics
import Metal
import MetalKit
import ScramKCore
import ScramKVirtualization

/// Resource/drawability/submission status, not completed display presentation.
public enum ScramKViewportAvailability: Equatable, Sendable {
    case ready
    case submitted
    case waitingForDrawable
    case waitingForGPU
    case unavailable(String)
    case stopped

    var summary: String {
        switch self {
        case .ready: "METAL RESOURCES READY"
        case .submitted: "FRAME SUBMITTED; COMPLETION UNVERIFIED"
        case .waitingForDrawable: "DRAWABLE UNAVAILABLE"
        case .waitingForGPU: "GPU SUBMISSION LIMIT; FRAME DEFERRED"
        case .unavailable(let reason): reason
        case .stopped: "RENDERER STOPPED"
        }
    }
}

/// Reference hex/triplet values are encoded sRGB. Shader outputs and clears are
/// linear Display P3; the sRGB render target applies the shared transfer curve.
enum ScramKViewportColor {
    static let backgroundHex: UInt32 = 0x030509

    static let canvasReferenceSRGB = SIMD3<Double>(3.0 / 255, 5.0 / 255, 9.0 / 255)
    static var canvasClearColor: MTLClearColor {
        let rgb = linearDisplayP3(encodedSRGB: canvasReferenceSRGB)
        return MTLClearColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
    }

    static func clearReferenceSRGB(status: InterlockStatus) -> SIMD3<Double> {
        switch status {
        case .locked: SIMD3(0.012, 0.020, 0.035)
        case .armed: SIMD3(0.035, 0.025, 0.010)
        case .permissiveGranted: SIMD3(0.010, 0.040, 0.020)
        case .emergencyAbort: SIMD3(0.060, 0.010, 0.010)
        }
    }

    /// Pure conversion; no device, view, or renderer state is required.
    static func clearColor(status: InterlockStatus) -> MTLClearColor {
        let rgb = linearDisplayP3(encodedSRGB: clearReferenceSRGB(status: status))
        return MTLClearColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
    }

    static func linearDisplayP3(
        hex: UInt32, opacity: Float = 1, backgroundSRGB: SIMD3<Double>? = nil
    ) -> SIMD3<Float> {
        let background = backgroundSRGB ?? encodedSRGB(hex: backgroundHex)
        let source = encodedSRGB(hex: hex)
        // Match the reference's legacy CSS sRGB alpha compositing before decoding.
        let alpha = Double(min(1, max(0, opacity)))
        let encoded = alpha == 1 ? source : background + (source - background) * alpha
        let rgb = linearDisplayP3(encodedSRGB: encoded)
        return SIMD3<Float>(Float(rgb.x), Float(rgb.y), Float(rgb.z))
    }

    private static func linearDisplayP3(encodedSRGB encoded: SIMD3<Double>) -> SIMD3<Double> {
        let rgb = SIMD3<Double>(decode(encoded.x), decode(encoded.y), decode(encoded.z))
        // D65 sRGB -> D65 Display P3; no white-point adaptation is needed.
        return SIMD3<Double>(
            0.8224619687 * rgb.x + 0.1775380313 * rgb.y,
            0.0331941989 * rgb.x + 0.9668058011 * rgb.y,
            0.0170826307 * rgb.x + 0.0723974407 * rgb.y + 0.9105199286 * rgb.z
        )
    }

    private static func encodedSRGB(hex: UInt32) -> SIMD3<Double> {
        SIMD3<Double>(Double((hex >> 16) & 0xff), Double((hex >> 8) & 0xff), Double(hex & 0xff)) / 255
    }

    private static func decode(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}

enum ScramKViewportDrawability {
    static func hasValidExtents(logicalSize: CGSize, drawableSize: CGSize) -> Bool {
        let extents = [logicalSize.width, logicalSize.height, drawableSize.width, drawableSize.height]
        return extents.allSatisfy { $0.isFinite && $0 > 0 && Float($0).isFinite && Float($0) > 0 }
            && drawableSize.width >= 1 && drawableSize.height >= 1
    }
}

/// Matches the MSL vertex's float2 / float4 alignment (32-byte stride).
struct ScramKViewportVertex: Equatable, Sendable {
    let position: SIMD2<Float>
    let color: SIMD4<Float>
}

/// Pure CPU projection of reported state. It contains no clock, host metrics,
/// guest framebuffer, animation, or authorization logic.
struct ScramKViewportGeometry: Equatable, Sendable {
    let vertices: [ScramKViewportVertex]

    static func make(
        size: CGSize,
        status: InterlockStatus,
        telemetryHealth: SubsystemHealth?,
        increasedContrast: Bool = false,
        backgroundSRGB: SIMD3<Double>? = nil
    ) -> Self {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return Self(vertices: [])
        }
        let width = Float(size.width)
        let height = Float(size.height)
        guard width.isFinite, height.isFinite else { return Self(vertices: []) }
        var vertices: [ScramKViewportVertex] = []
        vertices.reserveCapacity(400)

        func color(_ hex: UInt32, opacity: Float = 1) -> SIMD4<Float> {
            let rgb = ScramKViewportColor.linearDisplayP3(
                hex: hex, opacity: opacity,
                backgroundSRGB: backgroundSRGB ?? ScramKViewportColor.clearReferenceSRGB(status: status)
            )
            return SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
        }

        func rectangle(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ tint: SIMD4<Float>) {
            guard w > 0, h > 0 else { return }
            let a = ScramKViewportVertex(position: SIMD2(x, y), color: tint)
            let b = ScramKViewportVertex(position: SIMD2(x + w, y), color: tint)
            let c = ScramKViewportVertex(position: SIMD2(x, y + h), color: tint)
            let d = ScramKViewportVertex(position: SIMD2(x + w, y + h), color: tint)
            vertices.append(contentsOf: [a, b, c, b, d, c])
        }

        func outline(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ tint: SIMD4<Float>) {
            rectangle(x, y, w, 1, tint)
            rectangle(x, y + h - 1, w, 1, tint)
            rectangle(x, y + 1, 1, h - 2, tint)
            rectangle(x + w - 1, y + 1, 1, h - 2, tint)
        }

        let grid = color(0x1E293B, opacity: increasedContrast ? 0.45 : 0.10)
        for column in 1..<6 {
            rectangle((width * Float(column) / 6).rounded(), 0, 1, height, grid)
        }
        for row in 1..<4 {
            rectangle(0, (height * Float(row) / 4).rounded(), width, 1, grid)
        }
        // Static scan lines only; ruler ticks and target annotations belong to
        // SwiftUI above this drawable, not to a second Metal target overlay.
        let scan = color(0x1E293B, opacity: increasedContrast ? 0.30 : 0.06)
        for row in [1, 7] {
            let y = (height * Float(row) / 8).rounded()
            rectangle(0, y, width, 1, scan)
        }

        let stateHex: UInt32
        switch status {
        case .locked: stateHex = 0x475569
        case .armed: stateHex = 0xF59E0B
        case .permissiveGranted: stateHex = 0x10B981
        case .emergencyAbort: stateHex = 0xEF4444
        }
        let stateColor = color(stateHex)
        let selectedCategory: Int
        switch status {
        case .locked: selectedCategory = 0
        case .armed: selectedCategory = 1
        case .permissiveGranted: selectedCategory = 2
        case .emergencyAbort: selectedCategory = 3
        }
        // Lower-right one-hot categorical state band, not a target reticle,
        // utilization meter, or progressive readiness indicator.
        let x = max(12, width - 84).rounded()
        let y = max(12, height - 56).rounded()
        outline(x, y, 64, 16, stateColor)
        for category in 0..<4 {
            outline(x + 5 + Float(category) * 14, y + 4, 8, 8, stateColor)
        }
        rectangle(x + 7 + Float(selectedCategory) * 14, y + 6, 4, 4, stateColor)
        rectangle(x + 5 + Float(selectedCategory) * 14, y + 16, 8, 2, stateColor)

        // A reported health glyph only appears when a real TelemetryFrame exists.
        // It is categorical, not a utilization/progress meter.
        if let telemetryHealth {
            let count: Int
            let healthColor: SIMD4<Float>
            switch telemetryHealth {
            case .nominal: (count, healthColor) = (1, color(0x10B981))
            case .degraded: (count, healthColor) = (2, color(0xF59E0B))
            case .critical: (count, healthColor) = (3, color(0xEF4444))
            case .offline: (count, healthColor) = (0, color(0x475569))
            }
            outline(12, height - 22, 32, 10, healthColor)
            for index in 0..<count {
                rectangle(15 + Float(index) * 9, height - 19, 6, 4, healthColor)
            }
        }
        return Self(vertices: vertices)
    }
}

/// Main-actor Metal delegate. Optional framebuffer input is explicit; default
/// operation remains the native interlock geometry with no remote source.
/// The SDK's MTKViewDelegate callbacks are NS_SWIFT_UI_ACTOR annotated; no
/// unchecked Sendable conformance or suppression of delegate isolation is used.
@MainActor
public final class ScramKViewportRenderer: NSObject, MTKViewDelegate {
    /// Command buffers committed with clear + primitives; not completed/presented frames.
    public private(set) var renderedFrameCount: UInt64 = 0
    public private(set) var lastSubmittedVertexCount: Int = 0
    public private(set) var lastSubmittedInterlockStatus: InterlockStatus?
    public private(set) var lastSubmittedClearColor: MTLClearColor?
    public private(set) var latestTelemetryFrame: TelemetryFrame?
    public private(set) var availability: ScramKViewportAvailability = .unavailable("METAL NOT CONFIGURED")
    public private(set) var configurationFailure: String?
    public private(set) var increasedContrast = false
    public private(set) var encodedDrawCallsCount: UInt64 = 0

    public var metricSnapshot: ScramKViewportMetricSnapshot {
        ScramKViewportMetricSnapshot(
            submittedFrames: renderedFrameCount, encodedDrawCallsCount: encodedDrawCallsCount,
            uploadedFrameSequence: framebuffer.image?.sequence, uploadedGeneration: framebuffer.image?.generation,
            busyDropCounts: framebuffer.busyDropCounts, rejectedFrameCount: framebuffer.rejectedFrameCount,
            gpuFailureCount: framebuffer.gpuFailureCount, residentTextureBytes: framebuffer.residentTextureBytes,
            pendingCPUFrameBytes: framebuffer.pendingCPUFrameBytes, inFlightReadCounts: framebuffer.ownership.inFlightReadCounts,
            framebufferConfigured: framebuffer.configured, isImageAvailable: framebuffer.image != nil
        )
    }

    public var framebufferSummary: String {
        guard framebuffer.configured else { return "NO GUEST DISPLAY FEED." }
        guard let image = framebuffer.image else {
            return "CONTAINER DETACHED. \(framebuffer.failure ?? "FRAMEBUFFER IMAGE UNAVAILABLE")."
        }
        return "FRAMEBUFFER RECEIVED: \(image.layout.width) BY \(image.layout.height), SEQUENCE \(image.sequence). COLOR PROFILE: ASSUMED sRGB. PRESENTATION UNVERIFIED."
    }

    /// Explicit controller state takes precedence over an optional telemetry feed.
    public var interlockStatus: InterlockStatus {
        explicitInterlockStatus ?? latestTelemetryFrame?.interlockState ?? .locked
    }

    var hasConfiguredPipeline: Bool { pipeline != nil }

    private var explicitInterlockStatus: InterlockStatus?
    private var pipeline: (any MTLRenderPipelineState)?
    private var vertexBuffer: (any MTLBuffer)?
    private var cachedGeometry: ScramKViewportGeometry?
    private var cachedSize: CGSize?
    private var cachedStatus: InterlockStatus?
    private var cachedHealth: SubsystemHealth?
    private let framebuffer = ScramKFramebufferSurface()
    private var stopped = false

    var framebufferSourceConfigured: Bool { framebuffer.configured }
    /// Explicit frame input. Validates packed layout, cap, encoding, generation,
    /// and monotonic source sequence before touching GPU resources. No connect.
    public func updateFramebuffer(_ frame: RGBAFrame) {
        guard !stopped else { return }
        let previousMode = framebuffer.configured
        framebuffer.enqueue(frame)
        if previousMode != framebuffer.configured { invalidateGeometry() }
    }

    /// Retires image admission and clears pending pixels immediately. An explicit
    /// new generation/delivery is required before later frames can be accepted.
    public func clearFramebuffer() {
        framebuffer.clear()
    }

    public func setFramebufferSourceConfigured(_ enabled: Bool) {
        guard !stopped, framebuffer.configured != enabled else { return }
        framebuffer.setConfigured(enabled)
        invalidateGeometry()
    }

    public func beginFramebufferGeneration(_ generation: UUID) {
        guard !stopped else { return }
        let previousMode = framebuffer.configured
        framebuffer.beginGeneration(generation)
        if previousMode != framebuffer.configured { invalidateGeometry() }
    }

    public override init() {
        super.init()
    }

    /// Stores supplied telemetry without inventing host or guest metrics.
    public func updateTelemetry(_ frame: TelemetryFrame) {
        latestTelemetryFrame = frame
    }

    public func updateInterlockStatus(_ status: InterlockStatus) {
        explicitInterlockStatus = status
    }

    public func updateIncreasedContrast(_ enabled: Bool) {
        guard increasedContrast != enabled else { return }
        increasedContrast = enabled
        invalidateGeometry()
    }

    func clearTelemetry() {
        latestTelemetryFrame = nil
    }

    func configure(for view: ScramKMetalViewportView) {
        guard view.colorspace != nil else {
            availability = .unavailable("DISPLAY P3 UNAVAILABLE")
            return
        }
        guard let device = view.device else {
            availability = .unavailable("METAL DEVICE UNAVAILABLE")
            return
        }
        framebuffer.setDevice(device)
        guard view.commandQueue != nil else {
            availability = .unavailable("METAL QUEUE UNAVAILABLE")
            return
        }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "scramkVertex"),
                  let fragment = library.makeFunction(name: "scramkFragment") else {
                availability = .unavailable("METAL SHADER UNAVAILABLE")
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "ScramK state geometry / linear Display P3"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            availability = .ready
        } catch {
            pipeline = nil
            configurationFailure = error.localizedDescription
            availability = .unavailable("METAL PIPELINE UNAVAILABLE")
            // No success report or clear-only fallback after shader/pipeline failure.
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        invalidateGeometry()
    }

    public func draw(in view: MTKView) {
        guard let viewport = view as? ScramKMetalViewportView, !viewport.isDismantled else { return }
        defer { viewport.refreshAccessibilitySummary() }
        let status = interlockStatus
        viewport.synchronizeStateBackground(status: status)
        guard let pipeline else { return }
        guard let device = view.device, let commandQueue = viewport.commandQueue,
              device.registryID == commandQueue.device.registryID else {
            availability = .unavailable("METAL DEVICE / QUEUE MISMATCH")
            return
        }
        guard view.colorPixelFormat == .bgra8Unorm_srgb, view.sampleCount == 1,
              let colorSpaceName = view.colorspace?.name,
              (colorSpaceName as String) == (CGColorSpace.displayP3 as String) else {
            availability = .unavailable("METAL PRESENTATION CONFIGURATION CHANGED")
            return
        }
        guard viewport.window?.isVisible == true, !viewport.isHiddenOrHasHiddenAncestor,
              ScramKViewportDrawability.hasValidExtents(logicalSize: view.bounds.size, drawableSize: view.drawableSize) else {
            availability = .waitingForDrawable
            return
        }
        framebuffer.flushPending()
        if framebuffer.image != nil, !framebuffer.canSubmitRead {
            availability = .waitingForGPU
            return
        }
        guard prepareGeometry(for: viewport, status: status), let vertexBuffer,
              let vertexCount = cachedGeometry?.vertices.count, vertexCount > 0 else { return }
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            availability = .waitingForDrawable
            return
        }
        guard let colorTexture = renderPassDescriptor.colorAttachments[0].texture,
              colorTexture === drawable.texture,
              colorTexture.width > 0, colorTexture.height > 0,
              colorTexture.pixelFormat == .bgra8Unorm_srgb, colorTexture.sampleCount == 1,
              colorTexture.device.registryID == device.registryID else {
            availability = .unavailable("METAL DRAWABLE ATTACHMENT MISMATCH")
            return
        }
        configureRenderPass(renderPassDescriptor, status: status)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            availability = .unavailable("METAL ENCODER UNAVAILABLE")
            return
        }
        commandBuffer.label = "ScramK state geometry submission"
        // Image first, then the cached native HUD primitives. External SwiftUI
        // reference TRGT/rulers remain above this entire drawable.
        let framebufferTicket = framebuffer.encode(in: encoder, logicalSize: view.bounds.size)
        if framebuffer.image != nil, framebufferTicket == nil {
            encoder.endEncoding()
            availability = .unavailable("FRAMEBUFFER ENCODING UNAVAILABLE")
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var logicalSize = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        encoder.setVertexBytes(&logicalSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()
        if let framebufferTicket { framebuffer.attachCompletion(to: commandBuffer, ticket: framebufferTicket) }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderedFrameCount &+= 1
        encodedDrawCallsCount &+= (framebufferTicket == nil ? 1 : 2)
        lastSubmittedVertexCount = vertexCount
        lastSubmittedInterlockStatus = status
        lastSubmittedClearColor = renderPassDescriptor.colorAttachments[0].clearColor
        availability = .submitted
    }

    /// The production draw path explicitly writes the actual attachment, even
    /// when MTKView has already cached a descriptor using an older clear color.
    func configureRenderPass(_ descriptor: MTLRenderPassDescriptor, status: InterlockStatus) {
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = framebuffer.configured
            ? ScramKViewportColor.canvasClearColor : ScramKViewportColor.clearColor(status: status)
    }

    func stop() {
        stopped = true
        framebuffer.stop()
        pipeline = nil
        invalidateGeometry()
        availability = .stopped
    }

    private func invalidateGeometry() {
        cachedGeometry = nil
        cachedSize = nil
        vertexBuffer = nil
    }

    private func prepareGeometry(for view: ScramKMetalViewportView, status: InterlockStatus) -> Bool {
        let size = view.bounds.size
        let health = latestTelemetryFrame?.health
        if cachedGeometry != nil, cachedSize == size, cachedStatus == status, cachedHealth == health {
            return vertexBuffer != nil
        }
        let geometry = ScramKViewportGeometry.make(
            size: size, status: status, telemetryHealth: health, increasedContrast: increasedContrast,
            backgroundSRGB: framebuffer.configured ? ScramKViewportColor.canvasReferenceSRGB : nil
        )
        guard !geometry.vertices.isEmpty, let device = view.device else {
            availability = .unavailable("METAL GEOMETRY UNAVAILABLE")
            return false
        }
        // A replacement immutable buffer is allocated only on geometry changes.
        // Metal retains an old buffer while its submitted command buffer uses it;
        // no CPU writes race an in-flight GPU read.
        let buffer = geometry.vertices.withUnsafeBufferPointer { vertices -> (any MTLBuffer)? in
            guard let baseAddress = vertices.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: vertices.count * MemoryLayout<ScramKViewportVertex>.stride,
                options: .storageModeShared
            )
        }
        guard let buffer else {
            availability = .unavailable("METAL BUFFER UNAVAILABLE")
            return false
        }
        buffer.label = "Immutable ScramK state vertices"
        vertexBuffer = buffer
        cachedGeometry = geometry
        cachedSize = size
        cachedStatus = status
        cachedHealth = health
        return true
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct ScramKVertex { float2 position; float4 color; };
    struct RasterVertex { float4 position [[position]]; float4 color; };
    vertex RasterVertex scramkVertex(
        uint index [[vertex_id]],
        const device ScramKVertex *vertices [[buffer(0)]],
        constant float2 &logicalSize [[buffer(1)]]
    ) {
        ScramKVertex v = vertices[index];
        RasterVertex out;
        out.position = float4(v.position.x / logicalSize.x * 2.0 - 1.0,
                              1.0 - v.position.y / logicalSize.y * 2.0, 0.0, 1.0);
        out.color = v.color;
        return out;
    }
    fragment float4 scramkFragment(RasterVertex in [[stage_in]]) {
        return in.color;
    }
    """
}

/// Native state viewport with an optional, explicitly supplied telemetry stream.
@MainActor
public final class ScramKMetalViewportView: MTKView {
    public let commandQueue: (any MTLCommandQueue)?
    public let viewportRenderer: ScramKViewportRenderer
    public private(set) var isDismantled = false
    private var feedObservationTask: Task<Void, Never>?
    private var feedBindingID = UUID()
    private var isObservingInterlock = false
    private var lastAccessibilitySummary: String?
    private var synchronizedBackgroundStatus: InterlockStatus?
    private var synchronizedFramebufferMode: Bool?
    private let availabilityLabel = NSTextField(labelWithString: "")
    private var hasAvailabilityTypeface = false

    public convenience init(frame frameRect: CGRect = .zero) {
        self.init(frame: frameRect, device: MTLCreateSystemDefaultDevice())
    }

    public override init(frame frameRect: CGRect, device: (any MTLDevice)?) {
        commandQueue = device?.makeCommandQueue()
        viewportRenderer = ScramKViewportRenderer()
        super.init(frame: frameRect, device: device)

        colorPixelFormat = .bgra8Unorm_srgb
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        framebufferOnly = true
        sampleCount = 1
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = true // Resume only when attached to a window.
        delegate = viewportRenderer
        viewportRenderer.configure(for: self)
        synchronizeStateBackground()
        configureAvailabilityLabel()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("ScramK state viewport")
        refreshAccessibilitySummary()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 200) }
    public override var acceptsFirstResponder: Bool { false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeDrawableSize()
        isPaused = window == nil || isDismantled || !viewportRenderer.hasConfiguredPipeline
        if window == nil { unbindTelemetryStream() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeDrawableSize()
    }

    public override func layout() {
        super.layout()
        synchronizeDrawableSize()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("Use init(frame:device:) for the ScramK viewport")
    }

    deinit {
        feedObservationTask?.cancel()
    }

    /// Controller state does not manufacture a TelemetryFrame or authorize actions.
    public func updateInterlockStatus(_ status: InterlockStatus, isObserving: Bool = true) {
        guard !isDismantled else { return }
        isObservingInterlock = isObserving
        viewportRenderer.updateInterlockStatus(status)
        synchronizeStateBackground()
        refreshAccessibilitySummary()
    }

    public func ingestTelemetry(_ frame: TelemetryFrame) {
        guard !isDismantled else { return }
        viewportRenderer.updateTelemetry(frame)
        synchronizeStateBackground()
        refreshAccessibilitySummary()
    }

    /// Cancel/replace the owned task; a stale binding cannot ingest a late frame.
    @discardableResult
    public func bindTelemetryStream(_ stream: AsyncStream<TelemetryFrame>) -> Task<Void, Never> {
        unbindTelemetryStream()
        let bindingID = feedBindingID
        let task = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled, let self,
                      !self.isDismantled, self.feedBindingID == bindingID else { break }
                self.ingestTelemetry(frame)
            }
            if let self, self.feedBindingID == bindingID {
                self.feedObservationTask = nil
            }
        }
        feedObservationTask = task
        if isDismantled { task.cancel() }
        return task
    }

    public func unbindTelemetryStream() {
        feedBindingID = UUID()
        feedObservationTask?.cancel()
        feedObservationTask = nil
        viewportRenderer.clearTelemetry()
        synchronizeStateBackground()
        refreshAccessibilitySummary()
    }

    /// Final teardown for NSViewRepresentable. Does not modify the safety gate.
    public func shutdown() {
        isDismantled = true
        isObservingInterlock = false
        isPaused = true
        unbindTelemetryStream()
        delegate = nil
        viewportRenderer.stop()
        refreshAccessibilitySummary()
    }

    func refreshAccessibilitySummary() {
        let telemetry: String
        if let frame = viewportRenderer.latestTelemetryFrame {
            telemetry = "REPORTED \(frame.subsystem.rawValue) \(frame.health.rawValue), SEQUENCE \(frame.sequenceNumber)"
        } else {
            telemetry = "TELEMETRY UNAVAILABLE"
        }
        let observation = isObservingInterlock ? "STATE OBSERVED" : "STATE OBSERVATION INACTIVE"
        let summary = "\(viewportRenderer.interlockStatus.rawValue). \(observation). \(telemetry). \(viewportRenderer.availability.summary). LOWER-RIGHT GLYPH: INTERLOCK CATEGORY, NOT A TARGET. \(viewportRenderer.framebufferSummary)"
        guard lastAccessibilitySummary != summary else { return }
        lastAccessibilitySummary = summary
        setAccessibilityValue(summary)
        switch viewportRenderer.availability {
        case .unavailable, .waitingForDrawable, .waitingForGPU:
            availabilityLabel.stringValue = viewportRenderer.availability.summary
            availabilityLabel.isHidden = !hasAvailabilityTypeface
        case .ready, .submitted, .stopped:
            availabilityLabel.isHidden = true
        }
    }

    func synchronizeStateBackground(status explicitStatus: InterlockStatus? = nil) {
        let status = explicitStatus ?? viewportRenderer.interlockStatus
        let isRemote = viewportRenderer.framebufferSourceConfigured
        guard synchronizedBackgroundStatus != status || synchronizedFramebufferMode != isRemote else { return }
        clearColor = isRemote ? ScramKViewportColor.canvasClearColor : ScramKViewportColor.clearColor(status: status)
        let encoded = isRemote ? ScramKViewportColor.canvasReferenceSRGB : ScramKViewportColor.clearReferenceSRGB(status: status)
        // Core Animation receives an explicitly tagged encoded sRGB CGColor;
        // Metal receives the corresponding linear Display P3 clear value.
        if let layer {
            layer.backgroundColor = CGColor(
                srgbRed: CGFloat(encoded.x), green: CGFloat(encoded.y), blue: CGFloat(encoded.z), alpha: 1
            )
            synchronizedBackgroundStatus = status
            synchronizedFramebufferMode = isRemote
        }
    }

    private func configureAvailabilityLabel() {
        // Font registration belongs to the composition root. Never display a
        // system-font substitution if its licensed local face is unavailable.
        if let font = NSFont(name: "JetBrainsMono-Regular", size: 10) {
            availabilityLabel.font = font
            hasAvailabilityTypeface = true
        }
        availabilityLabel.textColor = NSColor(srgbRed: 239.0 / 255, green: 68.0 / 255, blue: 68.0 / 255, alpha: 1)
        availabilityLabel.isHidden = true
        availabilityLabel.setAccessibilityElement(false) // Parent image carries the same condition.
        availabilityLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(availabilityLabel)
        NSLayoutConstraint.activate([
            availabilityLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            availabilityLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            availabilityLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    private func synchronizeDrawableSize() {
        let size = convertToBacking(bounds).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if drawableSize != size { drawableSize = size }
    }
}
