import Combine
import Foundation
import os
import ScramKCore
import XCTest
@testable import ScramKUI
@testable import ScramKVirtualization

/// Independent real-clock failure watchdogs. Manual frame time never controls
/// whether a missing test milestone is reported as a failure.
private func frameRootDeadline() -> ContinuousClock.Instant { ContinuousClock.now.advanced(by: .seconds(8)) }

private final class RootFrameClock: Sendable {
    private struct Sleeper: Sendable {
        let deadline: ContinuousClock.Instant
        let result: FramePromise<Void>
    }
    private struct State: Sendable {
        var now = ContinuousClock.now
        var sleepers: [UUID: Sleeper] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    var timing: FrameTiming {
        var timing = FrameTiming()
        timing.now = { [self] in now }
        timing.sleep = { [self] deadline in try await sleep(until: deadline) }
        return timing
    }
    func advance(_ duration: Duration) {
        let ready = state.withLock { value -> [FramePromise<Void>] in
            value.now = value.now.advanced(by: duration)
            let ids = value.sleepers.filter { $0.value.deadline <= value.now }.map(\.key)
            return ids.compactMap { value.sleepers.removeValue(forKey: $0)?.result }
        }
        for result in ready { result.finish(.success(())) }
    }
    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        let result = FramePromise<Void>()
        let ready = state.withLock { value -> Bool in
            if value.now >= deadline { return true }
            value.sleepers[id] = Sleeper(deadline: deadline, result: result)
            return false
        }
        if ready { return }
        defer { _ = state.withLock { $0.sleepers.removeValue(forKey: id) } }
        try await withTaskCancellationHandler { try await result.value() } onCancel: {
            result.finish(.failure(.cancelled))
        }
    }
}

/// Inert RFB protocol fixture. No sockets, URL configuration, processes, or input
/// forwarding. Replies follow observed handshake writes, never scheduler sleeps.
private final class RootFrameWire: FrameWireTransport, Sendable {
    private struct State: Sendable {
        var retired = false
        var inbound = [Data("RFB 003.008\n".utf8)]
        var reader: FrameCompletion<Data?>?
        var phase = 0
        var requests = 0
        var requestWaiters: [(Int, FrameCompletion<Void>)] = []
        var writes: [Data] = []
        var closeCount = 0
    }
    private enum Read: Sendable { case data(Data), wait, retired }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let timing: FrameTiming
    let opened = FrameCompletion<Void>()
    let closeStarted = FrameCompletion<Void>()
    let closed = FrameCompletion<Void>()
    let closeGate = FrameCompletion<Void>()
    let openGate: FrameCompletion<Void>?
    let unsupportedSecurity: Bool

