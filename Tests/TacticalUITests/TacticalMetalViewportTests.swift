import AppKit
import CoreGraphics
import Metal
import os
import XCTest
import TacticalCore
import TacticalVirtualization
@testable import TacticalUI

final class TacticalMetalViewportTests: XCTestCase {
    func testSRGBToLinearDisplayP3NumericReferences() {
        // D65 matrix references, after the IEC 61966-2-1 inverse transfer curve.
        let samples: [(UInt32, SIMD3<Float>)] = [
            (0x000000, SIMD3(0, 0, 0)),
            (0xFFFFFF, SIMD3(1, 1, 1)),
            (0xFF0000, SIMD3(0.8224619687, 0.0331941989, 0.0170826307)),
            (0x030509, SIMD3(0.0010183561, 0.0014974842, 0.0026127343)),
            (0x10B981, SIMD3(0.0903941657, 0.4692177728, 0.2350951076)),
            (0xF59E0B, SIMD3(0.8116917287, 0.3608744277, 0.0433989439)),
            (0xEF4444, SIMD3(0.7201766434, 0.0845384374, 0.0715629573))
        ]
        for (hex, expected) in samples {
            let actual = TacticalViewportColor.linearDisplayP3(hex: hex)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, "R: \(hex)")
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, "G: \(hex)")
            XCTAssertEqual(actual.z, expected.z, accuracy: 0.000001, "B: \(hex)")
        }
    }

    func testTransparentReferenceColorMatchesDefaultCanvasComposite() {
        let clear = TacticalViewportColor.linearDisplayP3(hex: TacticalViewportColor.backgroundHex)
        XCTAssertEqual(TacticalViewportColor.linearDisplayP3(hex: 0xF59E0B, opacity: 0), clear)
        XCTAssertEqual(TacticalViewportColor.linearDisplayP3(hex: 0xEF4444, opacity: -1), clear)
        XCTAssertEqual(
            TacticalViewportColor.linearDisplayP3(hex: 0x10B981, opacity: 2),
            TacticalViewportColor.linearDisplayP3(hex: 0x10B981)
        )
    }

    func testAllFourClearColorsUseExactEncodedSRGBReferences() {
        for sample in clearSamples {
            XCTAssertEqual(TacticalViewportColor.clearReferenceSRGB(status: sample.status), sample.encoded)
            assertClearColor(TacticalViewportColor.clearColor(status: sample.status), expected: sample.linear)
        }
    }

    func testTransparentGeometryMatchesEachDynamicClearColor() {
        for sample in clearSamples {
            let transparent = TacticalViewportColor.linearDisplayP3(
                hex: 0xF59E0B, opacity: 0, backgroundSRGB: sample.encoded
            )
            XCTAssertEqual(Double(transparent.x), sample.linear.x, accuracy: 0.000000001)
            XCTAssertEqual(Double(transparent.y), sample.linear.y, accuracy: 0.000000001)
            XCTAssertEqual(Double(transparent.z), sample.linear.z, accuracy: 0.000000001)
            XCTAssertEqual(
                TacticalViewportColor.linearDisplayP3(hex: 0x10B981, backgroundSRGB: sample.encoded),
                TacticalViewportColor.linearDisplayP3(hex: 0x10B981)
            )
        }
    }

    func testDrawabilityRejectsInvalidLogicalAndDrawableExtents() {
        let valid = CGSize(width: 320, height: 200)
        XCTAssertTrue(TacticalViewportDrawability.hasValidExtents(logicalSize: valid, drawableSize: valid))
        let invalid: [CGSize] = [
            .zero, CGSize(width: -1, height: 200), CGSize(width: 320, height: 0),
            CGSize(width: CGFloat.infinity, height: 200), CGSize(width: CGFloat.nan, height: 200),
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: 200)
        ]
        for size in invalid {
            XCTAssertFalse(TacticalViewportDrawability.hasValidExtents(logicalSize: size, drawableSize: valid))
            XCTAssertFalse(TacticalViewportDrawability.hasValidExtents(logicalSize: valid, drawableSize: size))
        }
        XCTAssertFalse(TacticalViewportDrawability.hasValidExtents(
            logicalSize: valid, drawableSize: CGSize(width: 0.5, height: 200)
        ))
    }

    func testNeutralColorPreservesNeutralAxisAndDecodesOnlyOnce() {
        let gray = TacticalViewportColor.linearDisplayP3(hex: 0x808080)
        XCTAssertEqual(gray.x, 0.2158605001, accuracy: 0.000001)
        XCTAssertEqual(gray.x, gray.y, accuracy: 0.000001)
        XCTAssertEqual(gray.y, gray.z, accuracy: 0.000001)
        XCTAssertNotEqual(gray.x, Float(128) / 255) // Not encoded sRGB passed to Metal as linear.
    }

    func testAllInterlockStatesChangeGeometryNotOnlyColor() {
        let states: [InterlockStatus] = [.locked, .armed, .permissiveGranted, .emergencyAbort]
        let geometries = states.map {
            TacticalViewportGeometry.make(size: CGSize(width: 794, height: 500), status: $0, telemetryHealth: nil)
        }
        for left in geometries.indices {
            XCTAssertFalse(geometries[left].vertices.isEmpty)
            XCTAssertEqual(geometries[left].vertices.count % 3, 0)
            for right in geometries.indices where left < right {
                XCTAssertNotEqual(
                    geometries[left].vertices.map(\.position),
                    geometries[right].vertices.map(\.position)
                )
            }
        }
    }

    func testCategoricalStateBandIsLowerRightAndNotATargetCrosshair() {
        let size = CGSize(width: 794, height: 500)
        for sample in clearSamples {
            let geometry = TacticalViewportGeometry.make(size: size, status: sample.status, telemetryHealth: nil)
            // The final two rectangles select one of four categorical cells;
            // there are no target axes or target labels in this Metal layer.
            let selection = geometry.vertices.suffix(12)
            XCTAssertEqual(selection.count, 12)
            XCTAssertTrue(selection.allSatisfy { $0.position.x >= Float(size.width) - 84 })
            XCTAssertTrue(selection.allSatisfy { $0.position.y >= Float(size.height) - 56 })
            XCTAssertTrue(selection.allSatisfy { $0.position.y <= Float(size.height) - 38 })
        }
    }

    func testGeometryIsDeterministicAndFiniteAtReferenceSize() {
        let size = CGSize(width: 794, height: 500)
        let first = TacticalViewportGeometry.make(size: size, status: .armed, telemetryHealth: nil)
        let second = TacticalViewportGeometry.make(size: size, status: .armed, telemetryHealth: nil)
        XCTAssertEqual(first, second)
        for vertex in first.vertices {
            XCTAssertTrue(vertex.position.x.isFinite && vertex.position.y.isFinite)
            XCTAssertGreaterThanOrEqual(vertex.position.x, 0)
            XCTAssertGreaterThanOrEqual(vertex.position.y, 0)
            XCTAssertLessThanOrEqual(vertex.position.x, Float(size.width))
            XCTAssertLessThanOrEqual(vertex.position.y, Float(size.height))
            XCTAssertEqual(vertex.color.w, 1)
        }
        XCTAssertTrue(TacticalViewportGeometry.make(size: .zero, status: .locked, telemetryHealth: nil).vertices.isEmpty)
        XCTAssertTrue(TacticalViewportGeometry.make(
            size: CGSize(width: CGFloat.infinity, height: 200), status: .locked, telemetryHealth: nil
        ).vertices.isEmpty)
    }

    func testTelemetryHealthIsOptionalAndChangesReportedGlyph() {
        let size = CGSize(width: 794, height: 500)
        let missing = TacticalViewportGeometry.make(size: size, status: .locked, telemetryHealth: nil)
        let nominal = TacticalViewportGeometry.make(size: size, status: .locked, telemetryHealth: .nominal)
        let critical = TacticalViewportGeometry.make(size: size, status: .locked, telemetryHealth: .critical)
        let offline = TacticalViewportGeometry.make(size: size, status: .locked, telemetryHealth: .offline)
        XCTAssertGreaterThan(nominal.vertices.count, missing.vertices.count)
        XCTAssertGreaterThan(critical.vertices.count, nominal.vertices.count)
        XCTAssertGreaterThan(offline.vertices.count, missing.vertices.count)
        XCTAssertLessThan(offline.vertices.count, nominal.vertices.count)
    }

    func testIncreasedContrastChangesLatticeWithoutMovingGeometry() {
        let size = CGSize(width: 794, height: 500)
        let normal = TacticalViewportGeometry.make(size: size, status: .armed, telemetryHealth: nil)
        let increased = TacticalViewportGeometry.make(
            size: size, status: .armed, telemetryHealth: nil, increasedContrast: true
        )
        XCTAssertEqual(normal.vertices.map(\.position), increased.vertices.map(\.position))
        XCTAssertNotEqual(normal.vertices.map(\.color), increased.vertices.map(\.color))
    }

    func testVertexLayoutMatchesEmbeddedMetalStruct() {
        XCTAssertEqual(MemoryLayout<TacticalViewportVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<TacticalViewportVertex>.offset(of: \.position), 0)
        XCTAssertEqual(MemoryLayout<TacticalViewportVertex>.offset(of: \.color), 16)
    }

    @MainActor
    func testExplicitControllerStateOverridesTelemetryWithoutFabricatingAFrame() {
        let renderer = TacticalViewportRenderer()
        XCTAssertEqual(renderer.interlockStatus, .locked)
        XCTAssertNil(renderer.latestTelemetryFrame)
        renderer.updateInterlockStatus(.armed)
        XCTAssertEqual(renderer.interlockStatus, .armed)
        XCTAssertNil(renderer.latestTelemetryFrame)
        let telemetry = frame(sequence: 1, status: .locked)
        renderer.updateTelemetry(telemetry)
        XCTAssertEqual(renderer.latestTelemetryFrame, telemetry)
        XCTAssertEqual(renderer.interlockStatus, .armed)
        renderer.updateInterlockStatus(.emergencyAbort)
        XCTAssertEqual(renderer.interlockStatus, .emergencyAbort)
    }

    @MainActor
    func testLegacyTelemetryStateStillDrivesRendererWithoutControllerOverride() {
        let renderer = TacticalViewportRenderer()
        renderer.updateTelemetry(frame(sequence: 1, status: .permissiveGranted))
        XCTAssertEqual(renderer.interlockStatus, .permissiveGranted)
        renderer.clearTelemetry()
        XCTAssertEqual(renderer.interlockStatus, .locked)
        XCTAssertNil(renderer.latestTelemetryFrame)
    }

    @MainActor
    func testProductionRenderPassSelectionSetsAllFourAttachmentClears() {
        let renderer = TacticalViewportRenderer()
        let descriptor = MTLRenderPassDescriptor()
        for sample in clearSamples {
            // Simulate a cached descriptor with an obsolete color/load action.
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.75, green: 0.5, blue: 0.25, alpha: 0)
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .dontCare
            renderer.configureRenderPass(descriptor, status: sample.status)
            assertClearColor(descriptor.colorAttachments[0].clearColor, expected: sample.linear)
            XCTAssertEqual(descriptor.colorAttachments[0].loadAction, .clear)
            XCTAssertEqual(descriptor.colorAttachments[0].storeAction, .store)
        }
    }

    @MainActor
    func testViewStateClearUpdatesWithoutADeviceOrFabricatedTelemetry() {
        let view = TacticalMetalViewportView(frame: .zero, device: nil)
        defer { view.shutdown() }
        for sample in clearSamples {
            view.updateInterlockStatus(sample.status)
            assertClearColor(view.clearColor, expected: sample.linear)
            XCTAssertNil(view.viewportRenderer.latestTelemetryFrame)
            XCTAssertEqual(view.viewportRenderer.renderedFrameCount, 0)
            XCTAssertNil(view.viewportRenderer.lastSubmittedClearColor)
        }
    }

    @MainActor
    func testMissingDeviceHasAccessibleUnavailableConditionAndNoSubmissions() {
        let view = TacticalMetalViewportView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: nil)
        defer { view.shutdown() }
        XCTAssertNil(view.device)
        XCTAssertNil(view.commandQueue)
        XCTAssertEqual(view.viewportRenderer.availability, .unavailable("METAL DEVICE UNAVAILABLE"))
        XCTAssertTrue((view.accessibilityValue() as? String)?.contains("METAL DEVICE UNAVAILABLE") == true)
        view.viewportRenderer.draw(in: view)
        XCTAssertEqual(view.viewportRenderer.renderedFrameCount, 0)
        XCTAssertEqual(view.viewportRenderer.lastSubmittedVertexCount, 0)
    }

    @MainActor
    func testFeedReplacementAndShutdownRejectOldFrames() async {
        let view = TacticalMetalViewportView(frame: .zero, device: nil)
        let old = AsyncStream<TelemetryFrame>.makeStream()
        let replacement = AsyncStream<TelemetryFrame>.makeStream()
        let oldTask = view.bindTelemetryStream(old.stream)
        let replacementTask = view.bindTelemetryStream(replacement.stream)
        old.continuation.yield(frame(sequence: 1, status: .armed))
        old.continuation.finish()
        replacement.continuation.yield(frame(sequence: 2, status: .locked))
        replacement.continuation.finish()
        await oldTask.value
        await replacementTask.value
        XCTAssertEqual(view.viewportRenderer.latestTelemetryFrame?.sequenceNumber, 2)
        let pending = AsyncStream<TelemetryFrame>.makeStream()
        let pendingTask = view.bindTelemetryStream(pending.stream)
        view.shutdown()
        pending.continuation.yield(frame(sequence: 3, status: .permissiveGranted))
        pending.continuation.finish()
        await pendingTask.value
        XCTAssertTrue(view.isPaused)
        XCTAssertNil(view.delegate)
        XCTAssertNil(view.viewportRenderer.latestTelemetryFrame)
        XCTAssertEqual(view.viewportRenderer.availability, .stopped)
        view.ingestTelemetry(frame(sequence: 4, status: .permissiveGranted))
        XCTAssertNil(view.viewportRenderer.latestTelemetryFrame)
        view.viewportRenderer.draw(in: view)
        XCTAssertEqual(view.viewportRenderer.renderedFrameCount, 0)
    }

    @MainActor
    func testMetalDeviceConfigurationWhenAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable; GPU configuration not checked")
        }
        let view = TacticalMetalViewportView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: device)
        defer { view.shutdown() }
        XCTAssertNotNil(view.commandQueue)
        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm_srgb)
        let colorSpaceName = (view.colorspace?.name).map { $0 as String }
        XCTAssertEqual(colorSpaceName, CGColorSpace.displayP3 as String)
        XCTAssertEqual(view.sampleCount, 1)
        XCTAssertEqual(view.preferredFramesPerSecond, 60) // Requested rate, not a timing measurement.
        XCTAssertTrue(view.autoResizeDrawable)
        XCTAssertEqual(view.viewportRenderer.availability, .ready, view.viewportRenderer.configurationFailure ?? "")
        XCTAssertEqual(view.viewportRenderer.renderedFrameCount, 0)
        XCTAssertNil(view.viewportRenderer.latestTelemetryFrame)
    }

    @MainActor
    func testWindowlessViewDoesNotClaimASubmission() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable; windowless drawability not checked")
        }
        let view = TacticalMetalViewportView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: device)
        defer { view.shutdown() }
        XCTAssertEqual(view.viewportRenderer.availability, .ready, view.viewportRenderer.configurationFailure ?? "")
        guard view.viewportRenderer.availability == .ready else { return }
        view.viewportRenderer.draw(in: view)
        XCTAssertEqual(view.viewportRenderer.availability, .waitingForDrawable)
        XCTAssertEqual(view.viewportRenderer.renderedFrameCount, 0)
        XCTAssertNil(view.viewportRenderer.lastSubmittedInterlockStatus)
        XCTAssertNil(view.viewportRenderer.lastSubmittedClearColor)
    }

    @MainActor
    func testDrawableSubmissionWhenGPUAndDrawableAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable; drawable submission not checked")
        }
        let view = TacticalMetalViewportView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), device: device)
        guard NSScreen.main != nil else {
            view.shutdown()
            throw XCTSkip("Display session unavailable; window/drawable submission not checked")
        }
        XCTAssertEqual(view.viewportRenderer.availability, .ready, view.viewportRenderer.configurationFailure ?? "")
        guard view.viewportRenderer.availability == .ready else {
            view.shutdown()
            return
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.isPaused = true // Exercise only synchronous manual draw callbacks.
        defer {
            view.shutdown()
            window.orderOut(nil)
            window.close()
        }
        window.orderFront(nil) // No key-window activation or input capture.
        view.layoutSubtreeIfNeeded()
        guard window.isVisible else {
            throw XCTSkip("Visible window unavailable; drawable submission not checked")
        }
        for sample in clearSamples {
            let previousCount = view.viewportRenderer.renderedFrameCount
            view.updateInterlockStatus(sample.status)
            view.draw() // MTKView refreshes/releases its cached descriptor/drawable.
            if view.viewportRenderer.availability == .waitingForDrawable {
                throw XCTSkip("Drawable unavailable in this display session; submission not checked")
            }
            XCTAssertEqual(view.viewportRenderer.renderedFrameCount, previousCount + 1)
            XCTAssertGreaterThan(view.viewportRenderer.lastSubmittedVertexCount, 0)
            XCTAssertEqual(view.viewportRenderer.availability, .submitted)
            XCTAssertEqual(view.viewportRenderer.lastSubmittedInterlockStatus, sample.status)
            let submittedClear = try XCTUnwrap(view.viewportRenderer.lastSubmittedClearColor)
            assertClearColor(submittedClear, expected: sample.linear)
        }
    }

    // D2 additions. All 21 baseline method identifiers and bodies above remain
    // unchanged. These definitions are preparation only, not executed evidence.
    func testFramebufferLayoutRejectsOverflowStrideAndOversize() {
        XCTAssertNotNil(TacticalFramebufferLayout.validate(width: 1920, height: 1080, bytesPerRow: 7680, byteCount: 8_294_400))
        XCTAssertNil(TacticalFramebufferLayout.validate(width: 0, height: 2, bytesPerRow: 0, byteCount: 0))
        XCTAssertNil(TacticalFramebufferLayout.validate(width: 2, height: -1, bytesPerRow: 8, byteCount: 0))
        XCTAssertNil(TacticalFramebufferLayout.validate(width: Int.max, height: 2, bytesPerRow: 8, byteCount: 16))
        XCTAssertNil(TacticalFramebufferLayout.validate(width: 1921, height: 1080, bytesPerRow: 7684, byteCount: 8_298_720))
        XCTAssertNil(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 12, byteCount: 24))
        XCTAssertNil(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 8, byteCount: 15))
    }

    func testFramebufferBothSlotsRemainOwnedUntilExactCompletion() throws {
        var slots = TacticalFramebufferSlots()
        let layout = try XCTUnwrap(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 8, byteCount: 16))
        let generation = UUID()
        XCTAssertTrue(slots.replaceResource(at: 0, layout: layout))
        XCTAssertTrue(slots.uploaded(TacticalFramebufferImage(generation: generation, sequence: 1, layout: layout), at: 0))
        let first = try XCTUnwrap(slots.reserveRead())
        XCTAssertEqual(slots.writableSlot, 1)
        XCTAssertTrue(slots.replaceResource(at: 1, layout: layout))
        XCTAssertTrue(slots.uploaded(TacticalFramebufferImage(generation: generation, sequence: 2, layout: layout), at: 1))
        let second = try XCTUnwrap(slots.reserveRead())
        XCTAssertNil(slots.writableSlot)
        XCTAssertEqual(slots.inFlightReadCounts, [1, 1])
        XCTAssertFalse(slots.replaceResource(at: 0, layout: layout))
        XCTAssertFalse(slots.uploaded(TacticalFramebufferImage(generation: generation, sequence: 3, layout: layout), at: 1))
        XCTAssertEqual(slots.complete(first), .current)
        XCTAssertEqual(slots.complete(first), .rejected)
        XCTAssertEqual(slots.writableSlot, 0)
        XCTAssertEqual(slots.inFlightReadCounts, [0, 1])
        XCTAssertEqual(slots.complete(second), .current)
        XCTAssertEqual(slots.inFlightReadCounts, [0, 0])
    }

    func testFramebufferRetiredCompletionCannotMutateReplacementImage() throws {
        var slots = TacticalFramebufferSlots()
        let layout = try XCTUnwrap(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 8, byteCount: 16))
        XCTAssertTrue(slots.replaceResource(at: 0, layout: layout))
        XCTAssertTrue(slots.uploaded(TacticalFramebufferImage(generation: UUID(), sequence: 9, layout: layout), at: 0))
        let oldRead = try XCTUnwrap(slots.reserveRead())
        slots.retire()
        XCTAssertNil(slots.image)
        XCTAssertEqual(slots.inFlightReadCounts, [1, 0])
        let replacement = TacticalFramebufferImage(generation: UUID(), sequence: 1, layout: layout)
        XCTAssertTrue(slots.replaceResource(at: 1, layout: layout))
        XCTAssertTrue(slots.uploaded(replacement, at: 1))
        let replacementRead = try XCTUnwrap(slots.reserveRead())
        XCTAssertEqual(slots.complete(oldRead), .retired)
        XCTAssertEqual(slots.image, replacement)
        XCTAssertEqual(slots.inFlightReadCounts, [0, 1])
        XCTAssertEqual(slots.complete(oldRead), .rejected)
        XCTAssertEqual(slots.image, replacement)
        XCTAssertEqual(slots.complete(replacementRead), .current)
    }

    func testFramebufferResizeCannotReplaceBusyResourceAndRejectsLateToken() throws {
        var slots = TacticalFramebufferSlots()
        let small = try XCTUnwrap(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 8, byteCount: 16))
        let wide = try XCTUnwrap(TacticalFramebufferLayout.validate(width: 4, height: 2, bytesPerRow: 16, byteCount: 32))
        XCTAssertTrue(slots.replaceResource(at: 0, layout: small))
        XCTAssertTrue(slots.uploaded(TacticalFramebufferImage(generation: UUID(), sequence: 1, layout: small), at: 0))
        let oldRead = try XCTUnwrap(slots.reserveRead())
        let oldResource = slots.slots[0].resource
        slots.retire()
        XCTAssertFalse(slots.replaceResource(at: 0, layout: wide))
        XCTAssertEqual(slots.slots[0].layout, small)
        XCTAssertEqual(slots.complete(oldRead), .retired)
        XCTAssertTrue(slots.replaceResource(at: 0, layout: wide))
        XCTAssertNotEqual(slots.slots[0].resource, oldResource)
        let replacement = TacticalFramebufferImage(generation: UUID(), sequence: 1, layout: wide)
        XCTAssertTrue(slots.uploaded(replacement, at: 0))
        XCTAssertEqual(slots.complete(oldRead), .rejected)
        XCTAssertEqual(slots.image, replacement)
    }

    func testFramebufferGPUReadAdmissionIsBoundedWithoutWaiting() throws {
        var slots = TacticalFramebufferSlots()
        let layout = try XCTUnwrap(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 8, byteCount: 16))
        slots.replaceResource(at: 0, layout: layout)
        slots.uploaded(TacticalFramebufferImage(generation: UUID(), sequence: 1, layout: layout), at: 0)
        let first = try XCTUnwrap(slots.reserveRead())
        XCTAssertNotNil(slots.reserveRead())
        XCTAssertNotNil(slots.reserveRead())
        XCTAssertFalse(slots.canSubmitRead)
        XCTAssertNil(slots.reserveRead())
        XCTAssertEqual(slots.inFlightReadCounts, [3, 0])
        XCTAssertEqual(slots.complete(first), .current)
        XCTAssertTrue(slots.canSubmitRead)
    }

    func testFramebufferPendingKeepsOnlyLatestAndCountsBusyReplacement() throws {
        var pending = TacticalFramebufferPendingFrame()
        let generation = UUID()
        pending.replace(with: try framebufferFixture(generation: generation, sequence: 1), bothSlotsBusy: true)
        XCTAssertEqual(pending.busyDropCounts, 0)
        pending.replace(with: try framebufferFixture(generation: generation, sequence: 2), bothSlotsBusy: true)
        pending.replace(with: try framebufferFixture(generation: generation, sequence: 3), bothSlotsBusy: true)
        XCTAssertEqual(pending.frame?.sequence, 3)
        XCTAssertEqual(pending.frame?.pixels.count, 16)
        XCTAssertEqual(pending.busyDropCounts, 2)
        pending.clear()
        XCTAssertNil(pending.frame)
        XCTAssertEqual(pending.busyDropCounts, 2)
        pending.replace(with: try framebufferFixture(generation: generation, sequence: 4), bothSlotsBusy: false)
        pending.replace(with: try framebufferFixture(generation: generation, sequence: 5), bothSlotsBusy: false)
        XCTAssertEqual(pending.busyDropCounts, 2) // Not fabricated as GPU-busy drops.
    }

    func testFramebufferRevisionGenerationAndClearCursorFencesReplay() throws {
        var cursor = TacticalFramebufferDeliveryCursor()
        let firstGeneration = UUID()
        let secondGeneration = UUID()
        let first = try framebufferFixture(generation: firstGeneration, sequence: 10)
        let next = try framebufferFixture(generation: firstGeneration, sequence: 11)
        let replacement = try framebufferFixture(generation: secondGeneration, sequence: 1)
        XCTAssertTrue(cursor.accept(revision: 0, generation: firstGeneration, frame: first))
        XCTAssertFalse(cursor.accept(revision: 0, generation: firstGeneration, frame: next))
        XCTAssertFalse(cursor.accept(revision: 1, generation: firstGeneration, frame: replacement))
        XCTAssertTrue(cursor.accept(revision: 2, generation: firstGeneration, frame: nil))
        XCTAssertFalse(cursor.accept(revision: 3, generation: firstGeneration, frame: first))
        XCTAssertTrue(cursor.accept(revision: 4, generation: firstGeneration, frame: next))
        XCTAssertTrue(cursor.accept(revision: 5, generation: nil, frame: nil))
        XCTAssertFalse(cursor.accept(revision: 4, generation: firstGeneration, frame: next))
        XCTAssertTrue(cursor.accept(revision: 6, generation: secondGeneration, frame: replacement))
        XCTAssertEqual(cursor.revision, 6)
        XCTAssertEqual(cursor.generation, secondGeneration)
        XCTAssertEqual(cursor.sequence, 1)
    }

    func testFramebufferAspectFitAndTopLeftQuadOrientation() throws {
        let landscape = try XCTUnwrap(TacticalFramebufferLayout.aspectFit(
            imageWidth: 1920, imageHeight: 1080, bounds: CGSize(width: 800, height: 600)
        ))
        XCTAssertEqual(landscape, CGRect(x: 0, y: 75, width: 800, height: 450))
        XCTAssertEqual(TacticalFramebufferLayout.aspectFit(
            imageWidth: 100, imageHeight: 200, bounds: CGSize(width: 400, height: 100)
        ), CGRect(x: 175, y: 0, width: 50, height: 100))
        XCTAssertNil(TacticalFramebufferLayout.aspectFit(imageWidth: 0, imageHeight: 2, bounds: CGSize(width: 10, height: 10)))
        XCTAssertNil(TacticalFramebufferLayout.aspectFit(imageWidth: 2, imageHeight: 2, bounds: .zero))
        let vertices = TacticalFramebufferQuadVertex.vertices
        XCTAssertEqual(vertices.count, 6)
        XCTAssertEqual(vertices[0].position, SIMD2(-1, 1))
        XCTAssertEqual(vertices[0].uv, SIMD2(0, 0))
        XCTAssertEqual(vertices[1].position, SIMD2(-1, -1))
        XCTAssertEqual(vertices[1].uv, SIMD2(0, 1))
        XCTAssertEqual(vertices[2].uv, SIMD2(1, 0))
        XCTAssertEqual(MemoryLayout<TacticalFramebufferQuadVertex>.stride, 16)
    }

    func testFramebufferSRGBPrimaryReferencesForSampledColorMatrix() {
        let green = TacticalViewportColor.linearDisplayP3(hex: 0x00FF00)
        XCTAssertEqual(green.x, 0.1775380313, accuracy: 0.000001)
        XCTAssertEqual(green.y, 0.9668058011, accuracy: 0.000001)
        XCTAssertEqual(green.z, 0.0723974407, accuracy: 0.000001)
        let blue = TacticalViewportColor.linearDisplayP3(hex: 0x0000FF)
        XCTAssertEqual(blue.x, 0, accuracy: 0.000001)
        XCTAssertEqual(blue.y, 0, accuracy: 0.000001)
        XCTAssertEqual(blue.z, 0.9105199286, accuracy: 0.000001)
    }

    @MainActor
    func testFramebufferClearBeforeFirstInputRequiresExplicitNewGeneration() throws {
        let renderer = TacticalViewportRenderer()
        let frame = try framebufferFixture()
        renderer.clearFramebuffer()
        renderer.updateFramebuffer(frame)
        XCTAssertEqual(renderer.metricSnapshot.pendingCPUFrameBytes, 0)
        XCTAssertFalse(renderer.metricSnapshot.framebufferConfigured)
        XCTAssertEqual(renderer.metricSnapshot.rejectedFrameCount, 1)
        renderer.beginFramebufferGeneration(frame.generation)
        renderer.updateFramebuffer(frame)
        XCTAssertEqual(renderer.metricSnapshot.pendingCPUFrameBytes, 16)
        XCTAssertTrue(renderer.metricSnapshot.framebufferConfigured)
    }

    @MainActor
    func testFramebufferDetachedModeUsesSlateClearAndDropsPendingWithoutGPU() throws {
        let renderer = TacticalViewportRenderer()
        XCTAssertFalse(renderer.metricSnapshot.framebufferConfigured)
        renderer.setFramebufferSourceConfigured(true)
        let descriptor = MTLRenderPassDescriptor()
        renderer.configureRenderPass(descriptor, status: .emergencyAbort)
        let clear = TacticalViewportColor.linearDisplayP3(hex: 0x030509)
        XCTAssertEqual(descriptor.colorAttachments[0].clearColor.red, Double(clear.x), accuracy: 0.000000001)
        XCTAssertTrue(renderer.framebufferSummary.contains("CONTAINER DETACHED"))
        let frame = try framebufferFixture()
        renderer.beginFramebufferGeneration(frame.generation)
        renderer.updateFramebuffer(frame)
        XCTAssertEqual(renderer.metricSnapshot.pendingCPUFrameBytes, 16)
        XCTAssertNil(renderer.metricSnapshot.uploadedFrameSequence)
        renderer.clearFramebuffer()
        XCTAssertEqual(renderer.metricSnapshot.pendingCPUFrameBytes, 0)
        renderer.updateFramebuffer(frame) // Cannot resurrect the retired generation.
        XCTAssertEqual(renderer.metricSnapshot.pendingCPUFrameBytes, 0)
        XCTAssertEqual(renderer.metricSnapshot.rejectedFrameCount, 1)
        XCTAssertEqual(renderer.metricSnapshot.submittedFrames, 0)
        XCTAssertEqual(renderer.metricSnapshot.encodedDrawCallsCount, 0)
    }

    @MainActor
    func testFramebufferCoordinatorDismantleRetiresPendingAndRejectsLateInput() throws {
        let view = TacticalMetalViewportView(frame: .zero, device: nil)
        let coordinator = TacticalMetalViewportContainer.Coordinator()
        coordinator.bind(nil, to: view)
        let frame = try framebufferFixture()
        view.viewportRenderer.beginFramebufferGeneration(frame.generation)
        view.viewportRenderer.updateFramebuffer(frame)
        XCTAssertEqual(view.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 16)
        TacticalMetalViewportContainer.dismantleNSView(view, coordinator: coordinator)
        XCTAssertTrue(view.isPaused)
        XCTAssertNil(view.delegate)
        XCTAssertEqual(view.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)
        view.viewportRenderer.beginFramebufferGeneration(frame.generation)
        view.viewportRenderer.updateFramebuffer(frame)
        XCTAssertFalse(view.viewportRenderer.metricSnapshot.isImageAvailable)
        XCTAssertEqual(view.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)
    }

    @MainActor
    func testFramebufferObservationCancelledDuringBootstrapSettlesWithoutConnect() async {
        let client = FramebufferClient() // Frozen contract: offline initialization.
        let view = TacticalMetalViewportView(frame: .zero, device: nil)
        let coordinator = TacticalMetalViewportContainer.Coordinator()
        coordinator.bind(client, to: view)
        let retiredTask = coordinator.stop()
        await retiredTask?.value
        XCTAssertEqual(view.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)
        XCTAssertFalse(view.viewportRenderer.metricSnapshot.isImageAvailable)
        XCTAssertNil(coordinator.observationFailure)
        view.shutdown()
    }

    @MainActor
    func testFramebufferRegisteredObserverHandoffWaitsThroughNilAndCancelledSuccessor() async throws {
        let client = FramebufferClient()
        let control = MetalObservationHandoffControl()
        let coordinator = TacticalMetalViewportContainer.Coordinator(observationBarrier: { event in
            await control.handle(event)
        })
        let firstView = TacticalMetalViewportView(frame: .zero, device: nil)
        let secondView = TacticalMetalViewportView(frame: .zero, device: nil)
        defer {
            // Release barriers even on a failing assertion/throw; canceled old
            // registrations still own their real unsubscribe operation.
            control.releaseBootstrap.resolve(.succeeded)
            control.releaseCleanup.resolve(.succeeded)
            coordinator.stop()
            firstView.shutdown()
            secondView.shutdown()
        }
        coordinator.bind(client, to: firstView)
        let firstReady = await control.firstRegistered.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(firstReady, .succeeded)
        guard firstReady == .succeeded else { return }
        // This checks the REAL client's observer limit, not a stub counter.
        await assertFrameObserverOccupied(client)

        coordinator.bind(nil, to: firstView)
        coordinator.bind(client, to: secondView)
        let firstWait = await control.firstWaiting.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(firstWait, .succeeded)
        guard firstWait == .succeeded else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        await assertFrameObserverOccupied(client)

        // Old observation was demonstrably registered but bootstrap is canceled
        // before any iterator can trigger AsyncStream's automatic termination.
        control.releaseBootstrap.resolve(.succeeded)
        let cleanupHeld = await control.cleanupEntered.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(cleanupHeld, .succeeded)
        guard cleanupHeld == .succeeded else { return }
        await assertFrameObserverOccupied(client)

        // Cancel the successor WHILE it waits for old cleanup. Its replacement
        // must wait through that canceled task, not jump directly to observe().
        coordinator.bind(nil, to: secondView)
        coordinator.bind(client, to: firstView)
        let secondWait = await control.secondWaiting.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(secondWait, .succeeded)
        guard secondWait == .succeeded else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        await assertFrameObserverOccupied(client)

        control.releaseCleanup.resolve(.succeeded)
        let replacementReady = await control.secondRegistered.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(replacementReady, .succeeded)
        guard replacementReady == .succeeded else { return }
        XCTAssertEqual(control.registeredIDs.count, 2) // First + final; canceled successor never registered.
        XCTAssertNotEqual(control.registeredIDs[0], control.registeredIDs[1])
        XCTAssertEqual(control.barrierFailures, 0)
        XCTAssertNil(coordinator.observationFailure)
        await assertFrameObserverOccupied(client)

        let cleanup = coordinator.stop()
        let settled = MetalTestCompletion()
        let settlementWaiter = Task {
            await cleanup?.value
            settled.resolve(.succeeded)
        }
        defer { settlementWaiter.cancel() }
        let cleanupOutcome = await settled.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(cleanupOutcome, .succeeded)
        guard cleanupOutcome == .succeeded else { return }
        let probe = try await client.observeFrames() // Limit is free after exact unsubscription.
        await client.unsubscribe(id: probe.id)
    }

    @MainActor
    func testFramebufferDismantledCoordinatorHandsClientToDifferentCoordinator() async throws {
        let client = FramebufferClient()
        let control = MetalObservationHandoffControl()
        var first: TacticalMetalViewportContainer.Coordinator? = .init(observationBarrier: { await control.handle($0) })
        let second = TacticalMetalViewportContainer.Coordinator(observationBarrier: { await control.handle($0) })
        let weakFirst = MetalWeakCoordinatorReference(first)
        let firstView = TacticalMetalViewportView(frame: .zero, device: nil)
        let secondView = TacticalMetalViewportView(frame: .zero, device: nil)
        defer {
            // Installed before binding, fixture construction, or any await.
            control.releaseBootstrap.resolve(.succeeded)
            control.releaseCleanup.resolve(.succeeded)
            first?.stop()
            second.stop()
            firstView.shutdown()
            secondView.shutdown()
        }
        first?.bind(client, to: firstView)
        guard await metalSignal(control.firstRegistered) else { return }
        await assertFrameObserverOccupied(client)
        let frame = try framebufferFixture()
        firstView.viewportRenderer.beginFramebufferGeneration(frame.generation)
        firstView.viewportRenderer.updateFramebuffer(frame)
        XCTAssertEqual(firstView.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 16)
        if let first { TacticalMetalViewportContainer.dismantleNSView(firstView, coordinator: first) }
        first = nil // No local cleanup-task owner survives; the registry must own it.
        XCTAssertNil(weakFirst.value)
        XCTAssertTrue(firstView.isDismantled)
        XCTAssertEqual(firstView.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)

        second.bind(client, to: secondView)
        guard await metalSignal(control.firstWaiting) else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        XCTAssertNil(second.observationFailure)
        await assertFrameObserverOccupied(client)
        control.releaseBootstrap.resolve(.succeeded)
        guard await metalSignal(control.cleanupEntered) else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        await assertFrameObserverOccupied(client)
        control.releaseCleanup.resolve(.succeeded)
        guard await metalSignal(control.secondRegistered) else { return }
        XCTAssertEqual(control.registeredIDs.count, 2)
        XCTAssertEqual(control.barrierFailures, 0)
        XCTAssertNil(second.observationFailure)
        XCTAssertFalse(secondView.isDismantled)
        XCTAssertTrue(secondView.viewportRenderer.metricSnapshot.framebufferConfigured)
        XCTAssertFalse(secondView.viewportRenderer.metricSnapshot.isImageAvailable)
        XCTAssertEqual(secondView.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)
        // The old tail's completion must not erase the replacement's token.
        XCTAssertTrue(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
        await assertFrameObserverOccupied(client)
        guard await metalSettlement(second.stop()) else { return }
        XCTAssertFalse(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
        let finalObservation = try await client.observeFrames()
        await client.unsubscribe(id: finalObservation.id)
    }

    @MainActor
    func testFramebufferCrossCoordinatorCancelledSuccessorPreservesClientCleanupChain() async throws {
        let client = FramebufferClient()
        let control = MetalObservationHandoffControl()
        var first: TacticalMetalViewportContainer.Coordinator? = .init(observationBarrier: { await control.handle($0) })
        var middle: TacticalMetalViewportContainer.Coordinator? = .init(observationBarrier: { await control.handle($0) })
        let last = TacticalMetalViewportContainer.Coordinator(observationBarrier: { await control.handle($0) })
        let weakFirst = MetalWeakCoordinatorReference(first)
        let weakMiddle = MetalWeakCoordinatorReference(middle)
        let firstView = TacticalMetalViewportView(frame: .zero, device: nil)
        let middleView = TacticalMetalViewportView(frame: .zero, device: nil)
        let lastView = TacticalMetalViewportView(frame: .zero, device: nil)
        defer {
            control.releaseBootstrap.resolve(.succeeded)
            control.releaseCleanup.resolve(.succeeded)
            first?.stop()
            middle?.stop()
            last.stop()
            firstView.shutdown()
            middleView.shutdown()
            lastView.shutdown()
        }
        first?.bind(client, to: firstView)
        guard await metalSignal(control.firstRegistered) else { return }
        await assertFrameObserverOccupied(client)
        if let first { TacticalMetalViewportContainer.dismantleNSView(firstView, coordinator: first) }
        first = nil
        XCTAssertNil(weakFirst.value)
        middle?.bind(client, to: middleView)
        guard await metalSignal(control.firstWaiting) else { return }
        // A -> nil -> new A occurs on an entirely different coordinator. Its
        // canceled pending registration must itself remain a settlement owner.
        middle?.bind(nil, to: middleView)
        middle = nil
        XCTAssertNil(weakMiddle.value)
        last.bind(client, to: lastView)
        guard await metalSignal(control.secondWaiting) else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        await assertFrameObserverOccupied(client)
        control.releaseBootstrap.resolve(.succeeded)
        guard await metalSignal(control.cleanupEntered) else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        await assertFrameObserverOccupied(client)
        control.releaseCleanup.resolve(.succeeded)
        guard await metalSignal(control.secondRegistered) else { return }
        XCTAssertEqual(control.registeredIDs.count, 2) // First + last, never the canceled middle.
        XCTAssertEqual(control.barrierFailures, 0)
        XCTAssertNil(last.observationFailure)
        XCTAssertTrue(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
        XCTAssertEqual(lastView.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)
        await assertFrameObserverOccupied(client)
        guard await metalSettlement(last.stop()) else { return }
        XCTAssertFalse(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
    }

    @MainActor
    func testFramebufferCoordinatorDeinitAloneLeavesAwaitableCleanupForReplacement() async throws {
        let client = FramebufferClient()
        let control = MetalObservationHandoffControl()
        var first: TacticalMetalViewportContainer.Coordinator? = .init(observationBarrier: { await control.handle($0) })
        let second = TacticalMetalViewportContainer.Coordinator(observationBarrier: { await control.handle($0) })
        let weakFirst = MetalWeakCoordinatorReference(first)
        let firstView = TacticalMetalViewportView(frame: .zero, device: nil)
        let secondView = TacticalMetalViewportView(frame: .zero, device: nil)
        defer {
            control.releaseBootstrap.resolve(.succeeded)
            control.releaseCleanup.resolve(.succeeded)
            first?.stop()
            second.stop()
            firstView.shutdown()
            secondView.shutdown()
        }
        first?.bind(client, to: firstView)
        guard await metalSignal(control.firstRegistered) else { return }
        first = nil // Deliberately no stop/dismantle call.
        XCTAssertNil(weakFirst.value) // Registry and worker must not retain the coordinator.
        second.bind(client, to: secondView)
        guard await metalSignal(control.firstWaiting) else { return }
        XCTAssertEqual(control.registeredIDs.count, 1)
        await assertFrameObserverOccupied(client)
        control.releaseBootstrap.resolve(.succeeded)
        guard await metalSignal(control.cleanupEntered) else { return }
        await assertFrameObserverOccupied(client)
        control.releaseCleanup.resolve(.succeeded)
        guard await metalSignal(control.secondRegistered) else { return }
        XCTAssertEqual(control.registeredIDs.count, 2)
        XCTAssertNil(second.observationFailure)
        XCTAssertEqual(control.barrierFailures, 0)
        XCTAssertTrue(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
        guard await metalSettlement(second.stop()) else { return }
        XCTAssertFalse(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
    }

    @MainActor
    func testFramebufferIndependentActiveCoordinatorCannotSilentlyTakeOverClient() async throws {
        let client = FramebufferClient()
        let control = MetalObservationHandoffControl()
        let first = TacticalMetalViewportContainer.Coordinator(observationBarrier: { await control.handle($0) })
        let second = TacticalMetalViewportContainer.Coordinator(observationBarrier: { await control.handle($0) })
        let firstView = TacticalMetalViewportView(frame: .zero, device: nil)
        let secondView = TacticalMetalViewportView(frame: .zero, device: nil)
        defer {
            control.releaseBootstrap.resolve(.succeeded)
            control.releaseCleanup.resolve(.succeeded)
            first.stop()
            second.stop()
            firstView.shutdown()
            secondView.shutdown()
        }
        first.bind(client, to: firstView)
        guard await metalSignal(control.firstRegistered) else { return }
        second.bind(client, to: secondView) // First owner is active, not retiring.
        XCTAssertEqual(second.observationFailure, "FRAMEBUFFER OBSERVER ALREADY OWNED")
        XCTAssertEqual(control.registeredIDs.count, 1)
        XCTAssertEqual(secondView.viewportRenderer.metricSnapshot.pendingCPUFrameBytes, 0)
        await assertFrameObserverOccupied(client)
        let firstCleanup = first.stop()
        control.releaseBootstrap.resolve(.succeeded)
        control.releaseCleanup.resolve(.succeeded)
        guard await metalSettlement(firstCleanup) else { return }
        XCTAssertFalse(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
        second.bind(client, to: secondView) // Same failed binding is sticky; no silent retry.
        XCTAssertEqual(second.observationFailure, "FRAMEBUFFER OBSERVER ALREADY OWNED")
        XCTAssertEqual(control.registeredIDs.count, 1)
        XCTAssertFalse(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
        second.bind(nil, to: secondView)
        second.bind(client, to: secondView) // Explicit rebind is now legitimate.
        guard await metalSignal(control.secondRegistered) else { return }
        XCTAssertNil(second.observationFailure)
        await assertFrameObserverOccupied(client)
        guard await metalSettlement(second.stop()) else { return }
        XCTAssertFalse(TacticalMetalViewportContainer.Coordinator.retainedHandoffExists(for: client))
    }

    @MainActor
    func testFramebufferReadbackDeadlineSettlesAndRejectsLateGPUResolution() async {
        let completion = MetalTestCompletion()
        let outcome = await completion.value(until: ContinuousClock.now.advanced(by: .milliseconds(10)))
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(completion.resolve(.succeeded))
        XCTAssertFalse(completion.resolve(.failed))
        XCTAssertEqual(completion.outcome, .timedOut)
    }

    @MainActor
    func testFramebufferReadbackCancellationBeforeInstallSettlesExactlyOnce() async {
        let completion = MetalTestCompletion()
        let waiter = Task { await completion.value(until: ContinuousClock.now.advanced(by: .seconds(5))) }
        waiter.cancel()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(completion.resolve(.succeeded))
        XCTAssertEqual(completion.outcome, .cancelled)
    }

    @MainActor
    func testFramebufferReadbackTimeoutDoesNotReleaseInFlightOwnership() async throws {
        var slots = TacticalFramebufferSlots()
        let layout = try XCTUnwrap(TacticalFramebufferLayout.validate(width: 2, height: 2, bytesPerRow: 8, byteCount: 16))
        slots.replaceResource(at: 0, layout: layout)
        slots.uploaded(TacticalFramebufferImage(generation: UUID(), sequence: 1, layout: layout), at: 0)
        let realRead = try XCTUnwrap(slots.reserveRead())
        let completion = MetalTestCompletion()
        let outcome = await completion.value(until: ContinuousClock.now)
        XCTAssertEqual(outcome, .timedOut)
        slots.retire() // Same retirement policy as surface.stop(), NOT a GPU completion.
        XCTAssertEqual(slots.inFlightReadCounts, [1, 0])
        XCTAssertFalse(slots.replaceResource(at: 0, layout: layout))
        XCTAssertFalse(completion.resolve(.succeeded)) // Late waiter resolution cannot release a ticket.
        XCTAssertEqual(slots.inFlightReadCounts, [1, 0])
        XCTAssertEqual(slots.complete(realRead), .retired) // Only the actual read's completion reclaims it.
        XCTAssertEqual(slots.complete(realRead), .rejected)
    }

    @MainActor
    func testFramebufferOffscreenQuadReadbackColorOrientationAndLetterboxWhenGPUAvailable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable; framebuffer quad readback not checked")
        }
        let surface = TacticalFramebufferSurface()
        defer { surface.stop() } // Installed before any fixture/resource/encoder operation can throw.
        surface.setDevice(device)
        let frame = try framebufferFixture(pixels: [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255
        ])
        surface.enqueue(frame)
        XCTAssertNotNil(surface.image, surface.failure ?? "No uploaded image")
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 8, height: 4, mipmapped: false
        )
        targetDescriptor.usage = .renderTarget
        targetDescriptor.storageMode = TacticalFramebufferSurface.cpuVisibleStorageMode(for: device)
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = TacticalViewportColor.canvasClearColor
        let ticket: TacticalFramebufferReadTicket
        do {
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: descriptor))
            defer { encoder.endEncoding() } // Including a throwing nil-ticket assertion.
            ticket = try XCTUnwrap(surface.encode(in: encoder, logicalSize: CGSize(width: 8, height: 4)))
        }
        surface.attachCompletion(to: command, ticket: ticket)
        if target.storageMode == .managed {
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            defer { blit.endEncoding() }
            blit.synchronize(resource: target)
        }
        let completion = MetalTestCompletion()
        command.addCompletedHandler { buffer in
            let outcome: MetalTestCompletion.Outcome = buffer.status == .completed ? .succeeded : .failed
            completion.resolve(outcome)
        }
        command.commit()
        let outcome = await completion.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        guard outcome == .succeeded else {
            // This path is bounded independently of driver completion. Never
            // call surface.complete(ticket, ...) for a timeout/cancellation.
            // Retirement preserves physical read ownership; the real callback
            // and Metal's retained resource references remain authoritative.
            surface.stop()
            XCTFail("Offscreen GPU readback did not complete successfully: \(outcome)")
            return
        }
        var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            target.getBytes(base, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 4), mipmapLevel: 0)
        }
        // Top-left data row remains top-left on screen; two-column bars are clear.
        assertFramebufferPixel(pixels, x: 2, y: 0, width: 8, source: 0xFF0000)
        assertFramebufferPixel(pixels, x: 5, y: 0, width: 8, source: 0x00FF00)
        assertFramebufferPixel(pixels, x: 2, y: 3, width: 8, source: 0x0000FF)
        assertFramebufferPixel(pixels, x: 5, y: 3, width: 8, source: 0xFFFFFF)
        assertFramebufferPixel(pixels, x: 0, y: 0, width: 8, source: 0x030509)
        assertFramebufferPixel(pixels, x: 7, y: 3, width: 8, source: 0x030509)
    }

    private enum FramebufferFixtureError: Error { case invalidDimensions }

    @MainActor
    private func metalSignal(
        _ signal: MetalTestCompletion, file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let outcome = await signal.value(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(outcome, .succeeded, file: file, line: line)
        return outcome == .succeeded
    }

    @MainActor
    private func metalSettlement(
        _ task: Task<Void, Never>?, file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        let settled = MetalTestCompletion()
        let waiter = Task {
            await task?.value
            settled.resolve(.succeeded)
        }
        defer { waiter.cancel() } // Does not cancel or abandon the real cleanup owner.
        return await metalSignal(settled, file: file, line: line)
    }

    @MainActor
    private func assertFrameObserverOccupied(
        _ client: FramebufferClient, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let unexpected = try await client.observeFrames()
            await client.unsubscribe(id: unexpected.id)
            XCTFail("Expected an already registered single observer", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FrameError, .limitExceeded(.observers), file: file, line: line)
        }
    }

    private func framebufferFixture(
        generation: UUID = UUID(), sequence: UInt64 = 1,
        width: Int = 2, height: Int = 2, pixels: [UInt8]? = nil
    ) throws -> RGBAFrame {
        guard width > 0, height > 0, width <= 1920, height <= 1080 else {
            throw FramebufferFixtureError.invalidDimensions
        }
        let bytes = pixels ?? Array(repeating: UInt8(255), count: width * height * 4)
        // Matches sibling FrameContracts.swift's public throwing initializer;
        // it validates packed dimensions, positive sequence, and opaque alpha.
        return try RGBAFrame(
            generation: generation, sequence: sequence, width: width, height: height, bytesPerRow: width * 4,
            pixels: Data(bytes), receivedAt: ContinuousClock().now, colorEncoding: .assumedSRGB
        )
    }

    private func assertFramebufferPixel(
        _ pixels: [UInt8], x: Int, y: Int, width: Int, source: UInt32,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let linear = TacticalViewportColor.linearDisplayP3(hex: source)
        func encoded(_ value: Float) -> Double {
            let c = Double(value)
            return (c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255
        }
        let offset = (y * width + x) * 4
        XCTAssertEqual(Double(pixels[offset]), encoded(linear.z), accuracy: 2, file: file, line: line)
        XCTAssertEqual(Double(pixels[offset + 1]), encoded(linear.y), accuracy: 2, file: file, line: line)
        XCTAssertEqual(Double(pixels[offset + 2]), encoded(linear.x), accuracy: 2, file: file, line: line)
        XCTAssertEqual(pixels[offset + 3], 255, file: file, line: line)
    }

    private var clearSamples: [(status: InterlockStatus, encoded: SIMD3<Double>, linear: SIMD3<Double>)] {
        [
            (.locked, SIMD3(0.012, 0.020, 0.035),
             SIMD3(0.0010387232391950464, 0.0015274339325696594, 0.002594515316052632)),
            (.armed, SIMD3(0.035, 0.025, 0.010),
             SIMD3(0.002571564991253871, 0.001960676624535604, 0.0008911011902476781)),
            (.permissiveGranted, SIMD3(0.010, 0.040, 0.020),
             SIMD3(0.0011862338188080497, 0.0030188989189628484, 0.0016468361073529413)),
            (.emergencyAbort, SIMD3(0.060, 0.010, 0.010),
             SIMD3(0.004164442166017521, 0.0009108307943632686, 0.000844413814579606))
        ]
    }

    private func assertClearColor(
        _ actual: MTLClearColor, expected: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.red, expected.x, accuracy: 0.000000000001, file: file, line: line)
        XCTAssertEqual(actual.green, expected.y, accuracy: 0.000000000001, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.z, accuracy: 0.000000000001, file: file, line: line)
        XCTAssertEqual(actual.alpha, 1, file: file, line: line)
    }

    private func frame(sequence: UInt64, status: InterlockStatus) -> TelemetryFrame {
        TelemetryFrame(
            timestampNanoseconds: 10, sequenceNumber: sequence, subsystem: .interlock,
            health: .nominal, interlockState: status, payloadSize: 0
        )
    }
}

