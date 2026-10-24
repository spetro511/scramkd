import os
import XCTest
@testable import ScramKCore

final class HardwareInterlockGateTests: XCTestCase {
    func testInitialStateIsLocked() async {
        let gate = HardwareInterlockGate()
        let initialStatus = await gate.currentStatus
        XCTAssertEqual(initialStatus, .locked)
    }

    func testValidStateProgression() async throws {
        let gate = HardwareInterlockGate()

        try await gate.arm()
        let armedStatus = await gate.currentStatus
        XCTAssertEqual(armedStatus, .armed)

        try await gate.grantPermissive()
        let permissiveStatus = await gate.currentStatus
        XCTAssertEqual(permissiveStatus, .permissiveGranted)

        try await gate.lock()
        let lockedStatus = await gate.currentStatus
        XCTAssertEqual(lockedStatus, .locked)
    }

    func testInvalidTransitionRejections() async throws {
        let gate = HardwareInterlockGate()

        // locked -> permissiveGranted must throw
        do {
            try await gate.grantPermissive()
            XCTFail("Direct jump locked -> permissiveGranted must throw")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .locked, to: .permissiveGranted))
        }

        try await gate.arm()
        try await gate.grantPermissive()

        // permissiveGranted -> armed must throw
        do {
            try await gate.arm()
            XCTFail("Direct jump permissiveGranted -> armed must throw")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .permissiveGranted, to: .armed))
        }
    }

    func testStrictRecoveryLadderFromEmergencyAbort() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        await gate.tripEmergencyAbort(reason: "SENSOR_FAILURE")
        let abortStatus = await gate.currentStatus
        XCTAssertEqual(abortStatus, .emergencyAbort)

        // Direct transition to armed is forbidden
        do {
            try await gate.arm()
            XCTFail("emergencyAbort -> armed must throw")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .emergencyAbortActive)
        }

        // Direct transition to permissiveGranted is forbidden
        do {
            try await gate.grantPermissive()
            XCTFail("emergencyAbort -> permissiveGranted must throw")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .emergencyAbortActive)
        }

        // Direct transition to locked via lock() is forbidden
        do {
            try await gate.lock()
            XCTFail("emergencyAbort -> locked via lock() must throw")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .emergencyAbort, to: .locked))
        }

        // Reset emergency abort returns strictly to locked
        try await gate.resetEmergencyAbort()
        let resetStatus = await gate.currentStatus
        XCTAssertEqual(resetStatus, .locked)

        // Resetting again when already locked must fail
        do {
            try await gate.resetEmergencyAbort()
            XCTFail("resetEmergencyAbort when locked must throw")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .locked, to: .locked))
        }

        // Can now arm normally
        try await gate.arm()
        let armedStatus = await gate.currentStatus
        XCTAssertEqual(armedStatus, .armed)
    }

    func testHighConcurrencyMultiWaiterResolution() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()

        let taskCount = 100
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    try await gate.requestPermissive()
                }
            }

            // Ensure all 100 tasks are queued and suspended
            while await gate.pendingWaitersCount < taskCount {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            // Release all waiters simultaneously
            try await gate.grantPermissive()

            // All tasks must resume and finish with success
            try await group.waitForAll()
        }

        let finalStatus = await gate.currentStatus
        let waitersRemaining = await gate.pendingWaitersCount
        XCTAssertEqual(finalStatus, .permissiveGranted)
        XCTAssertEqual(waitersRemaining, 0)
    }

    func testEmergencyAbortDrainsAllWaitersWithEmergencyAbortActive() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()

        let taskCount = 50
        let abortErrorCount = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    do {
                        try await gate.requestPermissive()
                        XCTFail("Caller must throw emergencyAbortActive")
                    } catch let error as HardwareInterlockError {
                        if error == .emergencyAbortActive {
                            abortErrorCount.withLock { $0 += 1 }
                        }
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
            }

            // Await suspension of all callers
            while await gate.pendingWaitersCount < taskCount {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }

            await gate.tripEmergencyAbort(reason: "SCRAM_TEST")
            await group.waitForAll()
        }

        let recordedAbortCount = abortErrorCount.withLock { $0 }
        let remainingWaiters = await gate.pendingWaitersCount
        let finalStatus = await gate.currentStatus

        XCTAssertEqual(recordedAbortCount, taskCount)
        XCTAssertEqual(remainingWaiters, 0)
        XCTAssertEqual(finalStatus, .emergencyAbort)
    }

    func testConcurrentCancellationRacingAgainstGrantPermissive() async throws {
        // Run repeated races to verify zero double-resume runtime traps
        for _ in 0..<30 {
            let gate = HardwareInterlockGate()
            try await gate.arm()

            let cancellationTaskCount = 20
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<cancellationTaskCount {
                    group.addTask {
                        let requestTask = Task {
                            try await gate.requestPermissive()
                        }
                        // Concurrently cancel request task
                        requestTask.cancel()
                        _ = await requestTask.result
                    }
                }

                // Race grantPermissive concurrently with cancellations
                group.addTask {
                    try? await gate.grantPermissive()
                }

                await group.waitForAll()
            }
        }
    }

    func testPermissiveTimeout() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()

        do {
            try await gate.requestPermissive(timeout: .milliseconds(50))
            XCTFail("requestPermissive must throw timedOut")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testImmediatePermissiveWhenAlreadyGranted() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        // Calling requestPermissive returns immediately
        try await gate.requestPermissive()
    }

    func testRequestPermissiveWhenLockedThrowsGateLocked() async {
        let gate = HardwareInterlockGate()
        do {
            try await gate.requestPermissive()
            XCTFail("requestPermissive when locked must throw gateLocked")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransitionHistoryAuditTrail() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()
        try await gate.lock()

        let history = await gate.transitionHistory
        XCTAssertEqual(history.count, 3)

        XCTAssertEqual(history[0].from, .locked)
        XCTAssertEqual(history[0].to, .armed)

        XCTAssertEqual(history[1].from, .armed)
        XCTAssertEqual(history[1].to, .permissiveGranted)

        XCTAssertEqual(history[2].from, .permissiveGranted)
        XCTAssertEqual(history[2].to, .locked)

        for record in history {
            XCTAssertGreaterThan(record.timestampNanoseconds, 0)
        }
    }
}