    init(timing: FrameTiming, holdOpen: Bool = false, holdClose: Bool = false, unsupportedSecurity: Bool = false) {
        self.timing = timing
        self.openGate = holdOpen ? FrameCompletion<Void>() : nil
        self.unsupportedSecurity = unsupportedSecurity
        if !holdClose { closeGate.finish(.success(())) }
    }
    var requestCount: Int { state.withLock { $0.requests } }
    var closeCount: Int { state.withLock { $0.closeCount } }
    var writes: [Data] { state.withLock { $0.writes } }
    func releaseBarriers() {
        openGate?.finish(.success(()))
        closeGate.finish(.success(()))
    }
    func open(deadline: ContinuousClock.Instant) async throws {
        opened.finish(.success(()))
        if let openGate { try await openGate.value(deadline: deadline, stage: .connect, timing: timing) }
    }
    func sendBinary(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        try timing.check(deadline, stage: .write)
        let result = try state.withLock { value -> (Data?, [FrameCompletion<Void>]) in
            guard !value.retired else { throw FrameError.cancelled }
            value.writes.append(data)
            let response: Data?
            switch value.phase {
            case 0:
                guard data == Data("RFB 003.008\n".utf8) else { throw FrameError.protocolViolation(.rfbVersion) }
                response = Data([1, unsupportedSecurity ? 2 : 1])
            case 1:
                guard data == Data([1]) else { throw FrameError.securityRejected }
                response = Data([0, 0, 0, 0])
            case 2:
                guard data == Data([1]) else { throw FrameError.securityRejected }
                response = Self.serverInit
            case 3:
                guard data == RFBStreamDecoder.pixelFormatAndEncodings else { throw FrameError.protocolViolation(.pixelFormat) }
                response = nil
            default:
                guard data == Data([3, 0, 0, 0, 0, 0, 0, 2, 0, 1]) else { throw FrameError.protocolViolation(.serverMessage) }
                value.requests += 1
                response = nil
            }
            value.phase += 1
            let ready = value.requestWaiters.filter { $0.0 <= value.requests }.map(\.1)
            value.requestWaiters.removeAll { $0.0 <= value.requests }
            return (response, ready)
        }
        if let response = result.0 { push(response) }
        for result in result.1 { result.finish(.success(())) }
    }
    func receiveBinary(deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) async throws -> Data? {
        let result = FrameCompletion<Data?>()
        let choice = try state.withLock { value -> Read in
            if value.retired { return .retired }
            if !value.inbound.isEmpty { return .data(value.inbound.removeFirst()) }
            guard value.reader == nil else { throw FrameError.busy }
            value.reader = result
            return .wait
        }
        switch choice {
        case .data(let data): return data
        case .retired: throw FrameError.cancelled
        case .wait:
            defer { state.withLock { if $0.reader === result { $0.reader = nil } } }
            return try await result.value(deadline: deadline, stage: stage, timing: timing)
        }
    }
    func push(_ data: Data) {
        let reader = state.withLock { value -> FrameCompletion<Data?>? in
            if let reader = value.reader { value.reader = nil; return reader }
            value.inbound.append(data)
            return nil
        }
        reader?.finish(.success(data))
    }
    func waitForRequests(_ count: Int) async throws {
        let result = FrameCompletion<Void>()
        let ready = try state.withLock { value -> Bool in
            guard !value.retired else { throw FrameError.cancelled }
            if value.requests >= count { return true }
            value.requestWaiters.append((count, result))
            return false
        }
        if !ready { try await result.value(deadline: frameRootDeadline()) }
    }
    func retire() {
        let pending = state.withLock { value -> (FrameCompletion<Data?>?, [FrameCompletion<Void>]) in
            value.retired = true
            let reader = value.reader
            value.reader = nil
            let requests = value.requestWaiters.map(\.1)
            value.requestWaiters.removeAll()
            return (reader, requests)
        }
        pending.0?.finish(.failure(.cancelled))
        for request in pending.1 { request.finish(.failure(.cancelled)) }
        openGate?.finish(.failure(.cancelled))
    }
    func close(deadline: ContinuousClock.Instant) async throws {
        retire()
        closeStarted.finish(.success(()))
        try await closeGate.value(deadline: deadline, timing: timing)
        state.withLock { $0.closeCount += 1 }
        closed.finish(.success(()))
    }
    private static let serverInit = Data([
        0, 2, 0, 1, 32, 24, 0, 255, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
        0, 0, 0, 7, 102, 105, 120, 116, 117, 114, 101
    ])
    static let update = Data([
        0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0,
        1, 2, 3, 0, 4, 5, 6, 0
    ])
}

private final class RootFramePool: Sendable {
    private struct State: Sendable {
        var next = 0
        var replacementBeforePreviousClose = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let wires: [RootFrameWire]
    let timing: FrameTiming
    init(_ wires: [RootFrameWire], timing: FrameTiming) { self.wires = wires; self.timing = timing }
    var made: Int { state.withLock { $0.next } }
    var replacementBeforePreviousClose: Bool { state.withLock { $0.replacementBeforePreviousClose } }
    func make() -> any FrameWireTransport {
        let index = state.withLock { value -> Int in let index = value.next; value.next += 1; return index }
        if index > 0, index <= wires.count, wires[index - 1].closeCount == 0 {
            state.withLock { $0.replacementBeforePreviousClose = true }
        }
        if index < wires.count { return wires[index] }
        return RootFrameWire(timing: timing, unsupportedSecurity: true)
    }
    func releaseBarriers() { for wire in wires { wire.releaseBarriers() } }
}

private enum RootFrameFixtureError: Error { case pythonUnavailable }
private enum RootMCPFixtureMode: String { case normal, malformedPing }

@MainActor
final class ConsoleFramebufferControllerTests: XCTestCase {
    func testNilClientPreservesD1OfflineSurface() async {
        let controller = ConsoleStateController(interlockGate: HardwareInterlockGate())
        XCTAssertNil(controller.framebufferClient)
        XCTAssertNil(controller.frameSnapshot)
        XCTAssertNil(controller.frameStatistics)
        XCTAssertFalse(controller.isFramebufferConfigured)
        XCTAssertEqual(controller.frameConnectionState, .detached)
        await controller.start()
        XCTAssertNil(controller.frameSnapshot)
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        await controller.stop()
    }

    func testStartupObservesOnlyCoarseStateAndNeverConnectsOrConsumesPixelObserver() async throws {
        let clock = RootFrameClock()
        let wire = RootFrameWire(timing: clock.timing)
        try await withFixture(clock: clock, wires: [wire]) { gate, _, client, controller, pool in
            XCTAssertTrue(controller.isFramebufferConfigured)
            XCTAssertNotNil(controller.framebufferClient)
            XCTAssertEqual(controller.frameConnectionState, .detached)
            XCTAssertEqual(pool.made, 0)
            let pixels = try await client.observeFrames()
            XCTAssertNil(pixels.current.frame)
            await client.unsubscribe(id: pixels.id)
            var extras: [FrameStateObservation] = []
            for _ in 0..<3 { extras.append(try await client.observeState()) }
            do { _ = try await client.observeState(); XCTFail("Root must own exactly one state subscription") }
            catch { XCTAssertEqual(error as? FrameError, .limitExceeded(.observers)) }
            for source in extras { await client.unsubscribe(id: source.id) }
            let history = await gate.transitionHistory
            XCTAssertTrue(history.isEmpty)
            XCTAssertTrue(wire.writes.isEmpty)
        }
    }