/// Immutable test bindings retain this box, never the coordinator under test.
/// ARC still zeroes the weak property when the coordinator is deinitialized.
@MainActor
private final class MetalWeakCoordinatorReference {
    private(set) weak var value: TacticalMetalViewportContainer.Coordinator?

    init(_ value: TacticalMetalViewportContainer.Coordinator?) {
        self.value = value
    }
}

/// One active waiter per instance. Resolution can originate on a Metal callback,
/// a real-clock watchdog, or cancellation, including before continuation install.
/// This is ONLY test settlement: it never resolves or releases a GPU read ticket.
private final class MetalTestCompletion: Sendable {
    enum Outcome: Equatable, Sendable { case succeeded, failed, timedOut, cancelled }
    private struct State: Sendable {
        var outcome: Outcome?
        var continuation: CheckedContinuation<Outcome, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var outcome: Outcome? { state.withLock { $0.outcome } }

    @discardableResult
    func resolve(_ outcome: Outcome) -> Bool {
        let resolution: (Bool, CheckedContinuation<Outcome, Never>?) = state.withLock { value in
            guard value.outcome == nil else { return (false, nil) }
            value.outcome = outcome
            let continuation = value.continuation
            value.continuation = nil
            return (true, continuation)
        }
        resolution.1?.resume(returning: outcome) // Never resume while holding the lock.
        return resolution.0
    }

