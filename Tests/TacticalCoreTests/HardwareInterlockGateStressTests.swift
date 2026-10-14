import os
import XCTest
@testable import TacticalCore

/// High-throughput stress test and race-condition fuzzer suite for HardwareInterlockGate.
/// Verifies Swift 6 actor isolation, OSAllocatedUnfairLock re-entrancy/atomicity,
/// exactly-once continuation resumption, and leak/deadlock resistance under heavy contention.
final class HardwareInterlockGateStressTests: XCTestCase {

    // MARK: - 1. ContinuationWaiter Atomic Resumption & Double-Resume Protection

    /// Stress-tests ContinuationWaiter directly to guarantee OSAllocatedUnfairLock
    /// guarantees exactly-once resumption and zero double-resume runtime panics
    /// when bombarded by multiple threads simultaneously.
    func testContinuationWaiterNeverDoubleResumesUnderMassiveContention() async {
        let iterations = 200
        let threadsPerContinuation = 40

        for iteration in 0..<iterations {
            let successCount = OSAllocatedUnfairLock(initialState: 0)
            let failCount = OSAllocatedUnfairLock(initialState: 0)

            await withTaskGroup(of: Void.self) { group in
                let waiterHolder = OSAllocatedUnfairLock<ContinuationWaiter?>(initialState: nil)

                // Launch continuation in dedicated task
                group.addTask {
                    do {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            let waiter = ContinuationWaiter(continuation: continuation)
                            waiterHolder.withLock { $0 = waiter }
                        }
                    } catch {
                        // Expected if throwing resume won the race
                    }
                }

                // Wait until waiter is created
                while waiterHolder.withLock({ $0 == nil }) {
                    await Task.yield()
                }
                guard let waiter = waiterHolder.withLock({ $0 }) else { return }

                // Bombard waiter from parallel tasks racing resume(returning:) vs resume(throwing:)
                for index in 0..<threadsPerContinuation {
                    group.addTask {
                        let didResume: Bool
                        if index % 2 == 0 {
                            didResume = waiter.resume(returning: ())
                        } else {
                            didResume = waiter.resume(throwing: HardwareInterlockError.emergencyAbortActive)
                        }

                        if didResume {
                            successCount.withLock { $0 += 1 }
                        } else {
                            failCount.withLock { $0 += 1 }
                        }
                    }
                }

                await group.waitForAll()
            }

            let won = successCount.withLock { $0 }
            let lost = failCount.withLock { $0 }

            XCTAssertEqual(
                won, 1,
                "Iteration \(iteration): Exactly one task must win resumption race"
            )
            XCTAssertEqual(
                lost, threadsPerContinuation - 1,
                "Iteration \(iteration): All other contending tasks must safely receive false"
            )
        }
    }

    // MARK: - 2. High-Throughput Parallel Task Racing

    /// Spawns 160+ parallel Tasks in withThrowingTaskGroup performing concurrent
    /// racing across requestPermissive(), arm(), grantPermissive(), tripEmergencyAbort(),
    /// lock(), resetEmergencyAbort(), and Task.cancel().
    func testHighThroughputParallelTaskRacing() async throws {
        let totalWorkers = 160
        let rounds = 6

        for round in 0..<rounds {
            let gate = HardwareInterlockGate(initialStatus: .locked)
            let completedOperations = OSAllocatedUnfairLock(initialState: 0)
            let cancellationCount = OSAllocatedUnfairLock(initialState: 0)
            let permissiveCount = OSAllocatedUnfairLock(initialState: 0)
            let errorCount = OSAllocatedUnfairLock(initialState: 0)

            try await withThrowingTaskGroup(of: Void.self) { group in
                // 1. Waiters racing requestPermissive (80 tasks)
                for taskIndex in 0..<80 {
                    group.addTask {
                        do {
                            if taskIndex % 2 == 0 {
                                try await gate.requestPermissive(timeout: .milliseconds(Int.random(in: 10...50)))
                            } else {
                                try await gate.requestPermissive()
                            }
                            permissiveCount.withLock { $0 += 1 }
                        } catch let error as HardwareInterlockError {
                            if error == .taskCancelled {
                                cancellationCount.withLock { $0 += 1 }
                            } else {
                                errorCount.withLock { $0 += 1 }
                            }
                        } catch {
                            errorCount.withLock { $0 += 1 }
                        }
                        completedOperations.withLock { $0 += 1 }
                    }
                }

                // 2. Self-canceling tasks racing cancellation against gate status (40 tasks)
                for _ in 0..<40 {
                    group.addTask {
                        let childTask = Task {
                            try await gate.requestPermissive()
                        }
                        if Bool.random() {
                            try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000...50_000))
                        }
                        childTask.cancel()

                        do {
                            try await childTask.value
                            permissiveCount.withLock { $0 += 1 }
                        } catch let error as HardwareInterlockError {
                            if error == .taskCancelled {
                                cancellationCount.withLock { $0 += 1 }
                            } else {
                                errorCount.withLock { $0 += 1 }
                            }
                        } catch {
                            errorCount.withLock { $0 += 1 }
                        }
                        completedOperations.withLock { $0 += 1 }
                    }
                }

                // 3. State-transition drivers racing arm, grant, abort, reset, lock (40 tasks)
                for driverIndex in 0..<40 {
                    group.addTask {
                        for _ in 0..<6 {
                            switch driverIndex % 5 {
                            case 0:
                                try? await gate.arm()
                            case 1:
                                try? await gate.grantPermissive()
                            case 2:
                                await gate.tripEmergencyAbort(reason: "CHAOS_ROUND_\(round)")
                            case 3:
                                try? await gate.resetEmergencyAbort()
                            case 4:
                                try? await gate.lock()
                            default:
                                break
                            }
                            await Task.yield()
                        }
                        completedOperations.withLock { $0 += 1 }
                    }
                }

                try await group.waitForAll()
            }

            // Ensure all workers finished without deadlock
            let ops = completedOperations.withLock { $0 }
            XCTAssertEqual(ops, totalWorkers, "Round \(round): All parallel tasks must complete")

            // Release any dangling waiters by tripping or locking
            let finalStatus = await gate.currentStatus
            if finalStatus == .armed {
                try await gate.grantPermissive()
            } else if finalStatus == .emergencyAbort {
                try await gate.resetEmergencyAbort()
                try await gate.lock()
            } else {
                try? await gate.lock()
            }

            // Give actor a moment to finish async cancellation removes
            for _ in 0..<10 {
                if await gate.pendingWaitersCount == 0 { break }
                try await Task.sleep(nanoseconds: 500_000)
            }

            let remainingWaiters = await gate.pendingWaitersCount
            XCTAssertEqual(remainingWaiters, 0, "Round \(round): Pending waiters must be fully drained")

            // Verify transition history monotonicity
            let history = await gate.transitionHistory
            if history.count > 1 {
                for i in 1..<history.count {
                    XCTAssertGreaterThanOrEqual(
                        history[i].timestampNanoseconds,
                        history[i - 1].timestampNanoseconds,
                        "Audit records must be monotonically non-decreasing"
                    )
                }
            }
        }
    }

    // MARK: - 3. Thread Contention Fuzzer: Rapid Transition & Cancellation Cycles

    /// Repeated cycles of concurrent waiters cancelled while gate states transition rapidly.
    /// Confirms that neither race condition causes unhandled traps, leaked continuations,
    /// or stale waiters dictionary entries.
    func testThreadContentionFuzzerRapidCycles() async throws {
        let cycleCount = 50
        let waitersPerCycle = 120

        for cycle in 0..<cycleCount {
            let gate = HardwareInterlockGate(initialStatus: .locked)
            try await gate.arm()

            let completedWaiters = OSAllocatedUnfairLock(initialState: 0)

            await withTaskGroup(of: Void.self) { group in
                // Spawn concurrent waiters
                for waiterIndex in 0..<waitersPerCycle {
                    group.addTask {
                        let requestTask = Task {
                            try await gate.requestPermissive()
                        }

                        // Jittered cancellation targeting 50% of tasks
                        if waiterIndex % 2 == 0 {
                            if waiterIndex % 4 == 0 {
                                requestTask.cancel()
                            } else {
                                Task {
                                    try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000...200_000))
                                    requestTask.cancel()
                                }
                            }
                        }

                        do {
                            try await requestTask.value
                        } catch {
                            XCTAssertTrue(error is HardwareInterlockError)
                        }
                        completedWaiters.withLock { $0 += 1 }
                    }
                }

                // Concurrently fire rapid state mutations on the gate
                group.addTask {
                    try? await Task.sleep(nanoseconds: 50_000)
                    if cycle % 3 == 0 {
                        try? await gate.grantPermissive()
                    } else if cycle % 3 == 1 {
                        await gate.tripEmergencyAbort(reason: "FUZZER_CYCLE_\(cycle)")
                    } else {
                        try? await gate.lock()
                    }
                }

                await group.waitForAll()
            }

            let doneCount = completedWaiters.withLock { $0 }
            XCTAssertEqual(doneCount, waitersPerCycle, "Cycle \(cycle): All waiters must terminate")

            // Give any async cancellation cleanup tasks a brief moment to complete
            for _ in 0..<10 {
                if await gate.pendingWaitersCount == 0 { break }
                try await Task.sleep(nanoseconds: 500_000)
            }

            let remainingWaiters = await gate.pendingWaitersCount
            XCTAssertEqual(remainingWaiters, 0, "Cycle \(cycle): No continuation waiter may leak in dictionary")
        }
    }

    // MARK: - 4. Cancellation Leak & Deadlock Verification

    /// Specifically validates that rapid cancellation of pending waiters when gate is
    /// left in `.armed` without state transition never leaves orphan continuations
    /// or causes indefinite suspension.
    func testMassiveWaiterCancellationLeakAndDeadlock() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        try await gate.arm()

        let taskCount = 200
        let cancelledCount = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    let task = Task {
                        try await gate.requestPermissive()
                    }

                    // Cancel concurrently at variable intervals
                    let delay = UInt64.random(in: 0...100_000)
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    task.cancel()

                    do {
                        try await task.value
                        XCTFail("Must not succeed when gate remained armed without grant")
                    } catch let error as HardwareInterlockError {
                        if error == .taskCancelled {
                            cancelledCount.withLock { $0 += 1 }
                        }
                    } catch {
                        XCTFail("Unexpected non-interlock error: \(error)")
                    }
                }
            }

            await group.waitForAll()
        }

        let cancelled = cancelledCount.withLock { $0 }
        XCTAssertEqual(cancelled, taskCount, "All tasks must report .taskCancelled")

        // Wait for cleanup tasks on actor to complete
        for _ in 0..<20 {
            if await gate.pendingWaitersCount == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let remaining = await gate.pendingWaitersCount
        XCTAssertEqual(remaining, 0, "Gate must not leak any pending waiters after full cancellation")
    }

    // MARK: - 5. Thundering Herd: High-Concurrency Waiter Granting

    /// Suspends 300 parallel callers on armed gate, then triggers grantPermissive().
    /// All 300 must resume simultaneously without dropped continuations or actor stalls.
    func testThunderingHerdMassiveWaiterGrant() async throws {
        let waiterCount = 300
        let gate = HardwareInterlockGate(initialStatus: .locked)
        try await gate.arm()

        let successCount = OSAllocatedUnfairLock(initialState: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<waiterCount {
                group.addTask {
                    try await gate.requestPermissive()
                    successCount.withLock { $0 += 1 }
                }
            }

            // Spin until all callers are suspended
            while await gate.pendingWaitersCount < waiterCount {
                try await Task.sleep(nanoseconds: 500_000)
            }

            // Grant permissive to all callers in a single atomic drain
            try await gate.grantPermissive()

            try await group.waitForAll()
        }

        let totalSuccess = successCount.withLock { $0 }
        let remaining = await gate.pendingWaitersCount
        let status = await gate.currentStatus

        XCTAssertEqual(totalSuccess, waiterCount, "All waiters must receive permissive grant")
        XCTAssertEqual(remaining, 0, "No pending waiters remaining")
        XCTAssertEqual(status, .permissiveGranted)
    }

    // MARK: - 6. Concurrent Stream Subscriber Contention

    /// Stress tests transition stream subscribers when multiple consumers listen
    /// and disconnect concurrently while rapid transitions occur.
    func testConcurrentStreamSubscriberContention() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let subscriberCount = 40
        let receivedEvents = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            // Launch concurrent subscribers
            for subIndex in 0..<subscriberCount {
                group.addTask {
                    let stream = await gate.subscribeTransitions()
                    var count = 0
                    for await _ in stream {
                        count += 1
                        receivedEvents.withLock { $0 += 1 }
                        if subIndex % 2 == 0 && count >= 3 {
                            break
                        }
                    }
                }
            }

            // Rapidly drive transitions
            group.addTask {
                for _ in 0..<12 {
                    try? await gate.arm()
                    try? await gate.grantPermissive()
                    try? await gate.lock()
                    await Task.yield()
                }
                await gate.tripEmergencyAbort(reason: "STREAM_STRESS_END")
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
            group.cancelAll()
            await group.waitForAll()
        }

        let totalEvents = receivedEvents.withLock { $0 }
        XCTAssertGreaterThan(totalEvents, 0, "Subscribers must receive transition records")
    }

    // MARK: - 7. Actor Invariant State Machine Chaos Fuzzer

    /// Fuzzes rapid sequences of transitions and requests while verifying that
    /// the actor invariant rules always hold:
    /// - Status locked => 0 pending waiters
    /// - Status permissiveGranted => 0 pending waiters
    /// - Status emergencyAbort => 0 pending waiters
    /// - Transition history sequence continuity (to == next.from)
    func testActorInvariantStateMachineChaosFuzzer() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let workerCount = 16
        let operationsPerWorker = 50

        await withTaskGroup(of: Void.self) { group in
            for workerId in 0..<workerCount {
                group.addTask {
                    for op in 0..<operationsPerWorker {
                        let action = (workerId + op) % 6
                        switch action {
                        case 0:
                            try? await gate.arm()
                        case 1:
                            try? await gate.grantPermissive()
                        case 2:
                            try? await gate.lock()
                        case 3:
                            await gate.tripEmergencyAbort(reason: "FUZZER_W\(workerId)_OP\(op)")
                        case 4:
                            try? await gate.resetEmergencyAbort()
                        case 5:
                            _ = try? await gate.requestPermissive(timeout: .milliseconds(5))
                        default:
                            break
                        }
                        await Task.yield()
                    }
                }
            }

            await group.waitForAll()
        }

        // Clean finish
        let finalStatus = await gate.currentStatus
        if finalStatus == .armed {
            try await gate.grantPermissive()
        } else if finalStatus == .emergencyAbort {
            try await gate.resetEmergencyAbort()
            try await gate.lock()
        } else {
            try? await gate.lock()
        }

        // Wait for cancellation tasks to settle
        for _ in 0..<10 {
            if await gate.pendingWaitersCount == 0 { break }
            try await Task.sleep(nanoseconds: 500_000)
        }

        let finalWaiters = await gate.pendingWaitersCount
        XCTAssertEqual(finalWaiters, 0, "Invariant violation: non-armed status must have 0 waiters")

        // Validate audit history consistency
        let history = await gate.transitionHistory
        XCTAssertGreaterThan(history.count, 0)
        for i in 1..<history.count {
            XCTAssertEqual(
                history[i].from,
                history[i - 1].to,
                "Invariant violation: transition history must be contiguous (history[\(i)].from == history[\(i-1)].to)"
            )
            XCTAssertGreaterThanOrEqual(
                history[i].timestampNanoseconds,
                history[i - 1].timestampNanoseconds,
                "Invariant violation: timestamps must be monotonically increasing"
            )
        }
    }

    // MARK: - 8. 100-Task Concurrent Contention Race (Permissive / Arm / Grant / EmergencyAbort)

    /// Spawns 100 concurrent asynchronous tasks in a `withTaskGroup` that race
    /// `requestPermissive()`, `arm()`, `grantPermissive()`, and `tripEmergencyAbort()`
    /// to verify that `OSAllocatedUnfairLock` handles contention without double-resume panics or leaks.
    func testOneHundredConcurrentTasksRacingPermissiveArmGrantAndAbort() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let completedTasks = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<100 {
                group.addTask {
                    switch taskId % 4 {
                    case 0:
                        _ = try? await gate.requestPermissive(timeout: .milliseconds(25))
                    case 1:
                        try? await gate.arm()
                    case 2:
                        try? await gate.grantPermissive()
                    default:
                        await gate.tripEmergencyAbort(reason: "ADVERSARIAL_RACE_\(taskId)")
                    }
                    completedTasks.withLock { $0 += 1 }
                }
            }
            await group.waitForAll()
        }

        XCTAssertEqual(completedTasks.withLock { $0 }, 100, "All 100 racing tasks must complete without deadlock or double-resume traps")

        // Drain any remaining armed waiters deterministically
        let status = await gate.currentStatus
        if status == .armed {
            try await gate.grantPermissive()
        }
        for _ in 0..<10 {
            if await gate.pendingWaitersCount == 0 { break }
            try await Task.sleep(nanoseconds: 500_000)
        }
        let leakedWaiters = await gate.pendingWaitersCount
        XCTAssertEqual(leakedWaiters, 0, "Zero continuation waiters may leak after 100-task contention race")
    }
}
