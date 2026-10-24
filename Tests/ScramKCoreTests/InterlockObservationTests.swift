import XCTest
@testable import ScramKCore

final class InterlockObservationTests: XCTestCase {
    func testAtomicBootstrapInEveryStateDoesNotTransition() async {
        for status in [InterlockStatus.locked, .armed, .permissiveGranted, .emergencyAbort] {
            let gate = HardwareInterlockGate(initialStatus: status)
            let observation = await gate.observeTransitions()
            XCTAssertEqual(observation.snapshot.currentStatus, status)
            XCTAssertEqual(observation.snapshot.cursor, 0)
            XCTAssertTrue(observation.snapshot.transitions.isEmpty)
            XCTAssertEqual(observation.snapshot.omittedTransitionCount, 0)
            let history = await gate.transitionHistory
            XCTAssertTrue(history.isEmpty)
            await gate.unsubscribeObservation(id: observation.id)
            let subscribers = await gate.activeSubscribersCount
            XCTAssertEqual(subscribers, 0)
        }
    }

    func testBoundarySeparatesBeforeAndAfterTransitionsExactlyOnce() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        let observation = await gate.observeTransitions()
        XCTAssertEqual(observation.snapshot.cursor, 1)
        XCTAssertEqual(observation.snapshot.currentStatus, .armed)
        XCTAssertEqual(observation.snapshot.transitions.map(\.cursor), [1])
        XCTAssertEqual(observation.snapshot.transitions.map(\.record.to), [.armed])

        try await gate.arm() // Idempotent: must not create an observation.
        try await gate.grantPermissive()
        await gate.tripEmergencyAbort(reason: "BOUNDARY_TEST")
        // Finish explicitly so collecting the stream never depends on timing.
        await gate.unsubscribeObservation(id: observation.id)
        var future: [InterlockObservedTransition] = []
        for await transition in observation.transitions { future.append(transition) }
        XCTAssertEqual(future.map(\.cursor), [2, 3])
        XCTAssertEqual(future.map(\.record.to), [.permissiveGranted, .emergencyAbort])
        let history = await gate.transitionHistory
        XCTAssertEqual(observation.snapshot.transitions.map(\.record) + future.map(\.record), history)
    }

    func testCursorResumeReturnsOnlyUnappliedHistory() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()
        try await gate.lock()
        let observation = await gate.observeTransitions(after: 1)
        XCTAssertEqual(observation.snapshot.cursor, 3)
        XCTAssertEqual(observation.snapshot.currentStatus, .locked)
        XCTAssertEqual(observation.snapshot.transitions.map(\.cursor), [2, 3])
        XCTAssertEqual(observation.snapshot.omittedTransitionCount, 0)
        await gate.unsubscribeObservation(id: observation.id)
    }

    func testBoundedBufferGapCanBeReconciledWithoutStateMutation() async throws {
        let gate = HardwareInterlockGate()
        let observation = await gate.observeTransitions(bufferingLimit: 1)
        try await gate.arm()
        try await gate.grantPermissive()
        await gate.tripEmergencyAbort(reason: "OVERFLOW_TEST")
        await gate.unsubscribeObservation(id: observation.id)

        var received: [InterlockObservedTransition] = []
        for await transition in observation.transitions { received.append(transition) }
        XCTAssertEqual(received.map(\.cursor), [3])
        let reconciliation = await gate.observationSnapshot(after: observation.snapshot.cursor)
        XCTAssertEqual(reconciliation.transitions.map(\.cursor), [1, 2, 3])
        XCTAssertEqual(reconciliation.currentStatus, .emergencyAbort)
        XCTAssertEqual(reconciliation.omittedTransitionCount, 0)
        let truncated = await gate.observationSnapshot(after: 0, historyLimit: 1)
        XCTAssertEqual(truncated.transitions.map(\.cursor), [3])
        XCTAssertEqual(truncated.omittedTransitionCount, 2)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.count, 3)
    }

    func testExplicitCleanupIsIdempotentAndDoesNotAffectOtherSubscribers() async throws {
        let gate = HardwareInterlockGate()
        let first = await gate.observeTransitions()
        let second = await gate.observeTransitions()
        let legacy = await gate.subscribeTransitions()
        let initialCount = await gate.activeSubscribersCount
        XCTAssertEqual(initialCount, 3)

        await gate.unsubscribeObservation(id: first.id)
        await gate.unsubscribeObservation(id: first.id)
        let remainingCount = await gate.activeSubscribersCount
        XCTAssertEqual(remainingCount, 2)
        try await gate.arm()
        await gate.unsubscribeObservation(id: second.id)
        var firstEvents: [InterlockObservedTransition] = []
        for await transition in first.transitions { firstEvents.append(transition) }
        var secondEvents: [InterlockObservedTransition] = []
        for await transition in second.transitions { secondEvents.append(transition) }
        var legacyIterator = legacy.makeAsyncIterator()
        let legacyEvent = await legacyIterator.next()
        XCTAssertTrue(firstEvents.isEmpty)
        XCTAssertEqual(secondEvents.map(\.cursor), [1])
        XCTAssertEqual(legacyEvent?.to, .armed)
        // Cancel an iterator suspended at next() to exercise legacy termination.
        let legacyConsumer = Task { for await _ in legacy {} }
        legacyConsumer.cancel()
        await legacyConsumer.value
    }

    func testCancelledObservationCanBeSettledExplicitly() async {
        let gate = HardwareInterlockGate()
        let observation = await gate.observeTransitions()
        let consumer = Task { for await _ in observation.transitions {} }
        consumer.cancel()
        await consumer.value
        // Explicit cleanup also settles a possibly pending onTermination actor hop.
        await gate.unsubscribeObservation(id: observation.id)
        let count = await gate.activeSubscribersCount
        XCTAssertEqual(count, 0)
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
    }

    func testCancellationAutomaticallyDeregistersAfterConsumerReadyHandshake() async throws {
        let gate = HardwareInterlockGate()
        let ready = AsyncStream<UInt64>.makeStream()
        let cleanedUp = AsyncStream<Void>.makeStream()
        let observation = await gate.observeTransitions(
            after: 0, historyLimit: 256, bufferingLimit: 128,
            terminationCleanup: {
                cleanedUp.continuation.yield(())
                cleanedUp.continuation.finish()
            }
        )
        let consumer = Task {
            var iterator = observation.transitions.makeAsyncIterator()
            if let first = await iterator.next() {
                ready.continuation.yield(first.cursor)
            }
            ready.continuation.finish()
            while await iterator.next() != nil {}
        }
        try await gate.arm()
        var readyIterator = ready.stream.makeAsyncIterator()
        let readyCursor = await readyIterator.next()
        XCTAssertEqual(readyCursor, 1, "The consumer must receive an observation before cancellation")
        let registered = await gate.activeSubscribersCount
        XCTAssertEqual(registered, 1)
        consumer.cancel()
        await consumer.value
        var cleanupIterator = cleanedUp.stream.makeAsyncIterator()
        _ = await cleanupIterator.next()
        // No explicit unsubscribe: only onTermination can remove this subscriber.
        let remaining = await gate.activeSubscribersCount
        XCTAssertEqual(remaining, 0)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed])
    }
}
