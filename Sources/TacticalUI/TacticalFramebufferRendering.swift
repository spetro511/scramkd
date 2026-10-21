import CoreGraphics
import Foundation
import Metal
import TacticalVirtualization

// D2 preparation: DO RAG returned no context. Corroborated with Augment and
// baseline 26eba55 in this worktree. Frame Systems sibling FrameContracts.swift
// and FramebufferClient.swift were read during Red Team reconciliation:
// FrameObservation.current, throwing RGBAFrame initializer, one frame observer,
// nonthrowing unsubscribe(id:). No local DTO or protocol stub.
// Trust boundary: immutable decoded bytes -> bounded CPU upload -> GPU sample.
// No protocol decoding, endpoint selection, input forwarding, or connect here.

public struct TacticalViewportMetricSnapshot: Equatable, Sendable {
    public let submittedFrames: UInt64
    public let encodedDrawCallsCount: UInt64
    public let uploadedFrameSequence: UInt64?
    public let uploadedGeneration: UUID?
    /// Only a pending CPU frame replaced while BOTH local slots were busy.
    /// Does not count client/latest-1 stream coalescing or claim zero drops.
    public let busyDropCounts: UInt64
    public let rejectedFrameCount: UInt64
    /// Failures observed in the current rendering epoch; retired callbacks only
    /// reclaim physical ownership and cannot report against a new session.
    public let gpuFailureCount: UInt64
    /// MTLResource.allocatedSize of the two renderer-owned texture slots.
    public let residentTextureBytes: Int
    public let pendingCPUFrameBytes: Int
    public let inFlightReadCounts: [Int]
    public let framebufferConfigured: Bool
    public let isImageAvailable: Bool
}

struct TacticalFramebufferLayout: Equatable, Sendable {
    // Verified source is 1920x1080. This conservative renderer cap is independent
    // of (and must not weaken) the Frame Systems decoder's own allocation cap.
    static let maximumWidth = 1920
    static let maximumHeight = 1080
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let byteCount: Int

    static func validate(width: Int, height: Int, bytesPerRow: Int, byteCount: Int) -> Self? {
        guard width > 0, height > 0, width <= maximumWidth, height <= maximumHeight else { return nil }
        let row = width.multipliedReportingOverflow(by: 4)
        guard !row.overflow, row.partialValue == bytesPerRow else { return nil }
        let total = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !total.overflow, total.partialValue == byteCount else { return nil }
        return Self(width: width, height: height, bytesPerRow: bytesPerRow, byteCount: byteCount)
    }

    static func aspectFit(imageWidth: Int, imageHeight: Int, bounds: CGSize) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              Float(bounds.width).isFinite, Float(bounds.height).isFinite else { return nil }
        let scale = min(bounds.width / CGFloat(imageWidth), bounds.height / CGFloat(imageHeight))
        let width = CGFloat(imageWidth) * scale
        let height = CGFloat(imageHeight) * scale
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite else { return nil }
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// Metadata cursor only: it never retains frame pixels or an observation stream.
struct TacticalFramebufferDeliveryCursor: Sendable {
    private(set) var revision: UInt64?
    private(set) var generation: UUID?
    private(set) var sequence: UInt64?

    mutating func accept(revision nextRevision: UInt64, generation nextGeneration: UUID?, frame: RGBAFrame?) -> Bool {
        guard revision.map({ nextRevision > $0 }) ?? true else { return false }
        if let frame {
            guard nextGeneration == frame.generation else { return false }
            if nextGeneration == generation, let sequence, frame.sequence <= sequence { return false }
        }
        if nextGeneration != generation { sequence = nil }
        revision = nextRevision
        generation = nextGeneration
        if let frame { sequence = frame.sequence }
        return true
    }
}

struct TacticalFramebufferImage: Equatable, Sendable {
    let generation: UUID
    let sequence: UInt64
    let layout: TacticalFramebufferLayout
}

struct TacticalFramebufferPendingFrame: Sendable {
    private(set) var frame: RGBAFrame?
    private(set) var busyDropCounts: UInt64 = 0

    mutating func replace(with frame: RGBAFrame, bothSlotsBusy: Bool) {
        if self.frame != nil, bothSlotsBusy { busyDropCounts &+= 1 }
        self.frame = frame
    }

