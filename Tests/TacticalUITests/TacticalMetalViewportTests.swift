import AppKit
import CoreGraphics
import Metal
import XCTest
import TacticalCore
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
