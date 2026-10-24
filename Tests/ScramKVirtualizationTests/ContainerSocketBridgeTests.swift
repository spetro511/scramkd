import Foundation
import ScramKCore
@testable import ScramKVirtualization
import XCTest
import os

final class ContainerSocketBridgeTests: XCTestCase {
    func testHighRiskCommandRejectedWhenGateLocked() async throws {
        try await BridgeFixture.withSession { session in
            do {
                _ = try await session.bridge.submitTool(name: "click", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
                XCTFail("Locked gate must reject every tool")
            } catch let error as BridgeError {
                guard case .gateRejected(.gateLocked, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.bytesWritten, 0)
                XCTAssertEqual(receipt?.transmissionStage, BridgeTransmissionStage.none)
            }
        }
    }

    func testHighRiskCommandRejectedWhenEmergencyAbort() async throws {
        try await BridgeFixture.withSession { session in
            await session.gate.tripEmergencyAbort()
            do {
                _ = try await session.bridge.submitTool(name: "press_hotkey", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
                XCTFail("Abort must reject every tool")
            } catch let error as BridgeError {
                guard case .gateRejected(.emergencyAbortActive, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.bytesWritten, 0)
            }
        }
    }

    func testUninitializedBridgeThrowsSubsystemFailure() async throws {
        let bridge = ContainerSocketBridge(interlockGate: HardwareInterlockGate(), configuration: BridgeFixture.configuration())
        do {
            _ = try await bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTFail("Detached bridge must reject dispatch")
        } catch let error as BridgeError { XCTAssertEqual(error, .detached) }
    }

    func testCommandExecutionUnderPermissiveGateState() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            let result = try await BridgeFixture.approveNext(session, intercept: intercept)
            XCTAssertEqual(result.receipt.transmissionStage, .complete)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            XCTAssertEqual(result.receipt.outcome, .responseReceived)
            XCTAssertGreaterThan(result.receipt.bytesWritten, 0)
            XCTAssertGreaterThan(result.receipt.bytesRead, 0)
            let status = await session.gate.currentStatus
            XCTAssertEqual(status, .locked)
        }
    }

    func testLowRiskCommandBypassesInterlockRequirement() async throws {
        // Only exact metadata schemas are exempt; tool names are never risk labels.
        try await BridgeFixture.withSession { session in
            let data = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":200,"method":"tools/list","params":{}}"#.utf8))
            let response = try XCTUnwrap(try MCPJSONCodec.decode(data).object)
            XCTAssertNotNil(response["result"]?.object?["tools"]?.array)
            let status = await session.gate.currentStatus
            XCTAssertEqual(status, .locked)
            let snapshot = await session.bridge.snapshot()
            XCTAssertNil(snapshot.latestTransfer?.approval)
            XCTAssertNil(snapshot.pendingIntercept)
        }
    }

    /// Separate live acceptance only. Infrastructure/protocol failures throw; no
    /// catch-return or swallowed initialization errors can produce a green test.
    func testLiveContainerHandshakeUnderPermissiveGateState() async throws {
        // This is the sole opt-in network/container test ID. Constructing the
        // probe and both clients is offline; run owns explicit attach/connect.
        try await LiveFrameProbe().run()
    }
}

/// Live-only harness. No static initializer, tool execution, input forwarding,
/// capture files, raw JSON logging, or pixel persistence. Only this file's
/// historical filtered live method constructs and starts an instance.
private final class LiveFrameProbe: Sendable {
    private enum Failure: Error, Sendable {
        case invalidInitialize, invalidCatalog, invalidCatalogReceipt
        case clientWasNotOffline, closed, connectTimeout, firstFrameTimeout
        case streamEnded, generationMismatch, invalidFrameState
        case invalidGeometry(width: Int, height: Int, bytes: Int)
        case rendererBudgetExceeded(width: Int, height: Int, bytes: Int)
        case invalidAlpha, invalidColorEncoding, metadataEncoding, cleanupFailed
    }