    mutating func clear() { frame = nil }
}

struct TacticalFramebufferReadTicket: Hashable, Sendable {
    let epoch: UUID
    let slot: Int
    let resource: UUID
    let read: UUID
}

/// CPU proof model, shared by production and deterministic tests. A clear retires
/// content, NOT physical read ownership. Otherwise a late GPU read could collide
/// with a new-generation CPU upload into the same cached texture.
struct TacticalFramebufferSlots: Sendable {
    struct Slot: Sendable {
        var resource = UUID()
        var layout: TacticalFramebufferLayout?
        var image: TacticalFramebufferImage?
        var reads: [UUID: UUID] = [:] // read ID -> submitting epoch
    }
    enum Completion: Equatable { case rejected, retired, current }
    private(set) var epoch = UUID()
    private(set) var slots = [Slot(), Slot()]
    private(set) var displayedSlot: Int?
    static let maximumConcurrentReads = 3

    var inFlightReadCounts: [Int] { slots.map { $0.reads.count } }
    var image: TacticalFramebufferImage? { displayedSlot.flatMap { slots[$0].image } }
    var canSubmitRead: Bool { slots.reduce(0) { $0 + $1.reads.count } < Self.maximumConcurrentReads }
    var writableSlot: Int? {
        slots.indices.first { $0 != displayedSlot && slots[$0].reads.isEmpty }
            ?? slots.indices.first { slots[$0].reads.isEmpty }
    }

    mutating func retire() {
        epoch = UUID()
        displayedSlot = nil
        for index in slots.indices { slots[index].image = nil }
    }

    @discardableResult
    mutating func replaceResource(at index: Int, layout: TacticalFramebufferLayout?) -> Bool {
        guard slots.indices.contains(index), slots[index].reads.isEmpty else { return false }
        slots[index].resource = UUID()
        slots[index].layout = layout
        slots[index].image = nil
        if displayedSlot == index { displayedSlot = nil }
        return true
    }

    @discardableResult
    mutating func uploaded(_ image: TacticalFramebufferImage, at index: Int) -> Bool {
        guard slots.indices.contains(index), slots[index].reads.isEmpty,
              slots[index].layout == image.layout else { return false }
        slots[index].image = image
        displayedSlot = index
        return true
    }

    mutating func reserveRead() -> TacticalFramebufferReadTicket? {
        guard canSubmitRead, let index = displayedSlot, slots[index].image != nil else { return nil }
        let ticket = TacticalFramebufferReadTicket(epoch: epoch, slot: index, resource: slots[index].resource, read: UUID())
        slots[index].reads[ticket.read] = ticket.epoch
        return ticket
    }

    mutating func complete(_ ticket: TacticalFramebufferReadTicket) -> Completion {
        guard slots.indices.contains(ticket.slot), slots[ticket.slot].resource == ticket.resource,
              slots[ticket.slot].reads[ticket.read] == ticket.epoch else { return .rejected }
        slots[ticket.slot].reads.removeValue(forKey: ticket.read)
        return ticket.epoch == epoch ? .current : .retired
    }
}

struct TacticalFramebufferQuadVertex: Sendable {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>

