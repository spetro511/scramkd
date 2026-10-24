import Foundation
import os
import XCTest
@testable import ScramKVirtualization

final class FramebufferClientTests: XCTestCase {
    func testOfflineInitializationAndBoundedObservations() async throws {
        let made = OSAllocatedUnfairLock(initialState: 0)
        let client = FramebufferClient(timing: FrameTiming(), makeTransport: {
            made.withLock { $0 += 1 }; return FrameScriptedTransport()
        })
        try await FrameTestSession(client: client).run { session in
            let snapshot = await client.snapshot()
            XCTAssertEqual(snapshot.state, .detached)
            XCTAssertNil(snapshot.generation)
            XCTAssertEqual(made.withLock { $0 }, 0)
            let frames = try await session.observeFrames()
            XCTAssertNil(frames.current.frame)
            do { _ = try await session.observeFrames(); XCTFail("Unbounded frame subscriber") }
            catch { XCTAssertEqual(error as? FrameError, .limitExceeded(.observers)) }
            var states: [FrameTestStateObservation] = []
            for _ in 0..<4 { states.append(try await session.observeState()) }
            do { _ = try await session.observeState(); XCTFail("Unbounded status subscribers") }
            catch { XCTAssertEqual(error as? FrameError, .limitExceeded(.observers)) }
            await session.unsubscribe(id: frames.id)
            let replacement = try await session.observeFrames()
            await session.unsubscribe(id: replacement.id)
            for observation in states { await session.unsubscribe(id: observation.id) }
            _ = try await session.observeState()
        }
    }