    func value(
        until deadline: ContinuousClock.Instant, respondsToCancellation: Bool = true
    ) async -> Outcome {
        if ContinuousClock.now >= deadline { resolve(.timedOut) }
        let watchdog = Task { [self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch is CancellationError {
                return // Owned watchdog cancellation after another resolution.
            } catch {
                resolve(.failed)
                return
            }
            resolve(.timedOut)
        }
        defer { watchdog.cancel() }
        if respondsToCancellation {
            return await withTaskCancellationHandler {
                await installedValue()
            } onCancel: {
                self.resolve(.cancelled)
            }
        }
        // Controlled handoff barriers deliberately survive cancellation of the
        // observation worker, but still have a real-clock terminal deadline.
        return await installedValue()
    }

    private func installedValue() async -> Outcome {
        await withCheckedContinuation { continuation in
            let immediate: Outcome? = state.withLock { value in
                if let outcome = value.outcome { return outcome }
                guard value.continuation == nil else { return .failed }
                value.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

@MainActor
private final class MetalObservationHandoffControl {
    let firstRegistered = MetalTestCompletion()
    let secondRegistered = MetalTestCompletion()
    let firstWaiting = MetalTestCompletion()
    let secondWaiting = MetalTestCompletion()
    let releaseBootstrap = MetalTestCompletion()
    let cleanupEntered = MetalTestCompletion()
    let releaseCleanup = MetalTestCompletion()
    private(set) var registeredIDs: [UUID] = []
    private(set) var barrierFailures = 0
    private var waitingCount = 0

    func handle(_ event: TacticalMetalViewportContainer.Coordinator.ObservationEvent) async {
        switch event {
        case .waitingForPredecessor:
            waitingCount += 1
            if waitingCount == 1 { firstWaiting.resolve(.succeeded) }
            if waitingCount == 2 { secondWaiting.resolve(.succeeded) }
        case .registered(let id):
            registeredIDs.append(id)
            if registeredIDs.count == 1 {
                firstRegistered.resolve(.succeeded)
                let outcome = await releaseBootstrap.value(
                    until: ContinuousClock.now.advanced(by: .seconds(5)), respondsToCancellation: false
                )
                if outcome != .succeeded { barrierFailures += 1 }
            } else {
                secondRegistered.resolve(.succeeded)
            }
        case .willUnsubscribe(let id):
            if registeredIDs.first == id {
                cleanupEntered.resolve(.succeeded)
                let outcome = await releaseCleanup.value(
                    until: ContinuousClock.now.advanced(by: .seconds(5)), respondsToCancellation: false
                )
                if outcome != .succeeded { barrierFailures += 1 }
            }
        }
    }
}