    // Data row zero is the top row. No Core Graphics / OpenGL vertical flip.
    static let vertices: [Self] = [
        Self(position: SIMD2(-1, 1), uv: SIMD2(0, 0)),
        Self(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
        Self(position: SIMD2(1, 1), uv: SIMD2(1, 0)),
        Self(position: SIMD2(1, 1), uv: SIMD2(1, 0)),
        Self(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
        Self(position: SIMD2(1, -1), uv: SIMD2(1, 1))
    ]
}

/// Two renderer-owned GPU texture references plus at most one pending CPU frame.
/// Never writes a slot with outstanding reads, even after generation retirement.
@MainActor
final class TacticalFramebufferSurface {
    private(set) var configured = false
    private(set) var generation: UUID?
    private(set) var failure: String?
    private(set) var rejectedFrameCount: UInt64 = 0
    private(set) var gpuFailureCount: UInt64 = 0
    private(set) var ownership = TacticalFramebufferSlots()
    private var textures: [(any MTLTexture)?] = [nil, nil]
    private var pending = TacticalFramebufferPendingFrame()
    private var lastAcceptedSequence: UInt64?
    private var device: (any MTLDevice)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var sampler: (any MTLSamplerState)?
    private var quadBuffer: (any MTLBuffer)?
    private var configurationAttempted = false
    private var configurationFailure: String?
    private var stopped = false
    private var initialExplicitInputAllowed = true

    var image: TacticalFramebufferImage? { ownership.image }
    var busyDropCounts: UInt64 { pending.busyDropCounts }
    var pendingCPUFrameBytes: Int { pending.frame?.pixels.count ?? 0 }
    var residentTextureBytes: Int {
        textures.reduce(0) { total, texture in
            total + (texture.map { Int(clamping: $0.allocatedSize) } ?? 0)
        }
    }
    var canSubmitRead: Bool { ownership.canSubmitRead }

    static func cpuVisibleStorageMode(for device: any MTLDevice) -> MTLStorageMode {
        // Mac-family Intel GPUs can share system RAM without supporting shared
        // textures. Select shared textures by Apple-family support, not merely
        // hasUnifiedMemory; managed replace(...) is the Mac-family CPU path.
        device.supportsFamily(.apple1) ? .shared : .managed
    }

    func setDevice(_ device: any MTLDevice) {
        self.device = device // No extra queue; pipelines are lazy for default-nil compatibility.
    }

    func setConfigured(_ enabled: Bool) {
        guard !stopped, configured != enabled else { return }
        clear()
        configured = enabled
    }

    /// Delivery cursor or an explicit caller must establish a new generation
    /// after clear; a late updateFramebuffer alone cannot resurrect old content.
    func beginGeneration(_ value: UUID) {
        guard !stopped else { return }
        if !configured { setConfigured(true) }
        guard generation != value else { return }
        clear()
        generation = value
    }

    func enqueue(_ frame: RGBAFrame) {
        guard !stopped else { return }
        if !configured {
            guard initialExplicitInputAllowed else {
                rejectedFrameCount &+= 1
                return
            }
            beginGeneration(frame.generation) // Explicit API input, never automatic connect.
        }
        guard generation == frame.generation,
              lastAcceptedSequence.map({ frame.sequence > $0 }) ?? true else {
            rejectedFrameCount &+= 1
            return
        }
        guard case .assumedSRGB = frame.colorEncoding,
              TacticalFramebufferLayout.validate(
                width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, byteCount: frame.pixels.count
              ) != nil else {
            rejectedFrameCount &+= 1
            clear()
            failure = "FRAMEBUFFER INPUT REJECTED"
            return
        }
        lastAcceptedSequence = frame.sequence
        pending.replace(with: frame, bothSlotsBusy: ownership.writableSlot == nil)
        flushPending()
    }

    func clear() {
        initialExplicitInputAllowed = false
        ownership.retire()
        generation = nil
        lastAcceptedSequence = nil
        pending.clear()
        failure = nil
        releaseIdleTextures()
    }

    func stop() {
        clear()
        configured = false
        stopped = true
        pipeline = nil
        sampler = nil
        quadBuffer = nil
        device = nil
        // Busy slots remain bounded and retained until their real completions.
        // Command buffers also retain bound resources if this owner disappears.
    }

    func flushPending() {
        guard !stopped, let frame = pending.frame, frame.generation == generation,
              let index = ownership.writableSlot, prepareResources(), let device,
              let layout = TacticalFramebufferLayout.validate(
                width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, byteCount: frame.pixels.count
              ) else { return }
        let oldLayout = ownership.slots[index].layout
        if textures[index] == nil || oldLayout != layout {
            // Drop the idle old allocation before creating its replacement;
            // there is no third renderer-owned resize/generation texture.
            guard ownership.replaceResource(at: index, layout: nil) else { return }
            textures[index] = nil
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb, width: layout.width, height: layout.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = Self.cpuVisibleStorageMode(for: device)
            guard let texture = device.makeTexture(descriptor: descriptor),
                  ownership.replaceResource(at: index, layout: layout) else {
                failAndRetire("FRAMEBUFFER TEXTURE UNAVAILABLE")
                return
            }
            texture.label = "Framebuffer RGBA slot \(index) / assumed sRGB"
            textures[index] = texture
        }
        guard let texture = textures[index], ownership.slots[index].reads.isEmpty else { return }
        // Synchronous copy boundary; the pointer cannot escape the Data borrow.
        // RGBAFrame's throwing initializer owns the opaque-alpha invariant.
        var copied = false
        frame.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, layout.width, layout.height), mipmapLevel: 0,
                withBytes: baseAddress, bytesPerRow: layout.bytesPerRow
            )
            copied = true
        }
        guard copied, ownership.uploaded(
            TacticalFramebufferImage(generation: frame.generation, sequence: frame.sequence, layout: layout), at: index
        ) else {
            failAndRetire("FRAMEBUFFER UPLOAD REJECTED")
            return
        }
        pending.clear() // No uploaded slot retains CPU pixel Data.
        failure = nil
    }