    func testConnectFramesTruthfulStatsAndAllowedOutboundOnly() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { session in
            let observation = try await session.observeFrames()
            let deliveries = observation.updates
            let generation = try await client.connect()
            let connected = await client.snapshot()
            XCTAssertEqual(connected.state, .connected)
            XCTAssertEqual(connected.width, 2)
            XCTAssertNil(connected.lastFrameAt) // Successful handshake is not a frame.
            let clear = try await deliveries.next()
            XCTAssertNil(clear.frame)
            try await wire.waitForRequests(1)
            wire.push(FrameFixtures.update())
            let delivery = try await deliveries.next()
            let frame = try XCTUnwrap(delivery.frame)
            XCTAssertEqual(frame.generation, generation)
            XCTAssertEqual(frame.sequence, 1)
            XCTAssertEqual(frame.pixels, Data([3, 2, 1, 255, 6, 5, 4, 255]))
            let snapshot = await client.snapshot()
            XCTAssertEqual(snapshot.statistics.publishedFrames, 1)
            XCTAssertEqual(snapshot.statistics.completedUpdates, 1)
            XCTAssertEqual(snapshot.statistics.receivedBinaryMessages, 5)
            XCTAssertEqual(snapshot.statistics.receivedBinaryPayloadBytes,
                           UInt64(12 + 2 + 4 + FrameFixtures.serverInit().count + FrameFixtures.update().count))
            XCTAssertEqual(wire.sent, [FrameFixtures.version, Data([1]), Data([1]),
                                      RFBStreamDecoder.pixelFormatAndEncodings,
                                      Data([3, 0, 0, 0, 0, 0, 0, 2, 0, 1])])
            try await client.disconnect(generation: generation)
            let retired = await client.snapshot()
            XCTAssertEqual(retired.state, .detached)
            XCTAssertNil(retired.generation)
            XCTAssertNil(retired.lastFrameAt)
            let clearAfter = try await deliveries.next()
            XCTAssertNil(clearAfter.frame)
            XCTAssertGreaterThan(clearAfter.revision, delivery.revision)
        }
    }

    func testLatestOneReplacesActualFramesAndRateRequiresMonotonicAdvance() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { session in
            let observation = try await session.observeFrames()
            let deliveries = observation.updates
            _ = try await client.connect()
            _ = try await deliveries.next() // Initial clear, not an eager collector.
            try await wire.waitForRequests(1)
            wire.push(FrameFixtures.update())
            // Advance only protocol scheduling, never a failure watchdog.
            clock.advance(.milliseconds(100))
            try await wire.waitForRequests(2)
            XCTAssertEqual(wire.requestCount, 2)
            wire.push(FrameFixtures.update())
            clock.advance(.milliseconds(100))
            try await wire.waitForRequests(3) // Second publication completed.
            let newest = try await deliveries.next()
            XCTAssertEqual(newest.frame?.sequence, 2)
            let snapshot = await client.snapshot()
            XCTAssertEqual(snapshot.statistics.replacedFrameDeliveries, 1)
            XCTAssertEqual(wire.requestCount, 3) // No fourth request without time.
            try await client.disconnect()
        }
    }

    func testDetachFencesAndClearsBeforeQuiescentCleanupCompletes() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing, holdClose: true)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        // Session entry installs synchronous gate-release defer before this body.
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { session in
            let observation = try await session.observeFrames()
            let deliveries = observation.updates
            let generation = try await client.connect()
            _ = try await deliveries.next()
            try await wire.waitForRequests(1)
            wire.push(FrameFixtures.update())
            _ = try await deliveries.next()
            let detach = try session.spawn(label: "held detach") { try await client.disconnect(generation: generation) }
            try await session.wait(wire.closeStarted, label: "held close entered")
            let during = await client.snapshot()
            XCTAssertEqual(during.state, .disconnecting)
            XCTAssertNil(during.lastFrameAt)
            let clear = try await deliveries.next()
            XCTAssertNil(clear.frame)
            do { _ = try await client.connect(); XCTFail("Reused retiring resources") }
            catch { XCTAssertEqual(error as? FrameError, .busy) }
            wire.closeGate.finish(.success(()))
            try await detach.value()
            let detached = await client.snapshot()
            XCTAssertEqual(detached.state, .detached)
        }
    }

    func testNewGenerationRejectsStaleDisconnectAndOldDelivery() async throws {
        let clock = FrameTestClock()
        let first = FrameScriptedTransport(timing: clock.timing)
        let second = FrameScriptedTransport(timing: clock.timing)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let client = FramebufferClient(timing: clock.timing, makeTransport: {
            let index = count.withLock { value in value += 1; return value }
            return index == 1 ? first : second
        })
        try await FrameTestSession(client: client, wires: [first, second], clock: clock).run { session in
            let observation = try await session.observeFrames()
            let deliveries = observation.updates
            let old = try await client.connect()
            _ = try await deliveries.next()
            try await client.disconnect(generation: old)
            let oldClear = try await deliveries.next()
            let new = try await client.connect()
            let newClear = try await deliveries.next()
            XCTAssertNotEqual(old, new)
            XCTAssertGreaterThan(newClear.revision, oldClear.revision)
            do { try await client.disconnect(generation: old); XCTFail("Stale disconnect retired replacement") }
            catch { XCTAssertEqual(error as? FrameError, .staleGeneration) }
            first.push(FrameFixtures.update()) // Retired feed cannot publish into replacement.
            let replacement = await client.snapshot()
            XCTAssertEqual(replacement.generation, new)
            try await second.waitForRequests(1)
            second.push(FrameFixtures.update())
            let newest = try await deliveries.next()
            XCTAssertEqual(newest.frame?.generation, new)
            XCTAssertEqual(newest.frame?.sequence, 1)
            try await client.disconnect()
        }
    }

    func testConnectCancellationSettlesWithoutAutomaticReconnect() async throws {
        let gate = FrameCompletion<Void>()
        let wire = FrameScriptedTransport(openGate: gate)
        let client = FramebufferClient(timing: FrameTiming(), makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire]).run { session in
            let connect = try session.spawn(label: "held connect") { try await client.connect() }
            try await session.wait(wire.opened, label: "connect entered")
            let connecting = await client.snapshot()
            XCTAssertEqual(connecting.state, .connecting)
            connect.cancel()
            do { _ = try await connect.value(); XCTFail("Cancelled connect succeeded") }
            catch { XCTAssertEqual(error as? FrameError, .cancelled) }
            try await client.disconnect()
            let snapshot = await client.snapshot()
            XCTAssertEqual(snapshot.state, .detached)
            XCTAssertTrue(wire.sent.isEmpty)
        }
    }

    func testNegotiationCancellationAndConcurrentConnectRejection() async throws {
        let wire = FrameScriptedTransport(holdSecurity: true)
        let client = FramebufferClient(timing: FrameTiming(), makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire]).run { session in
            let connect = try session.spawn(label: "held negotiation") { try await client.connect() }
            try await session.wait(wire.firstSend, label: "negotiation first send")
            let negotiating = await client.snapshot()
            XCTAssertEqual(negotiating.state, .negotiating)
            do { _ = try await client.connect(); XCTFail("Concurrent connect admitted") }
            catch { XCTAssertEqual(error as? FrameError, .busy) }
            connect.cancel()
            do { _ = try await connect.value(); XCTFail("Cancelled negotiation succeeded") }
            catch { XCTAssertEqual(error as? FrameError, .cancelled) }
            try await client.disconnect()
            XCTAssertEqual(wire.sent, [FrameFixtures.version])
        }
    }

    func testReadDeadlineRetiresLocallyWithoutClaimingPeerDisconnect() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { session in
            let observation = try await session.observeFrames()
            let frames = observation.updates
            let statuses = try await session.observeState()
            _ = try await client.connect(); _ = try await frames.next()
            try await wire.waitForRequests(1)
            clock.advance(.seconds(11))
            let clear = try await frames.next()
            XCTAssertNil(clear.frame)
            let failure = try await statuses.updates.first { $0.failure == .timedOut(.update) }
            XCTAssertEqual(failure.failure, .timedOut(.update))
            try await client.disconnect()
            let failed = await client.snapshot()
            XCTAssertEqual(failed.statistics.noChangeUpdates, 0)
            XCTAssertEqual(failed.statistics.publishedFrames, 0)
        }
    }

    func testEOFIsFailureAndCannotPublishPartialImage() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { session in
            let observation = try await session.observeFrames()
            let frames = observation.updates
            _ = try await client.connect(); _ = try await frames.next()
            try await wire.waitForRequests(1)
            wire.push(Data(FrameFixtures.update().prefix(17)))
            wire.end()
            let clear = try await frames.next()
            XCTAssertNil(clear.frame)
            try await client.disconnect()
            let failed = await client.snapshot()
            XCTAssertEqual(failed.state, .failed)
            XCTAssertEqual(failed.failure, .protocolViolation(.truncated))
            XCTAssertEqual(failed.statistics.publishedFrames, 0)
        }
    }

    func testProtocolFailureClearsAndCleanupTimeoutStaysBusyUntilRetry() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing, holdClose: true)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { session in
            let statuses = try await session.observeState()
            let observation = try await session.observeFrames()
            let deliveries = observation.updates
            _ = try await client.connect(); _ = try await deliveries.next()
            try await wire.waitForRequests(1)
            wire.push(Data([1])) // Unsupported SetColorMapEntries.
            let clear = try await deliveries.next()
            XCTAssertNil(clear.frame)
            try await session.wait(wire.closeStarted, label: "failing close entered")
            clock.advance(.seconds(3))
            let timeout = try await statuses.updates.first { $0.failure == .timedOut(.cleanup) }
            XCTAssertEqual(timeout.failure, .timedOut(.cleanup))
            do { _ = try await client.connect(); XCTFail("Failed cleanup lost ownership") }
            catch { XCTAssertEqual(error as? FrameError, .busy) }
            wire.closeGate.finish(.success(()))
            try await client.disconnect() // Fresh budget, same retired generation.
            let failed = await client.snapshot()
            XCTAssertEqual(failed.state, .failed)
        }
    }

    func testEmptyResponseIsMeasuredNoChangeNotAFrameOrDisconnect() async throws {
        let clock = FrameTestClock()
        let wire = FrameScriptedTransport(timing: clock.timing)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        try await FrameTestSession(client: client, wires: [wire], clock: clock).run { _ in
            _ = try await client.connect()
            try await wire.waitForRequests(1)
            wire.push(Data([0, 0, 0, 0]))
            clock.advance(.milliseconds(100))
            try await wire.waitForRequests(2)
            let snapshot = await client.snapshot()
            XCTAssertEqual(snapshot.state, .connected)
            XCTAssertEqual(snapshot.statistics.noChangeUpdates, 1)
            XCTAssertEqual(snapshot.statistics.publishedFrames, 0)
            XCTAssertNil(snapshot.lastFrameAt)
            try await client.disconnect()
        }
    }

    func testWorkerFailureBeforeRequestMilestonePreservesOriginalAndSettles() async throws {
        let clock = FrameTestClock(), original = FrameError.securityRejected
        let start = clock.now
        let wire = FrameScriptedTransport(timing: clock.timing, holdClose: true, openFailure: original)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        let session = FrameTestSession(client: client, wires: [wire], clock: clock)
        do {
            try await session.run { owned in
                let request = try owned.spawn(label: "request N before worker failure") { try await wire.waitForRequests(1) }
                try await owned.wait(wire.requestWaitRegistered, label: "request waiter registered")
                do { _ = try await client.connect(); XCTFail("Injected worker failure succeeded") }
                catch { XCTAssertEqual(error as? FrameError, original) }
                try await request.value() // Propagates original, not watchdog/cancel.
                XCTFail("Impossible request milestone succeeded")
            }
            XCTFail("Body lost original worker failure")
        } catch { XCTAssertEqual(error as? FrameError, original) }
        // Also reject a newly requested impossible count, without logical time.
        do { try await wire.waitForRequests(2); XCTFail("Retired fixture admitted new wait") }
        catch { XCTAssertEqual(error as? FrameError, original) }
        XCTAssertEqual(clock.now, start)
        XCTAssertEqual(wire.requestCount, 0)
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(wire.gatesReleased)
        XCTAssertEqual(wire.pendingRequestWaiterCount, 0)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
        XCTAssertEqual(session.ownedTaskCount, 0)
        XCTAssertEqual(session.observationCount, 0)
        XCTAssertTrue(session.clientDisconnected)
    }

    func testBodyFailureWhileCloseHeldReleasesGateAndSettlesWithoutClockAdvance() async throws {
        let clock = FrameTestClock()
        let start = clock.now
        let wire = FrameScriptedTransport(timing: clock.timing, holdClose: true)
        let client = FramebufferClient(timing: clock.timing, makeTransport: { wire })
        let session = FrameTestSession(client: client, wires: [wire], clock: clock)
        do {
            try await session.run { (owned: FrameTestSession) async throws -> Void in
                _ = try await owned.observeFrames()
                _ = try await owned.observeState()
                _ = try await client.connect()
                _ = try owned.spawn(label: "detach held during body failure") { try await client.disconnect() }
                try await owned.wait(wire.closeStarted, label: "close held before body failure")
                XCTAssertFalse(wire.gatesReleased)
                throw FrameTestInjectedFailure.body
            }
            XCTFail("Body failure was lost")
        } catch { XCTAssertEqual(error as? FrameTestInjectedFailure, .body) }
        XCTAssertEqual(clock.now, start)
        XCTAssertTrue(wire.gatesReleased)
        XCTAssertEqual(wire.pendingRequestWaiterCount, 0)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
        XCTAssertEqual(session.ownedTaskCount, 0)
        XCTAssertEqual(session.observationCount, 0)
        XCTAssertTrue(session.clientDisconnected)
    }

    func testCleanupSecondaryErrorIsReportedWithoutMaskingBodyFailure() async throws {
        let diagnostics = FrameTestDiagnostics()
        let session = FrameTestSession(cleanup: { throw FrameTestInjectedFailure.cleanup },
                                       reportSecondary: { diagnostics.record($0) })
        do {
            try await session.run { (_: FrameTestSession) async throws -> Void in throw FrameTestInjectedFailure.body }
            XCTFail("Body failure was lost")
        } catch { XCTAssertEqual(error as? FrameTestInjectedFailure, .body) }
        XCTAssertEqual(diagnostics.failures.count, 1)
        XCTAssertEqual(diagnostics.failures.first as? FrameTestInjectedFailure, .cleanup)
        XCTAssertEqual(session.ownedTaskCount, 0)
    }
}