    private struct CleanupReport: Sendable {
        let issues: [String]
        let failure: (any Error)?
        let frame: FrameSnapshot
        let bridge: BridgeDetachReceipt
    }

    private struct State: Sendable {
        var closing = false
        var observationID: UUID?
        var generation: UUID?
        var connect: Task<Void, Never>?
        var reader: Task<Void, Never>?
        var cleanup: Task<CleanupReport, Never>?
    }

    private let gate: HardwareInterlockGate
    private let bridge: ContainerSocketBridge
    private let client: FramebufferClient
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        let gate = HardwareInterlockGate()
        self.gate = gate
        self.bridge = ContainerSocketBridge(interlockGate: gate)
        self.client = FramebufferClient()
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            do {
                try await verifyAndEmitMetadata()
            } catch {
                // Cleanup is installed before awaiting any worker/watchdog.
                // Preserve the actual operation error; cleanup failures add
                // independent XCTest failures rather than replace that error.
                let report = await beginCleanup().value
                for issue in report.issues { XCTFail("PHASE4_LIVE_CLEANUP \(issue)") }
                throw error
            }
            let report = await beginCleanup().value
            for issue in report.issues { XCTFail("PHASE4_LIVE_CLEANUP \(issue)") }
            if let failure = report.failure { throw failure }
            if let failure = report.frame.failure { throw failure }
            guard report.issues.isEmpty, report.bridge.handlesClosed,
                  report.bridge.outcome == .detached,
                  report.frame.generation == nil, report.frame.state == .detached else {
                throw Failure.cleanupFailed
            }
            try Task.checkCancellation()
        } onCancel: {
            // This owned cleanup task is never cancelled with its observer.
            _ = self.beginCleanup()
        }
    }

    private func verifyAndEmitMetadata() async throws {
        try Task.checkCancellation()
        let info = try await bridge.attach()
        let attached = await bridge.snapshot()
        guard BridgeLimits.supportedProtocols.contains(info.protocolVersion),
              !info.advertisedName.isEmpty, !info.advertisedVersion.isEmpty,
              attached.connectionState == .attached, attached.serverInfo == info,
              attached.generation == info.generation else { throw Failure.invalidInitialize }

        // Always inspect the real catalog. Never tools/call, even for screenshots.
        let raw = try await bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":"live-catalog","method":"tools/list"}"#.utf8))
        guard let envelope = try MCPJSONCodec.decode(raw).object,
              envelope["jsonrpc"] == .string("2.0"), envelope["error"] == nil,
              let wireID = envelope["id"]?.string, let requestID = UUID(uuidString: wireID),
              wireID == requestID.uuidString,
              let tools = envelope["result"]?.object?["tools"]?.array, !tools.isEmpty else {
            throw Failure.invalidCatalog
        }
        for tool in tools {
            guard let fields = tool.object, let name = fields["name"]?.string,
                  !name.isEmpty, name.utf8.count <= BridgeLimits.toolNameBytes,
                  fields["inputSchema"]?.object?["type"] == .string("object") else {
                throw Failure.invalidCatalog
            }
        }
        let catalogState = await bridge.snapshot()
        guard let receipt = catalogState.latestTransfer,
              receipt.requestID == requestID, receipt.connectionGeneration == info.generation,
              receipt.approval == nil, receipt.transmissionStage == .complete,
              receipt.hasCorrelatedResponse, receipt.outcome == .responseReceived,
              receipt.bytesWritten > 0, receipt.bytesRead > 0 else { throw Failure.invalidCatalogReceipt }

        let offline = await client.snapshot()
        guard offline.state == .detached, offline.generation == nil,
              offline.statistics.publishedFrames == 0 else { throw Failure.clientWasNotOffline }
        try Task.checkCancellation()
        let observation = try await client.observeFrames() // Before connect, never after it.
        let installed = state.withLock { state in
            guard !state.closing else { return false }
            state.observationID = observation.id
            return true
        }
        guard installed else {
            // A cancelled observe call may finish registration after owned cleanup
            // captured its IDs. Retire that late registration before returning.
            await client.unsubscribe(id: observation.id)
            throw CancellationError()
        }
        guard observation.current.frame == nil, observation.current.generation == nil else {
            throw Failure.clientWasNotOffline
        }

        let connectionResult = MCPIOCompletion<UUID>()
        let start = MCPIOCompletion<Void>()
        let connectDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        let client = self.client
        try state.withLock { state in
            guard !state.closing else { throw Failure.closed }
            // Startup is gated until this task is owned under the same state
            // fence that installs cleanup. Cancellation cannot start a late G2.
            let task = Task {
                do {
                    try await start.wait(deadline: connectDeadline)
                    try Task.checkCancellation()
                    connectionResult.finish(.success(try await client.connect()))
                } catch { connectionResult.finish(.failure(error)) }
            }
            state.connect = task
        }
        start.finish(.success(()))
        let generation: UUID
        do { generation = try await connectionResult.wait(deadline: connectDeadline) }
        catch MCPTransportError.deadlineExceeded { throw Failure.connectTimeout }
        guard ContinuousClock.now < connectDeadline else { throw Failure.connectTimeout }
        try Task.checkCancellation()
        try state.withLock { state in
            guard !state.closing else { throw Failure.closed }
            state.generation = generation
        }

        let firstFrame = MCPIOCompletion<RGBAFrame>()
        let frameDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        try state.withLock { state in
            guard !state.closing else { throw Failure.closed }
            state.reader = Task {
                for await delivery in observation.updates {
                    guard !Task.isCancelled else { return }
                    if let frame = delivery.frame {
                        guard ContinuousClock.now < frameDeadline else {
                            firstFrame.finish(.failure(Failure.firstFrameTimeout))
                            return
                        }
                        guard delivery.generation == generation, frame.generation == generation else {
                            firstFrame.finish(.failure(Failure.generationMismatch))
                            return
                        }
                        firstFrame.finish(.success(frame))
                        return
                    }
                    let status = await client.snapshot()
                    if let failure = status.failure {
                        firstFrame.finish(.failure(failure))
                        return
                    }
                    if status.state == .failed || status.state == .detached || status.state == .disconnecting {
                        firstFrame.finish(.failure(Failure.streamEnded))
                        return
                    }
                }
                firstFrame.finish(.failure(Failure.streamEnded))
            }
        }
        let frame: RGBAFrame
        do {
            // Real clock, independent of FrameTiming and the worker's update
            // timeout. The completion waiter handles cancellation exactly once;
            // no task-group timeout can wait on an uncancellable continuation.
            frame = try await firstFrame.wait(deadline: frameDeadline)
        } catch MCPTransportError.deadlineExceeded { throw Failure.firstFrameTimeout }
        guard ContinuousClock.now < frameDeadline else { throw Failure.firstFrameTimeout }
        try Task.checkCancellation()
        guard frame.generation == generation, frame.sequence > 0 else { throw Failure.generationMismatch }
        let (rowBytes, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: frame.height)
        guard frame.width > 0, frame.height > 0, !rowOverflow, !sizeOverflow,
              frame.bytesPerRow == rowBytes, frame.pixels.count == byteCount else {
            throw Failure.invalidGeometry(width: frame.width, height: frame.height, bytes: frame.pixels.count)
        }
        guard frame.width <= 1920, frame.height <= 1080, byteCount <= 1920 * 1080 * 4 else {
            throw Failure.rendererBudgetExceeded(width: frame.width, height: frame.height, bytes: byteCount)
        }
        guard frame.colorEncoding == .assumedSRGB else { throw Failure.invalidColorEncoding }
        guard stride(from: 3, to: frame.pixels.count, by: 4).allSatisfy({ frame.pixels[frame.pixels.startIndex + $0] == 255 }) else {
            throw Failure.invalidAlpha
        }
        let sampled = await client.snapshot()
        guard sampled.generation == generation, sampled.state == .connected, sampled.failure == nil,
              sampled.width == frame.width, sampled.height == frame.height,
              sampled.lastFrameAt != nil, sampled.statistics.publishedFrames >= frame.sequence,
              sampled.statistics.completedUpdates >= sampled.statistics.publishedFrames,
              sampled.statistics.receivedBinaryPayloadBytes > 0,
              sampled.statistics.receivedBinaryMessages > 0 else { throw Failure.invalidFrameState }
        let mcpStillAttached = await bridge.isBridgeActive
        let gateStatus = await gate.currentStatus
        guard mcpStillAttached, gateStatus == .locked else { throw Failure.invalidInitialize }
        try Task.checkCancellation()

        // Capture while active. This line reports validated observations, not a
        // test pass: the method returns successfully only after verified cleanup.
        let metadata: [String: Any] = [
            "serverAdvertisedName": info.advertisedName,
            "serverAdvertisedVersion": info.advertisedVersion,
            "protocolVersion": info.protocolVersion,
            "mcpGeneration": info.generation.uuidString,
            "toolsCount": tools.count,
            "frameGeneration": generation.uuidString,
            "frameWidth": frame.width, "frameHeight": frame.height,
            "frameBytesPerRow": frame.bytesPerRow, "frameBytes": frame.pixels.count,
            "frameSequence": frame.sequence, "frameColorEncoding": frame.colorEncoding.rawValue,
            "sourcePublishedFrames": sampled.statistics.publishedFrames,
            "sourceCompletedUpdates": sampled.statistics.completedUpdates,
            "sourceReceivedBinaryPayloadBytes": sampled.statistics.receivedBinaryPayloadBytes,
            "sourceReceivedBinaryMessages": sampled.statistics.receivedBinaryMessages,
            "matchesVerified1920x1080": frame.width == 1920 && frame.height == 1080,
            "verifiedFrameWidth": 1920, "verifiedFrameHeight": 1080,
            "rendererByteBudget": 1920 * 1080 * 4,
            "measurementScope": "LOCALLY_DECODED_SOURCE_NOT_GPU_OR_PRESENTATION",
            "cleanup": "PENDING"
        ]
        let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard let line = String(data: encoded, encoding: .utf8) else { throw Failure.metadataEncoding }
        print("PHASE4_LIVE_METADATA \(line)")
    }

    /// One independent cleanup task, shared by normal, failure and cancellation
    /// paths. Session resources are released BEFORE joining other owned tasks.
    private func beginCleanup() -> Task<CleanupReport, Never> {
        let action = state.withLock { state -> (Task<CleanupReport, Never>, Task<Void, Never>?, Task<Void, Never>?) in
            if let cleanup = state.cleanup { return (cleanup, state.connect, state.reader) }
            state.closing = true
            let observationID = state.observationID
            let expectedGeneration = state.generation
            let connect = state.connect
            let reader = state.reader
            let client = self.client
            let bridge = self.bridge
            let cleanup = Task {
                connect?.cancel()
                reader?.cancel()
                var issues: [String] = []
                var failure: (any Error)?
                if let observationID { await client.unsubscribe(id: observationID) }
                let captured = await client.snapshot()
                if let expectedGeneration, let active = captured.generation, expectedGeneration != active {
                    issues.append("FRAME_CLEANUP_GENERATION_MISMATCH")
                } else {
                    do { try await client.disconnect(generation: captured.generation) }
                    catch {
                        issues.append("FRAME_DISCONNECT_FAILED")
                        failure = error
                    }
                }
                let frameAfter = await client.snapshot()
                if frameAfter.generation != nil { issues.append("FRAME_GENERATION_RETAINED") }
                let receipt = await bridge.detach()
                if !receipt.handlesClosed || receipt.outcome == .cleanupIncomplete { issues.append("MCP_DETACH_INCOMPLETE") }
                // Unsubscribe/disconnect/detach above settle the iterator and
                // connection before these joins; no blocked timeout group exists.
                await connect?.value
                await reader?.value
                return CleanupReport(issues: issues, failure: failure, frame: frameAfter, bridge: receipt)
            }
            state.cleanup = cleanup
            return (cleanup, connect, reader)
        }
        action.1?.cancel()
        action.2?.cancel()
        return action.0
    }
}