    /// Caller must attach completion before commit. Nil means no image draw was
    /// encoded; no ticket/read count was reserved on the failing path.
    func encode(in encoder: any MTLRenderCommandEncoder, logicalSize: CGSize) -> TacticalFramebufferReadTicket? {
        guard let image, let index = ownership.displayedSlot, let texture = textures[index],
              let pipeline, let sampler, let quadBuffer,
              let fit = TacticalFramebufferLayout.aspectFit(
                imageWidth: image.layout.width, imageHeight: image.layout.height, bounds: logicalSize
              ), let ticket = ownership.reserveRead() else { return nil }
        var scale = SIMD2<Float>(Float(fit.width / logicalSize.width), Float(fit.height / logicalSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        return ticket
    }

    func attachCompletion(to commandBuffer: any MTLCommandBuffer, ticket: TacticalFramebufferReadTicket) {
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let succeeded = buffer.status == .completed
            // Only checked Sendable scalar metadata crosses into the main actor.
            // Neither the command buffer nor a texture is transferred to the Task.
            Task { @MainActor [weak self, ticket, succeeded] in
                self?.complete(ticket, succeeded: succeeded)
            }
        }
    }

    func complete(_ ticket: TacticalFramebufferReadTicket, succeeded: Bool) {
        let result = ownership.complete(ticket)
        guard result != .rejected else { return }
        if result == .current, !succeeded, !stopped {
            gpuFailureCount &+= 1
            clear()
            failure = "FRAMEBUFFER GPU SUBMISSION FAILED"
        }
        // Old-epoch callbacks only reclaim their exact resource/read ticket.
        // They cannot publish an image, upload pending bytes, change generation,
        // or report a failure against a replacement session.
        if result == .retired || stopped { releaseIdleTextures() }
    }

    private func releaseIdleTextures() {
        for index in textures.indices where ownership.slots[index].reads.isEmpty && ownership.slots[index].image == nil {
            textures[index] = nil
            ownership.replaceResource(at: index, layout: nil)
        }
    }

    private func prepareResources() -> Bool {
        if pipeline != nil, sampler != nil, quadBuffer != nil { return true }
        guard !configurationAttempted else {
            failure = configurationFailure
            return false
        }
        guard let device else {
            failure = "FRAMEBUFFER METAL DEVICE UNAVAILABLE"
            return false
        }
        configurationAttempted = true
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "framebufferVertex"),
                  let fragment = library.makeFunction(name: "framebufferFragment") else {
                failConfiguration("FRAMEBUFFER SHADER UNAVAILABLE")
                return false
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Framebuffer assumed sRGB -> linear Display P3"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            let candidate = try device.makeRenderPipelineState(descriptor: descriptor)
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            guard let candidateSampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
                failConfiguration("FRAMEBUFFER SAMPLER UNAVAILABLE")
                return false
            }
            let buffer = TacticalFramebufferQuadVertex.vertices.withUnsafeBufferPointer { vertices -> (any MTLBuffer)? in
                guard let baseAddress = vertices.baseAddress else { return nil }
                return device.makeBuffer(
                    bytes: baseAddress, length: vertices.count * MemoryLayout<TacticalFramebufferQuadVertex>.stride,
                    options: .storageModeShared
                )
            }
            guard let buffer else {
                failConfiguration("FRAMEBUFFER QUAD UNAVAILABLE")
                return false
            }
            pipeline = candidate
            sampler = candidateSampler
            quadBuffer = buffer
            failure = nil
            return true
        } catch {
            failConfiguration("FRAMEBUFFER PIPELINE UNAVAILABLE: \(error.localizedDescription)")
            return false
        }
    }

    private func failAndRetire(_ reason: String) {
        clear()
        failure = reason
    }

    private func failConfiguration(_ reason: String) {
        configurationFailure = reason
        failAndRetire(reason)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadVertex { float2 position; float2 uv; };
    struct RasterQuad { float4 position [[position]]; float2 uv; };
    vertex RasterQuad framebufferVertex(
        uint index [[vertex_id]], const device QuadVertex *vertices [[buffer(0)]],
        constant float2 &scale [[buffer(1)]]
    ) {
        RasterQuad out;
        out.position = float4(vertices[index].position * scale, 0.0, 1.0);
        out.uv = vertices[index].uv;
        return out;
    }
    fragment float4 framebufferFragment(
        RasterQuad in [[stage_in]], texture2d<float> image [[texture(0)]], sampler imageSampler [[sampler(0)]]
    ) {
        // rgba8Unorm_srgb sampling already decoded encoded sRGB exactly once.
        float3 rgb = image.sample(imageSampler, in.uv).rgb;
        float3 p3 = float3(0.8224619687 * rgb.r + 0.1775380313 * rgb.g,
                          0.0331941989 * rgb.r + 0.9668058011 * rgb.g,
                          0.0170826307 * rgb.r + 0.0723974407 * rgb.g + 0.9105199286 * rgb.b);
        return float4(p3, 1.0); // bgra8Unorm_srgb target encodes once; Display P3 tag is on MTKView.
    }
    """
}
