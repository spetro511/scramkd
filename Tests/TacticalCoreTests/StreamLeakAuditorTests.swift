import Foundation
import TacticalAudioSVS
@testable import TacticalCore
import XCTest

final class StreamLeakAuditorTests: XCTestCase {

    /// Helper to wait for an async condition with a timeout.
    private func waitForCondition(
        timeoutSeconds: Double = 3.0,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    // MARK: - Directive 2.1: AsyncStream consumer cancellation deregisters UUID subscriber

    func testAsyncStreamConsumerCancellationDeregistersSubscriber() async throws {
        let gate = HardwareInterlockGate()
        let initialCount = await gate.activeSubscribersCount
        XCTAssertEqual(initialCount, 0)

        let stream = await gate.subscribeTransitions()
        let subscribedCount = await gate.activeSubscribersCount
        XCTAssertEqual(subscribedCount, 1)

        let consumerTask = Task {
            var received = [InterlockTransitionRecord]()
            for await record in stream {
                received.append(record)
            }
            return received
        }

        // Emit an event to ensure the stream consumer loop is actively running
        try await gate.arm()

        // Wait a beat, then cancel the consumer
        try await Task.sleep(nanoseconds: 10_000_000)
        consumerTask.cancel()
        _ = await consumerTask.result

        // Terminating consumer must trigger onTermination and deregister UUID subscriber
        let deregistered = await waitForCondition {
            await gate.activeSubscribersCount == 0
        }
        let finalCount = await gate.activeSubscribersCount
        XCTAssertTrue(deregistered, "Expected subscriber count to drop to 0 after consumer cancellation")
        XCTAssertEqual(finalCount, 0)
    }

    // MARK: - Directive 2.2: Gate deinit cleanly finishes all open AsyncStream.Continuation channels

    func testGateDeinitFinishesAllOpenStreamsWithoutHangingConsumers() async throws {
        var gate: HardwareInterlockGate? = HardwareInterlockGate()
        let subscriberCount = 10

        var streams: [AsyncStream<InterlockTransitionRecord>] = []
        for _ in 0..<subscriberCount {
            streams.append(await gate!.subscribeTransitions())
        }
        let currentCount = await gate!.activeSubscribersCount
        XCTAssertEqual(currentCount, subscriberCount)

        // Launch consumer tasks for each stream
        let tasks = streams.map { stream in
            Task {
                var count = 0
                for await _ in stream {
                    count += 1
                }
                return count
            }
        }

        // Deliver an initial state transition
        try await gate!.arm()

        // Wait briefly to allow reception
        try await Task.sleep(nanoseconds: 20_000_000)

        // Release gate instance so deinit runs
        gate = nil

        // Verify all consumer tasks finish cleanly without hanging
        let allCompleted = await withThrowingTaskGroup(of: Int.self) { group in
            for task in tasks {
                group.addTask {
                    let result = await task.result
                    switch result {
                    case .success(let count):
                        return count
                    case .failure(let error):
                        throw error
                    }
                }
            }

            var counts = [Int]()
            do {
                for try await c in group {
                    counts.append(c)
                }
                return true
            } catch {
                return false
            }
        }

        XCTAssertTrue(allCompleted, "All stream consumers should finish cleanly upon gate deinit")
    }

    // MARK: - Memory retain cycle: Stream retention does not leak HardwareInterlockGate

    func testGateDeinitializesWhenHoldingOpenStream() async throws {
        weak var weakGate: HardwareInterlockGate?
        var stream: AsyncStream<InterlockTransitionRecord>?

        do {
            let localGate = HardwareInterlockGate()
            weakGate = localGate
            stream = await localGate.subscribeTransitions()
            XCTAssertNotNil(weakGate)
            let count = await localGate.activeSubscribersCount
            XCTAssertEqual(count, 1)
        }

        // Local scope exited; gate should deinitialize even though stream is still held
        let gateDeallocated = await waitForCondition {
            weakGate == nil
        }
        XCTAssertTrue(gateDeallocated, "HardwareInterlockGate should deinit even if caller holds AsyncStream reference")
        _ = stream // silence unused variable warning
    }

    // MARK: - Directive 2.3: SVSBridge start/stop observing lifecycle & proper task cancellation

    func testSVSBridgeStartStopObservingLifecycle() async throws {
        let gate = HardwareInterlockGate()
        let synthesizer = TacticalToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synthesizer)

        let initialObserving = await bridge.isObserving
        XCTAssertFalse(initialObserving)
        let initialCount = await gate.activeSubscribersCount
        XCTAssertEqual(initialCount, 0)

        // Start observing
        await bridge.startObserving(gate: gate)
        let observingAfterStart = await bridge.isObserving
        XCTAssertTrue(observingAfterStart)
        let countAfterStart = await gate.activeSubscribersCount
        XCTAssertEqual(countAfterStart, 1)

        // Trigger transition to verify auditory cue
        try await gate.arm()
        let armedCuePlayed = await waitForCondition {
            await synthesizer.currentActiveCue == .armedPulse
        }
        XCTAssertTrue(armedCuePlayed, "Expected armed pulse cue after arming gate")

        // Stop observing
        await bridge.stopObserving()
        let observingAfterStop = await bridge.isObserving
        XCTAssertFalse(observingAfterStop)

        // Subscriber must be deregistered from gate
        let subscriberRemoved = await waitForCondition {
            await gate.activeSubscribersCount == 0
        }
        XCTAssertTrue(subscriberRemoved, "Stopping observation must deregister subscriber from gate")
    }