    func testExplicitCurrentBridgeAttachStartsOwnedViewerAndCoarseMetricsContainNoPixels() async throws {
        let clock = RootFrameClock()
        let wire = RootFrameWire(timing: clock.timing)
        try await withFixture(clock: clock, wires: [wire]) { gate, _, _, controller, pool in
            try await watched(Task { try await controller.attachBridge() })
            XCTAssertEqual(pool.made, 1)
            XCTAssertEqual(controller.bridgeConnectionState, .attached)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertNil(controller.frameSnapshot?.lastFrameAt)
            try await wire.waitForRequests(1)
            wire.push(RootFrameWire.update)
            let snapshot = try await frameState(controller) { $0.statistics.publishedFrames == 1 }
            XCTAssertEqual(snapshot.width, 2)
            XCTAssertEqual(snapshot.height, 1)
            XCTAssertNotNil(snapshot.lastFrameAt)
            XCTAssertGreaterThan(snapshot.statistics.receivedBinaryPayloadBytes, 0)
            XCTAssertFalse(Mirror(reflecting: snapshot).children.contains { $0.value is Data })
            XCTAssertFalse(Mirror(reflecting: snapshot).children.contains { $0.label == "pixels" || $0.label == "frame" })
            let history = await gate.transitionHistory
            XCTAssertTrue(history.isEmpty)
            XCTAssertEqual(controller.currentStatus, .locked)
        }
    }

    func testUnsupportedFrameSecurityIsStandbyNotFailedMCPAttachOrGateTransition() async throws {
        let clock = RootFrameClock()
        let wire = RootFrameWire(timing: clock.timing, unsupportedSecurity: true)
        try await withFixture(clock: clock, wires: [wire]) { gate, _, _, controller, pool in
            try await watched(Task { try await controller.attachBridge() })
            XCTAssertEqual(controller.bridgeConnectionState, .attached)
            XCTAssertNotNil(controller.serverInfo)
            XCTAssertEqual(controller.frameConnectionState, .failed)
            XCTAssertEqual(controller.frameSnapshot?.failure, .unsupportedSecurity([2]))
            XCTAssertTrue(controller.auditRows.contains { $0.subsystem == "FRAME" && $0.description.contains("STANDBY") })
            XCTAssertFalse(controller.auditRows.contains { $0.description.hasPrefix("ATTACH FAILED") })
            let metadata = try await controller.dispatchMCPCommand(Data("{\"jsonrpc\":\"2.0\",\"id\":501,\"method\":\"ping\"}".utf8))
            XCTAssertFalse(metadata.isEmpty)
            await controller.start()
            XCTAssertEqual(pool.made, 1, "Observation refresh must not reconnect")
            let history = await gate.transitionHistory
            XCTAssertTrue(history.isEmpty)
        }
    }

    func testObsoleteBridgeAttachCompletionCannotStartViewerForNewBridgeGeneration() async throws {
        let clock = RootFrameClock()
        let wire = RootFrameWire(timing: clock.timing)
        let entered = FrameCompletion<Void>()
        let release = FrameCompletion<Void>()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        defer { release.finish(.success(())) }
        try await withFixture(clock: clock, wires: [wire], makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                bridgeAttachCompletionBarrier: {
                    let first = calls.withLock { value -> Bool in value += 1; return value == 1 }
                    if first {
                        entered.finish(.success(()))
                        do { try await release.value(deadline: frameRootDeadline()) }
                        catch { XCTFail("MCP attach completion barrier failed: \(error)") }
                    }
                }
            )
        }) { _, _, _, controller, pool in
            let oldAttach = Task { try await controller.attachBridge() }
            defer { oldAttach.cancel(); release.finish(.success(())) }
            try await entered.value(deadline: frameRootDeadline())
            let oldBridge = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            XCTAssertEqual(pool.made, 0)
            try await watched(Task { await controller.detachBridge() })
            try await watched(Task { try await controller.attachBridge() })
            let newBridge = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            let newFrame = try XCTUnwrap(controller.frameSnapshot?.generation)
            XCTAssertNotEqual(oldBridge, newBridge)
            XCTAssertEqual(pool.made, 1)
            release.finish(.success(()))
            try await watched(oldAttach)
            XCTAssertEqual(pool.made, 1, "G1's completion must not create another viewer against G2")
            XCTAssertEqual(controller.bridgeSnapshot?.generation, newBridge)
            XCTAssertEqual(controller.frameSnapshot?.generation, newFrame)
            XCTAssertEqual(wire.closeCount, 0)
        }
    }

    func testStopCancelsConnectBeforeGenerationReturnAndFreshAttachUsesNewTransport() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing, holdOpen: true)
        let second = RootFrameWire(timing: clock.timing)
        try await withFixture(clock: clock, wires: [first, second]) { _, _, _, controller, pool in
            let oldAttach = Task { try await controller.attachBridge() }
            defer { oldAttach.cancel(); first.releaseBarriers() }
            try await first.opened.value(deadline: frameRootDeadline())
            let stopped = Task { await controller.stop() }
            try await watched(stopped)
            _ = try await watched(oldAttach)
            XCTAssertEqual(first.closeCount, 1)
            XCTAssertEqual(controller.ownedFramebufferConnectionCount, 0)
            await controller.start()
            try await watched(Task { try await controller.attachBridge() })
            XCTAssertEqual(pool.made, 2)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertEqual(second.closeCount, 0)
        }
    }

    func testOldConnectCompletionCannotPublishIntoReplacementSession() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing)
        let second = RootFrameWire(timing: clock.timing)
        let entered = FrameCompletion<Void>()
        let release = FrameCompletion<Void>()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        defer { release.finish(.success(())) }
        try await withFixture(clock: clock, wires: [first, second], makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                frameConnectCompletionBarrier: {
                    let first = calls.withLock { value -> Bool in value += 1; return value == 1 }
                    if first {
                        entered.finish(.success(()))
                        do { try await release.value(deadline: frameRootDeadline()) }
                        catch { XCTFail("Connect completion barrier failed: \(error)") }
                    }
                }
            )
        }) { _, _, _, controller, _ in
            let oldAttach = Task { try await controller.attachBridge() }
            defer { oldAttach.cancel(); release.finish(.success(())) }
            try await entered.value(deadline: frameRootDeadline())
            try await watched(Task { await controller.stop() })
            await controller.start()
            try await watched(Task { try await controller.attachBridge() })
            let replacement = try XCTUnwrap(controller.frameSnapshot?.generation)
            let rows = controller.auditRows.map(\.id)
            release.finish(.success(()))
            try await watched(oldAttach)
            XCTAssertEqual(controller.frameSnapshot?.generation, replacement)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertEqual(second.closeCount, 0)
            XCTAssertEqual(controller.auditRows.map(\.id), rows)
        }
    }

    func testSameSessionLateAbortCannotRetireReplacementViewer() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing)
        let second = RootFrameWire(timing: clock.timing)
        let accepted = FrameCompletion<Void>()
        let release = FrameCompletion<Void>()
        defer { release.finish(.success(())) }
        try await withFixture(clock: clock, wires: [first, second], makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                commandCompletionBarrier: { command in
                    if command == .emergencyAbort {
                        accepted.finish(.success(()))
                        do { try await release.value(deadline: frameRootDeadline()) }
                        catch { XCTFail("Abort test barrier failed: \(error)") }
                    }
                }
            )
        }) { _, bridge, _, controller, _ in
            try await watched(Task { try await controller.attachBridge() })
            let oldFrame = try XCTUnwrap(controller.frameSnapshot?.generation)
            let abort = Task { await controller.emergencyAbort() }
            defer { release.finish(.success(())); abort.cancel() }
            try await accepted.value(deadline: frameRootDeadline())
            try await watched(Task { await controller.detachBridge() })
            try await controller.resetAbort()
            try await watched(Task { try await controller.attachBridge() })
            let replacement = try XCTUnwrap(controller.frameSnapshot?.generation)
            XCTAssertNotEqual(oldFrame, replacement)
            try await controller.armGate()
            let pending = FrameCompletion<Void>()
            let pendingObservation = controller.$bridgeSnapshot.compactMap { $0?.pendingIntercept }
                .filter { $0.phase == .awaitingApproval }.prefix(1).sink { _ in pending.finish(.success(())) }
            defer { pendingObservation.cancel() }
            let call = Task { try await controller.submitTool(name: "root_frame_fixture", argumentsJSON: Data("{}".utf8)) }
            defer { call.cancel() }
            try await pending.value(deadline: frameRootDeadline())
            let key = try XCTUnwrap(controller.pendingIntercept?.approval)
            let grant = controller.commandRequest(.grantPermissive)
            let bridgeBefore = await bridge.snapshot()
            release.finish(.success(()))
            try await watched(abort)
            let bridgeAfter = await bridge.snapshot(after: bridgeBefore.cursor)
            XCTAssertTrue(bridgeAfter.events.isEmpty)
            XCTAssertEqual(bridgeAfter.connectionState, .attached)
            XCTAssertEqual(bridgeAfter.generation, bridgeBefore.generation)
            XCTAssertEqual(bridgeAfter.pendingIntercept?.approval, key)
            XCTAssertEqual(bridgeAfter.pendingIntercept?.phase, .awaitingApproval)
            XCTAssertEqual(controller.frameSnapshot?.generation, replacement)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertEqual(first.closeCount, 1)
            XCTAssertEqual(second.closeCount, 0)
            await controller.perform(grant)
            let result = try await watched(call)
            XCTAssertEqual(result.receipt.approval, key)
        }
    }

    func testStopUpgradesViewerOnlyCancellationRetirementToIncludeMCP() async throws {
        let clock = RootFrameClock()
        let wire = RootFrameWire(timing: clock.timing, holdClose: true)
        let connected = FrameCompletion<Void>()
        let releaseCompletion = FrameCompletion<Void>()
        defer { releaseCompletion.finish(.success(())); wire.releaseBarriers() }
        try await withFixture(clock: clock, wires: [wire], makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                frameConnectCompletionBarrier: {
                    connected.finish(.success(()))
                    do { try await releaseCompletion.value(deadline: frameRootDeadline()) }
                    catch {
                        if (error as? FrameError) != .cancelled && !(error is CancellationError) {
                            XCTFail("Viewer cancellation barrier failed: \(error)")
                        }
                    }
                }
            )
        }) { _, bridge, _, controller, _ in
            let attach = Task { try await controller.attachBridge() }
            defer { attach.cancel(); releaseCompletion.finish(.success(())); wire.releaseBarriers() }
            try await connected.value(deadline: frameRootDeadline())
            attach.cancel() // MCP is accepted; cancellation starts viewer-only cleanup.
            releaseCompletion.finish(.success(()))
            try await wire.closeStarted.value(deadline: frameRootDeadline())
            let before = await bridge.snapshot()
            XCTAssertEqual(before.connectionState, .attached)
            let stopping = FrameCompletion<Void>()
            let observation = controller.$isObserving.dropFirst().filter { !$0 }.prefix(1).sink { _ in
                stopping.finish(.success(()))
            }
            defer { observation.cancel() }
            let stop = Task { await controller.stop() }
            try await stopping.value(deadline: frameRootDeadline())
            wire.releaseBarriers()
            try await watched(stop)
            try await watched(attach)
            let after = await bridge.snapshot()
            XCTAssertEqual(after.connectionState, .detached)
            XCTAssertFalse(controller.isObserving)
            XCTAssertEqual(wire.closeCount, 1)
            XCTAssertEqual(controller.ownedFramebufferConnectionCount, 0)
        }
    }

    func testHeldOldCoarseFrameCallbackCannotRestoreRetiredGenerationWithinSameSession() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing)
        let second = RootFrameWire(timing: clock.timing)
        let entered = FrameCompletion<Void>()
        let release = FrameCompletion<Void>()
        let nextDelivery = FrameCompletion<Void>()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        defer { release.finish(.success(())) }
        try await withFixture(clock: clock, wires: [first, second], makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                frameStateDeliveryBarrier: {
                    let call = calls.withLock { value -> Int in value += 1; return value }
                    if call == 1 {
                        entered.finish(.success(()))
                        do { try await release.value(deadline: frameRootDeadline()) }
                        catch { XCTFail("Frame state delivery barrier failed: \(error)") }
                    } else if call == 2 {
                        // The old callback completed before the loop fetched this
                        // latest-one update. No yield/poll proves callback ordering.
                        nextDelivery.finish(.success(()))
                    }
                }
            )
        }) { _, _, _, controller, _ in
            try await watched(Task { try await controller.attachBridge() })
            try await entered.value(deadline: frameRootDeadline())
            let old = try XCTUnwrap(controller.frameSnapshot?.generation)
            try await watched(Task { await controller.detachBridge() })
            try await watched(Task { try await controller.attachBridge() })
            let replacement = try XCTUnwrap(controller.frameSnapshot?.generation)
            XCTAssertNotEqual(old, replacement)
            let rows = controller.auditRows.map(\.id)
            release.finish(.success(()))
            try await nextDelivery.value(deadline: frameRootDeadline())
            XCTAssertEqual(controller.frameSnapshot?.generation, replacement)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertEqual(controller.auditRows.map(\.id), rows)
            XCTAssertEqual(second.closeCount, 0)
        }
    }

    func testAbortCoreTransitionDoesNotWaitForViewerCloseAndCleanupBusyIsNotFakeDetached() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing, holdClose: true)
        let second = RootFrameWire(timing: clock.timing)
        defer { first.releaseBarriers() }
        try await withFixture(clock: clock, wires: [first, second]) { gate, _, _, controller, pool in
            try await watched(Task { try await controller.attachBridge() })
            let aborted = FrameCompletion<Void>()
            let observation = controller.$currentStatus.filter { $0 == .emergencyAbort }.prefix(1).sink { _ in aborted.finish(.success(())) }
            defer { observation.cancel(); first.releaseBarriers() }
            let abort = Task { await controller.emergencyAbort() }
            defer { abort.cancel() }
            try await first.closeStarted.value(deadline: frameRootDeadline())
            try await aborted.value(deadline: frameRootDeadline())
            let status = await gate.currentStatus
            XCTAssertEqual(status, .emergencyAbort, "Core abort cannot wait behind held viewer close")
            clock.advance(.seconds(3))
            try await watched(abort)
            XCTAssertEqual(controller.frameConnectionState, .failed)
            XCTAssertNotNil(controller.frameSnapshot?.generation, "Failed cleanup must retain actor ownership")
            XCTAssertEqual(controller.ownedFramebufferConnectionCount, 1)
            try await controller.resetAbort()
            do {
                try await controller.attachBridge()
                XCTFail("Fresh attach must remain Busy until viewer cleanup actually settles")
            } catch { XCTAssertEqual(error as? FrameError, .busy) }
            XCTAssertEqual(pool.made, 1)
            first.releaseBarriers()
            try await watched(Task { await controller.detachBridge() })
            try await watched(Task { try await controller.attachBridge() })
            XCTAssertEqual(pool.made, 2)
            XCTAssertEqual(controller.frameConnectionState, .connected)
        }
    }

    func testPendingMCPApprovalIsUnaffectedByReadonlyViewer() async throws {
        let clock = RootFrameClock()
        let wire = RootFrameWire(timing: clock.timing)
        try await withFixture(clock: clock, wires: [wire]) { _, _, _, controller, _ in
            try await watched(Task { try await controller.attachBridge() })
            let viewer = try XCTUnwrap(controller.frameSnapshot?.generation)
            try await controller.armGate()
            let pending = FrameCompletion<Void>()
            let observation = controller.$bridgeSnapshot.compactMap { $0?.pendingIntercept }.filter { $0.phase == .awaitingApproval }.prefix(1).sink { _ in pending.finish(.success(())) }
            defer { observation.cancel() }
            let call = Task { try await controller.submitTool(name: "root_frame_fixture", argumentsJSON: Data("{}".utf8)) }
            defer { call.cancel() }
            try await pending.value(deadline: frameRootDeadline())
            XCTAssertEqual(controller.currentStatus, .armed)
            XCTAssertEqual(controller.frameSnapshot?.generation, viewer)
            await controller.perform(controller.commandRequest(.grantPermissive))
            let result = try await watched(call)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            XCTAssertEqual(controller.frameSnapshot?.generation, viewer)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        }
    }

    func testReceivedViewerRetiresOnMCPAssociationLossAndRecoversOnlyAfterF1Closes() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing, holdClose: true)
        let second = RootFrameWire(timing: clock.timing)
        let attachOrder = OSAllocatedUnfairLock(initialState: (calls: 0, beforeFrameClose: false))
        let recoveryWaiting = FrameCompletion<Void>()
        defer { first.releaseBarriers() }
        try await withFixture(clock: clock, wires: [first, second], mcpMode: .malformedPing, makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                bridgeAttachBarrier: {
                    let closed = first.closeCount > 0
                    attachOrder.withLock {
                        $0.calls += 1
                        if $0.calls > 1 && !closed { $0.beforeFrameClose = true }
                    }
                },
                bridgeRetirementWaitMilestone: { recoveryWaiting.finish(.success(())) }
            )
        }) { gate, bridge, _, controller, pool in
            try await watched(Task { try await controller.attachBridge() })
            try await first.waitForRequests(1)
            first.push(RootFrameWire.update)
            let received = try await frameState(controller) { $0.statistics.publishedFrames == 1 && $0.lastFrameAt != nil }
            let oldFrame = try XCTUnwrap(received.generation)
            let oldBridge = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            XCTAssertEqual(received.state, .connected)

            try await triggerMCPFailure(controller)
            XCTAssertNotEqual(controller.bridgeConnectionState, .attached)
            XCTAssertNil(controller.frameSnapshot?.lastFrameAt, "Association loss must synchronously clear STREAMING")
            XCTAssertNotEqual(controller.frameConnectionState, .connected)
            try await first.closeStarted.value(deadline: frameRootDeadline())
            let terminal = try await frameState(controller) {
                $0.generation == oldFrame && $0.state == .disconnecting && $0.lastFrameAt == nil
            }
            XCTAssertNil(terminal.width)
            XCTAssertEqual(controller.ownedFramebufferConnectionCount, 1, "F1 remains owned until close acknowledges")
            XCTAssertEqual(pool.made, 1)
            try await settleFailedMCPForRecovery(bridge)
            try await explicitlyLockGateForRecovery(gate: gate, controller: controller)

            let recovery = Task { try await controller.attachBridge() }
            defer { recovery.cancel(); first.releaseBarriers() }
            try await recoveryWaiting.value(deadline: frameRootDeadline())
            XCTAssertEqual(attachOrder.withLock { $0.calls }, 1, "G2 must not be submitted while F1 close is held")
            XCTAssertEqual(first.closeCount, 0)
            first.releaseBarriers()
            try await watched(recovery)
            XCTAssertEqual(first.closeCount, 1)
            XCTAssertFalse(attachOrder.withLock { $0.beforeFrameClose }, "G2 MCP attach entered before captured F1 cleanup")
            XCTAssertEqual(pool.made, 2)
            XCTAssertEqual(controller.bridgeConnectionState, .attached)
            XCTAssertNotEqual(controller.bridgeSnapshot?.generation, oldBridge)
            XCTAssertNotEqual(controller.frameSnapshot?.generation, oldFrame)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertNil(controller.frameSnapshot?.lastFrameAt, "F1's received timestamp must not survive under F2")
            XCTAssertEqual(second.closeCount, 0)
            try await second.waitForRequests(1)
            second.push(RootFrameWire.update)
            let newFrame = try await frameState(controller) { $0.statistics.publishedFrames == 1 && $0.lastFrameAt != nil }
            XCTAssertNotEqual(newFrame.generation, oldFrame)
            XCTAssertEqual(newFrame.state, .connected)
        }
    }

    func testAssociationLossCleanupFailureRetainsBusyOwnershipAndNeverRestoresStreaming() async throws {
        let clock = RootFrameClock()
        let first = RootFrameWire(timing: clock.timing, holdClose: true)
        let second = RootFrameWire(timing: clock.timing)
        let attaches = OSAllocatedUnfairLock(initialState: 0)
        defer { first.releaseBarriers() }
        try await withFixture(clock: clock, wires: [first, second], mcpMode: .malformedPing, makeController: { gate, bridge, client in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, framebufferClient: client, observationDeliveryBarrier: nil,
                bridgeAttachBarrier: { attaches.withLock { $0 += 1 } }
            )
        }) { gate, bridge, _, controller, pool in
            try await watched(Task { try await controller.attachBridge() })
            try await first.waitForRequests(1)
            first.push(RootFrameWire.update)
            let received = try await frameState(controller) { $0.lastFrameAt != nil }
            let oldFrame = try XCTUnwrap(received.generation)
            try await triggerMCPFailure(controller)
            try await first.closeStarted.value(deadline: frameRootDeadline())
            clock.advance(.seconds(3))
            let failed = try await frameState(controller) {
                $0.generation == oldFrame && $0.state == .failed && $0.failure == .timedOut(.cleanup)
            }
            XCTAssertNil(failed.lastFrameAt)
            XCTAssertNil(failed.width)
            XCTAssertEqual(controller.ownedFramebufferConnectionCount, 1)
            try await settleFailedMCPForRecovery(bridge)
            try await explicitlyLockGateForRecovery(gate: gate, controller: controller)
            do {
                try await watched(Task { try await controller.attachBridge() })
                XCTFail("F1 cleanup failure must not silently retain its viewer under G2")
            } catch { XCTAssertEqual(error as? FrameError, .busy) }
            XCTAssertEqual(attaches.withLock { $0 }, 1, "Busy must be reported before submitting a G2 MCP attach")
            XCTAssertEqual(pool.made, 1)
            XCTAssertNotEqual(controller.frameConnectionState, .connected)
            XCTAssertNil(controller.frameSnapshot?.lastFrameAt)
            first.releaseBarriers()
            try await watched(Task { await controller.detachBridge() })
            try await watched(Task { try await controller.attachBridge() })
            XCTAssertEqual(first.closeCount, 1)
            XCTAssertEqual(pool.made, 2)
            XCTAssertEqual(controller.frameConnectionState, .connected)
            XCTAssertNotEqual(controller.frameSnapshot?.generation, oldFrame)
            XCTAssertNil(controller.frameSnapshot?.lastFrameAt)
        }
    }

    private func triggerMCPFailure(_ controller: ConsoleStateController) async throws {
        do {
            _ = try await watched(Task {
                try await controller.dispatchMCPCommand(Data("{\"jsonrpc\":\"2.0\",\"id\":601,\"method\":\"ping\"}".utf8))
            })
            XCTFail("The inert MCP fixture must deliver the malformed-response failure")
        } catch let error as BridgeError {
            guard case .protocolViolation = error else { throw error }
        }
    }

    private func explicitlyLockGateForRecovery(gate: HardwareInterlockGate, controller: ConsoleStateController) async throws {
        await controller.start() // Observation only; must not reset an abort or reconnect a viewer.
        let history = await gate.transitionHistory
        XCTAssertFalse(history.contains { $0.reason == "EMERGENCY_ABORT_RESET" }, "Frame cleanup must never auto-reset Core")
        switch await gate.currentStatus {
        case .emergencyAbort:
            XCTAssertEqual(controller.currentStatus, .emergencyAbort)
            try await controller.resetAbort() // Explicit operator recovery for the new attach.
        case .armed, .permissiveGranted:
            try await gate.lock() // Explicit fixture/operator action, never viewer policy.
            await controller.start()
        case .locked: break
        }
        let state = await gate.currentStatus
        XCTAssertEqual(state, .locked)
    }

    private func settleFailedMCPForRecovery(_ bridge: ContainerSocketBridge) async throws {
        // Explicit operator/test recovery, not viewer-failure policy. Settle the
        // failed MCP reader/writer independently of the still-held F1 close gate.
        let receipt = try await watched(Task { await bridge.detach() })
        XCTAssertNotEqual(receipt.outcome, .cleanupIncomplete)
        XCTAssertTrue(receipt.handlesClosed)
    }

    private func frameState(
        _ controller: ConsoleStateController, matching predicate: @escaping @Sendable (FrameSnapshot) -> Bool
    ) async throws -> FrameSnapshot {
        let result = FrameCompletion<FrameSnapshot>()
        let observation = controller.$frameSnapshot.compactMap { $0 }.filter(predicate).prefix(1).sink { result.finish(.success($0)) }
        defer { observation.cancel() }
        return try await result.value(deadline: frameRootDeadline())
    }

    private func watched<T: Sendable, Failure: Error>(_ task: Task<T, Failure>) async throws -> T {
        let result = FrameCompletion<Result<T, any Error>>()
        let monitor = Task { result.finish(.success(await task.result.mapError { $0 as any Error })) }
        defer { monitor.cancel() }
        do { return try await result.value(deadline: frameRootDeadline()).get() }
        catch { task.cancel(); throw error }
    }

    private func withFixture(
        clock: RootFrameClock, wires: [RootFrameWire],
        mcpMode: RootMCPFixtureMode = .normal,
        makeController: (@MainActor (HardwareInterlockGate, ContainerSocketBridge, FramebufferClient) -> ConsoleStateController)? = nil,
        _ body: @MainActor (HardwareInterlockGate, ContainerSocketBridge, FramebufferClient, ConsoleStateController, RootFramePool) async throws -> Void
    ) async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw RootFrameFixtureError.pythonUnavailable }
        let gate = HardwareInterlockGate()
        let script = Self.mcpStub.replacingOccurrences(of: "MCP_MODE", with: "'" + mcpMode.rawValue + "'")
        let bridge = ContainerSocketBridge(interlockGate: gate, executableURL: URL(fileURLWithPath: python), arguments: ["-u", "-c", script])
        let pool = RootFramePool(wires, timing: clock.timing)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { pool.make() })
        let controller = makeController?(gate, bridge, client) ?? ConsoleStateController(interlockGate: gate, bridge: bridge, framebufferClient: client)
        defer { pool.releaseBarriers() }
        await controller.start()
        do {
            try await body(gate, bridge, client, controller, pool)
            XCTAssertLessThanOrEqual(pool.made, wires.count, "Unexpected viewer reconnect/factory invocation")
            XCTAssertFalse(pool.replacementBeforePreviousClose, "F2 factory entered before F1 physically closed")
            pool.releaseBarriers()
            try await watched(Task { await controller.stop() })
            try await assertStopped(gate: gate, bridge: bridge, client: client, controller: controller)
        } catch {
            pool.releaseBarriers()
            do { try await watched(Task { await controller.stop() }) }
            catch { XCTFail("Owned Root cleanup failed: \(error)") }
            throw error
        }
    }

    private func assertStopped(
        gate: HardwareInterlockGate, bridge: ContainerSocketBridge, client: FramebufferClient, controller: ConsoleStateController
    ) async throws {
        let source = await client.snapshot()
        XCTAssertNil(source.generation)
        XCTAssertFalse(controller.isObserving)
        XCTAssertEqual(controller.ownedFramebufferConnectionCount, 0)
        let bridgeState = await bridge.snapshot()
        XCTAssertEqual(bridgeState.connectionState, .detached)
        let coreSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(coreSubscribers, 0)
        // All four coarse-state slots are available again; Root unsubscribed its
        // real source, rather than only clearing local bookkeeping.
        var sources: [FrameStateObservation] = []
        do {
            for _ in 0..<4 { sources.append(try await client.observeState()) }
        } catch {
            for source in sources { await client.unsubscribe(id: source.id) }
            throw error
        }
        for source in sources { await client.unsubscribe(id: source.id) }
    }

    private static let mcpStub = #"""
    import sys, json
    mode = MCP_MODE
    for line in sys.stdin.buffer:
        request = json.loads(line)
        if 'id' not in request:
            continue
        method = request.get('method')
        if mode == 'malformedPing' and method == 'ping':
            sys.stdout.write('{invalid_owned_fixture}\n')
            sys.stdout.flush()
            continue
        if method == 'initialize':
            result = {'protocolVersion': request.get('params', {}).get('protocolVersion', '2024-11-05'),
                      'capabilities': {'tools': {}}, 'serverInfo': {'name': 'root-frame-fixture', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'root_frame_fixture', 'inputSchema': {'type': 'object'}}]}
        elif method == 'tools/call':
            result = {'content': [], 'isError': False}
        else:
            result = {}
        sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}, separators=(',', ':')) + '\n')
        sys.stdout.flush()
    """#
}