    func testSVSBridgeDeinitCancelsObservationAndDeregistersSubscriber() async throws {
        let gate = HardwareInterlockGate()
        var bridge: SVSBridge? = SVSBridge()

        await bridge!.startObserving(gate: gate)
        let countBeforeDeinit = await gate.activeSubscribersCount
        XCTAssertEqual(countBeforeDeinit, 1)

        // Deallocate bridge
        bridge = nil

        // Verify task cancellation triggers onTermination and deregisters subscriber
        let deregistered = await waitForCondition {
            await gate.activeSubscribersCount == 0
        }
        XCTAssertTrue(deregistered, "Deallocating SVSBridge must cancel task and deregister subscriber from gate")
    }

    func testSVSBridgeRestartObservingCleansUpPreviousSubscriber() async throws {
        let gate = HardwareInterlockGate()
        let bridge = SVSBridge()

        // Start observing first time
        await bridge.startObserving(gate: gate)
        let countFirst = await gate.activeSubscribersCount
        XCTAssertEqual(countFirst, 1)

        // Start observing second time (restart observation)
        await bridge.startObserving(gate: gate)

        // The previous subscriber should be cleaned up, leaving exactly 1 subscriber
        let exactlyOneSubscriber = await waitForCondition {
            await gate.activeSubscribersCount == 1
        }
        XCTAssertTrue(exactlyOneSubscriber, "Restarting observation should cancel old stream and retain exactly 1 subscriber")
    }

    // MARK: - Directive 2.4: High-volume concurrent subscribers (50 subscribers) receiving bursts

    func testHighVolumeConcurrentSubscribersBurstAndDisconnect() async throws {
        let gate = HardwareInterlockGate()
        let subscriberCount = 50

        typealias SubscriberTask = Task<[InterlockTransitionRecord], Never>
        var subscriberTasks: [SubscriberTask] = []

        // 1. Subscribe 50 concurrent consumers
        for _ in 0..<subscriberCount {
            let stream = await gate.subscribeTransitions()
            let task = Task {
                var records = [InterlockTransitionRecord]()
                for await record in stream {
                    records.append(record)
                    if record.to == .locked && record.from == .permissiveGranted {
                        // Consumer voluntarily finishes after full cycle
                        break
                    }
                }
                return records
            }
            subscriberTasks.append(task)
        }

        let initialSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(initialSubscribers, subscriberCount)

        // 2. Deliver burst of transitions
        try await gate.arm()
        try await gate.grantPermissive()
        try await gate.lock()

        // 3. Wait for all 50 consumers to finish their loops and collect records
        for task in subscriberTasks {
            let records = await task.value
            XCTAssertEqual(records.count, 3, "Each subscriber must receive all 3 burst transitions")
            XCTAssertEqual(records.map(\.to), [.armed, .permissiveGranted, .locked])
        }

        // 4. Verify all 50 consumers are completely deregistered from gate
        let allDeregistered = await waitForCondition(timeoutSeconds: 5.0) {
            await gate.activeSubscribersCount == 0
        }
        let remaining = await gate.activeSubscribersCount
        XCTAssertTrue(
            allDeregistered,
            "All 50 subscribers should be deregistered after breaking from stream. Active remaining: \(remaining)"
        )
    }

    func testHighVolumeConcurrentSubscribersCancellationBurst() async throws {
        let gate = HardwareInterlockGate()
        let subscriberCount = 50

        var tasks: [Task<Void, Never>] = []

        for _ in 0..<subscriberCount {
            let stream = await gate.subscribeTransitions()
            let task = Task {
                for await _ in stream {
                    // Just consume
                }
            }
            tasks.append(task)
        }

        let initialSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(initialSubscribers, subscriberCount)

        // Burst transitions
        try await gate.arm()
        try await gate.grantPermissive()

        // Concurrently cancel all 50 tasks
        for task in tasks {
            task.cancel()
        }

        // Wait for cancellation to complete
        for task in tasks {
            _ = await task.result
        }

        let allCleanedUp = await waitForCondition(timeoutSeconds: 5.0) {
            await gate.activeSubscribersCount == 0
        }
        let remaining = await gate.activeSubscribersCount
        XCTAssertTrue(
            allCleanedUp,
            "All 50 cancelled subscribers should be deregistered. Active remaining: \(remaining)"
        )
    }
}
