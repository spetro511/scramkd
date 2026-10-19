import Combine
import XCTest
import TacticalCore
@testable import TacticalUI

/// Explicit handshakes, not sleeps, choose command completion order.
private actor ConsoleTestLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class ConsoleStateControllerTests: XCTestCase {
    func testInitializationIsInactiveAndBootstrapIsLockedAndIdempotent() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        XCTAssertFalse(controller.isObserving)
        XCTAssertTrue(controller.auditRows.isEmpty)
        XCTAssertEqual(controller.currentStatus, .locked)
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        XCTAssertFalse(controller.isBridgeConfigured)
        XCTAssertNil(controller.bridgeSnapshot)
        XCTAssertNil(controller.pendingIntercept)
        XCTAssertEqual(controller.bridgeConnectionState, .detached)
        let initialSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(initialSubscribers, 0)
        await controller.start()
        await controller.start()
        XCTAssertTrue(controller.isObserving)
        XCTAssertEqual(controller.currentStatus, .locked)
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 1)
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
        await controller.stop()
        await controller.stop()
        let finalSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(finalSubscribers, 0)
    }

    func testBootstrapReflectsInjectedStateAndActualHistoryOnly() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        XCTAssertEqual(controller.currentStatus, .permissiveGranted)
        XCTAssertEqual(controller.auditRows.map(\.subsystem), ["INTERLOCK", "INTERLOCK"])
        XCTAssertEqual(controller.auditRows.map(\.metric), ["#1", "#2"])
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        await controller.stop()
    }

    func testRejectedGrantHasNoSuccessOrTransitionAndExplicitArmThenGrantWorks() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        await controller.perform(.grantPermissive)
        XCTAssertEqual(controller.currentStatus, .locked)
        XCTAssertTrue(controller.lastCommandResult.hasPrefix("GRANT REJECTED:"))
        XCTAssertFalse(controller.auditRows.contains { $0.description.contains("ACCEPTED") })
        let rejectedHistory = await gate.transitionHistory
        XCTAssertTrue(rejectedHistory.isEmpty)

        await controller.perform(.armGate)
        XCTAssertEqual(controller.currentStatus, .armed)
        await controller.perform(.armGate)
        let armedHistory = await gate.transitionHistory
        XCTAssertEqual(armedHistory.count, 1, "Idempotent arm must not invent a transition")
        await controller.perform(.grantPermissive)
        XCTAssertEqual(controller.currentStatus, .permissiveGranted)
        XCTAssertEqual(controller.lastCommandResult, "GRANT ACCEPTED: GATE ONLY")
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "INTERLOCK" }.map(\.metric), ["#1", "#2"])
        await controller.stop()
    }

    func testAbortRecoveryRequiresExplicitResetThenSeparateArm() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        await controller.resetEmergencyAbort()
        XCTAssertTrue(controller.lastCommandResult.hasPrefix("RESET REJECTED:"))
        await controller.emergencyAbort()
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        await controller.perform(.armGate)
        XCTAssertEqual(controller.lastCommandResult, "ARM REJECTED: ABORT ACTIVE")
        await controller.perform(.grantPermissive)
        XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: ABORT ACTIVE")
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        await controller.resetEmergencyAbort()
        XCTAssertEqual(controller.currentStatus, .locked)
        let resetHistory = await gate.transitionHistory
        XCTAssertEqual(resetHistory.map(\.to), [.emergencyAbort, .locked])
        await controller.perform(.armGate)
        XCTAssertEqual(controller.currentStatus, .armed)
        await controller.stop()
    }

    func testLateGrantCompletionCannotOverwriteNewerAbortProjectionOrOutcome() async {
        let gate = HardwareInterlockGate()
        let entered = ConsoleTestLatch()
        let release = ConsoleTestLatch()
        let controller = ConsoleStateController(interlockGate: gate, observationDeliveryBarrier: nil, commandCompletionBarrier: { command in
            if command == .grantPermissive {
                await entered.signal()
                await release.wait()
            }
        })
        await controller.start()
        await controller.perform(.armGate)
        let grant = Task { await controller.perform(.grantPermissive) }
        await entered.wait() // The gate accepted grant, but its UI completion is held.
        let grantedStatus = await gate.currentStatus
        XCTAssertEqual(grantedStatus, .permissiveGranted)
        await controller.emergencyAbort() // Must not queue behind the held grant.
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        await release.signal()
        await grant.value
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.lastCommandResult, "ABORT ACCEPTED: GATE ONLY")
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" && $0.description == "GRANT ACCEPTED: GATE ONLY" }.count, 1)
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" && $0.description == "ABORT ACCEPTED: GATE ONLY" }.count, 1)
        await controller.stop()
    }

    func testAbortBeforeGrantRejectsGrantEvenWhenAbortCompletionIsHeld() async {
        let gate = HardwareInterlockGate()
        let entered = ConsoleTestLatch()
        let release = ConsoleTestLatch()
        let controller = ConsoleStateController(interlockGate: gate, observationDeliveryBarrier: nil, commandCompletionBarrier: { command in
            if command == .emergencyAbort {
                await entered.signal()
                await release.wait()
            }
        })
        await controller.start()
        await controller.perform(.armGate)
        let abort = Task { await controller.emergencyAbort() }
        await entered.wait()
        await controller.perform(.grantPermissive)
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: ABORT ACTIVE")
        await release.signal()
        await abort.value
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: ABORT ACTIVE")
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" && $0.description == "GRANT REJECTED: ABORT ACTIVE" }.count, 1)
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" && $0.description == "ABORT ACCEPTED: GATE ONLY" }.count, 1)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed, .emergencyAbort])
        await controller.stop()
    }

    func testF12IsNotImplementedAndHasNoGateEffects() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        await controller.perform(.armGate)
        let before = await gate.transitionHistory
        await controller.forceAirgapDump()
        let after = await gate.transitionHistory
        let waiters = await gate.pendingWaitersCount
        XCTAssertEqual(before, after)
        XCTAssertEqual(waiters, 0)
        XCTAssertEqual(controller.currentStatus, .armed)
        XCTAssertEqual(controller.lastCommandResult, "F12 NOT IMPLEMENTED")
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        await controller.stop()
        await controller.forceAirgapDump()
        XCTAssertEqual(controller.lastCommandResult, "F12 NOT IMPLEMENTED")
        let stoppedHistory = await gate.transitionHistory
        XCTAssertEqual(stoppedHistory, after)
    }

    func testBoundedAuditMarksTruncationWithoutSeededRows() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        for _ in 0..<(ConsoleStateController.auditRowLimit + 4) {
            await controller.forceAirgapDump()
        }
        XCTAssertEqual(controller.auditRows.count, ConsoleStateController.auditRowLimit)
        XCTAssertEqual(controller.auditRows.first?.description, "OLDER DISPLAY ROWS TRUNCATED")
        XCTAssertEqual(controller.auditRows.first?.metric, "5 ROWS")
        XCTAssertEqual(controller.auditRows.last?.description, "F12 NOT IMPLEMENTED")
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
        await controller.stop()
    }

    func testBoundedBootstrapReportsOmittedTransitionsAndReconcilesStatus() async throws {
        let gate = HardwareInterlockGate()
        for _ in 0..<((ConsoleStateController.auditRowLimit / 2) + 2) {
            try await gate.arm()
            try await gate.lock()
        }
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        XCTAssertEqual(controller.currentStatus, .locked)
        XCTAssertEqual(controller.auditRows.count, ConsoleStateController.auditRowLimit)
        // A persistent observation-gap marker must survive display-row truncation.
        XCTAssertTrue(controller.auditRows.contains { $0.subsystem == "OBSERVATION" })
        await controller.stop()
    }

    func testDroppedLiveObservationsReconcileWithAndWithoutHistoryOmission() async throws {
        for cycles in [100, 200] {
            let gate = HardwareInterlockGate()
            let entered = ConsoleTestLatch()
            let release = ConsoleTestLatch()
            let reconciled = ConsoleTestLatch()
            let controller = ConsoleStateController(
                interlockGate: gate,
                observationDeliveryBarrier: {
                    await entered.signal()
                    await release.wait()
                }
            )
            await controller.start()
            let statusObservation = controller.$currentStatus.sink { status in
                if status == .emergencyAbort {
                    Task { await reconciled.signal() }
                }
            }
            try await gate.arm()
            await entered.wait() // Hold delivery of cursor 1 while the bounded buffer overflows.
            for _ in 0..<cycles {
                try await gate.lock()
                try await gate.arm()
            }
            await gate.tripEmergencyAbort(reason: "CONTROLLED_OBSERVATION_OVERFLOW")
            await release.signal()
            await reconciled.wait()
            statusObservation.cancel()
            XCTAssertEqual(controller.currentStatus, .emergencyAbort)
            let transitionCount = (cycles * 2) + 2
            let transitionRows = controller.auditRows.filter { $0.subsystem == "INTERLOCK" }
            if transitionCount <= ConsoleStateController.auditRowLimit {
                XCTAssertEqual(transitionRows.map(\.metric), (1...transitionCount).map { "#\($0)" })
                XCTAssertFalse(controller.auditRows.contains { $0.subsystem == "OBSERVATION" })
            } else {
                XCTAssertEqual(controller.auditRows.count, ConsoleStateController.auditRowLimit)
                XCTAssertEqual(controller.auditRows.first?.subsystem, "OBSERVATION")
                XCTAssertTrue(controller.auditRows.first?.metric.contains("TRANSITIONS OMITTED") == true)
                XCTAssertEqual(transitionRows.last?.metric, "#\(transitionCount)")
            }
            await controller.stop()
        }
    }

    func testConcurrentStartsAndStopsShareSubscriptionAndCleanup() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        async let first: Void = controller.start()
        async let second: Void = controller.start()
        _ = await (first, second)
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 1)
        XCTAssertTrue(controller.isObserving)
        async let firstStop: Void = controller.stop()
        async let secondStop: Void = controller.stop()
        _ = await (firstStop, secondStop)
        let finalSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(finalSubscribers, 0)
    }

    func testRegisteredPendingBootstrapCannotOverwriteRestartAndOldCleanupSettles() async {
        let gate = HardwareInterlockGate()
        let bootstrapRegistered = ConsoleTestLatch()
        let releaseOldBootstrap = ConsoleTestLatch()
        let invalidated = ConsoleTestLatch()
        let secondStartReady = AsyncStream<Void>.makeStream()
        let controller = ConsoleStateController(
            interlockGate: gate,
            observationDeliveryBarrier: nil,
            bootstrapDeliveryBarrier: { snapshot in
                if snapshot.cursor == 0 {
                    await bootstrapRegistered.signal()
                    await releaseOldBootstrap.wait()
                }
            }
        )
        let firstStart = Task { await controller.start() }
        await bootstrapRegistered.wait()
        XCTAssertFalse(controller.isObserving)
        XCTAssertTrue(controller.auditRows.isEmpty)
        let registered = await gate.activeSubscribersCount
        XCTAssertEqual(registered, 1, "The old bootstrap is registered but has not reached presentation")

        let secondStart = Task {
            secondStartReady.continuation.yield(())
            secondStartReady.continuation.finish()
            await controller.start()
        }
        var secondStartIterator = secondStartReady.stream.makeAsyncIterator()
        _ = await secondStartIterator.next()
        let sharedSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(sharedSubscribers, 1, "Concurrent start must share the held bootstrap")

        // dropFirst removes the initial false value. This publication happens after
        // stop invalidates the old session, before its cleanup can finish.
        let invalidationObservation = controller.$isObserving.dropFirst().sink { observing in
            if !observing { Task { await invalidated.signal() } }
        }
        let oldStop = Task { await controller.stop() }
        await invalidated.wait()
        invalidationObservation.cancel()
        await gate.tripEmergencyAbort(reason: "RESTART_DURING_PENDING_BOOTSTRAP")
        await controller.start()
        XCTAssertTrue(controller.isObserving)
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        let restartedRows = controller.auditRows.map(\.id)
        XCTAssertEqual(controller.auditRows.map(\.metric), ["#1"])

        await releaseOldBootstrap.signal()
        await firstStart.value
        await secondStart.value
        await oldStop.value // Both old startup deliveries and teardown are now settled.
        let survivingSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(survivingSubscribers, 1)
        XCTAssertTrue(controller.isObserving)
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.auditRows.map(\.id), restartedRows)
        XCTAssertEqual(controller.auditRows.map(\.metric), ["#1"])
        await controller.stop()
        let finalSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(finalSubscribers, 0)
    }

    func testHeldOldObservationCannotOverwriteRestartAndOldCleanupSettles() async throws {
        let gate = HardwareInterlockGate()
        let deliveryEntered = ConsoleTestLatch()
        let releaseOldDelivery = ConsoleTestLatch()
        let invalidated = ConsoleTestLatch()
        let controller = ConsoleStateController(
            interlockGate: gate,
            observationDeliveryBarrier: {
                await deliveryEntered.signal()
                await releaseOldDelivery.wait()
            }
        )
        await controller.start()
        try await gate.arm()
        await deliveryEntered.wait() // Cursor 1 was consumed but not applied.
        XCTAssertEqual(controller.currentStatus, .locked)
        XCTAssertTrue(controller.auditRows.isEmpty)
        let invalidationObservation = controller.$isObserving.dropFirst().sink { observing in
            if !observing { Task { await invalidated.signal() } }
        }
        let oldStop = Task { await controller.stop() }
        await invalidated.wait()
        invalidationObservation.cancel()
        await gate.tripEmergencyAbort(reason: "RESTART_WITH_OLD_OBSERVATION_HELD")
        await controller.start()
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        let restartedRows = controller.auditRows.map(\.id)
        XCTAssertEqual(controller.auditRows.map(\.metric), ["#1", "#2"])

        await releaseOldDelivery.signal()
        await oldStop.value // Waits for the old observation task, not just unsubscribe.
        let survivingSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(survivingSubscribers, 1)
        XCTAssertTrue(controller.isObserving)
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.auditRows.map(\.id), restartedRows)
        XCTAssertEqual(controller.auditRows.map(\.metric), ["#1", "#2"])
        await controller.stop()
        let finalSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(finalSubscribers, 0)
    }

    func testStopRestartRejectsOldCompletionAndResumesWithoutDuplicateAudit() async throws {
        let gate = HardwareInterlockGate()
        let entered = ConsoleTestLatch()
        let release = ConsoleTestLatch()
        let controller = ConsoleStateController(interlockGate: gate, observationDeliveryBarrier: nil, commandCompletionBarrier: { command in
            if command == .grantPermissive {
                await entered.signal()
                await release.wait()
            }
        })
        await controller.start()
        await controller.perform(.armGate)
        let oldGrant = Task { await controller.perform(.grantPermissive) }
        await entered.wait()
        await controller.stop()
        let stoppedSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(stoppedSubscribers, 0)
        await gate.tripEmergencyAbort(reason: "CLOSED_WINDOW_ABORT")
        await controller.start()
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        let before = controller.auditRows.map(\.id)
        await release.signal()
        await oldGrant.value
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.auditRows.map(\.id), before)
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "INTERLOCK" }.map(\.metric), ["#1", "#2", "#3"])
        await controller.stop()
        let finalSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(finalSubscribers, 0)

        // Rebinding the presentation uses a new controller and its own injected gate.
        let replacementGate = HardwareInterlockGate()
        let replacement = ConsoleStateController(interlockGate: replacementGate)
        await replacement.start()
        XCTAssertEqual(replacement.currentStatus, .locked)
        XCTAssertTrue(replacement.auditRows.isEmpty)
        await replacement.stop()
    }

    func testStoppedCommandsAreRejectedWithoutGateEffects() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.perform(.armGate)
        XCTAssertEqual(controller.lastCommandResult, "ARM REJECTED: NOT OBSERVING")
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
    }

    func testThrowingWrappersReportTypedNotObservingAndAuditEachRejectionOnce() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        for command in [ConsoleCommand.armGate, .grantPermissive, .resetEmergencyAbort] {
            let before = controller.auditRows.count
            do {
                switch command {
                case .armGate: try await controller.armGate()
                case .grantPermissive: try await controller.grantPermissive()
                case .resetEmergencyAbort: try await controller.resetAbort()
                default: XCTFail("Unexpected test command")
                }
                XCTFail("An inactive controller must throw")
            } catch let error as ConsoleStateControllerError {
                XCTAssertEqual(error, .notObserving)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(controller.auditRows.count, before + 1)
            XCTAssertEqual(controller.auditRows.last?.subsystem, "COMMAND")
            XCTAssertTrue(controller.lastCommandResult.hasSuffix("REJECTED: NOT OBSERVING"))
        }
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(controller.isObserving)
    }

    func testThrowingWrappersPreserveActualInvalidTransitionAndAbortErrors() async throws {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        do {
            try await controller.grantPermissive()
            XCTFail("Grant from locked must throw the gate's error")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .locked, to: .permissiveGranted))
        }
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" }.count, 1)
        XCTAssertFalse(controller.auditRows.contains { $0.description.contains("ACCEPTED") })
        do {
            try await controller.resetAbort()
            XCTFail("Reset from locked must throw the gate's error")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .locked, to: .locked))
        }
        await controller.tripAbort()
        for command in [ConsoleCommand.armGate, .grantPermissive] {
            let before = controller.auditRows.filter { $0.subsystem == "COMMAND" }.count
            do {
                if command == .armGate {
                    try await controller.armGate()
                } else {
                    try await controller.grantPermissive()
                }
                XCTFail("Abort must reject arm and grant")
            } catch let error as HardwareInterlockError {
                XCTAssertEqual(error, .emergencyAbortActive)
            }
            XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" }.count, before + 1)
            XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        }
        try await controller.resetAbort()
        XCTAssertEqual(controller.currentStatus, .locked)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.emergencyAbort, .locked])
        await controller.stop()
    }

    func testThrowingArmAndGrantDistinguishAtomicNoOpsWithoutInventedTransitions() async throws {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        try await controller.armGate()
        XCTAssertEqual(controller.lastCommandResult, "ARM ACCEPTED: GATE ONLY")
        try await controller.armGate()
        XCTAssertEqual(controller.lastCommandResult, "ARM NO-OP: GATE UNCHANGED")
        XCTAssertEqual(controller.auditRows.last?.tagColor, "slate")
        var history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed])
        try await controller.grantPermissive()
        XCTAssertEqual(controller.lastCommandResult, "GRANT ACCEPTED: GATE ONLY")
        try await controller.grantPermissive()
        XCTAssertEqual(controller.lastCommandResult, "GRANT NO-OP: GATE UNCHANGED")
        history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed, .permissiveGranted])
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "INTERLOCK" }.map(\.metric), ["#1", "#2"])
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" }.count, 4)
        XCTAssertEqual(controller.auditRows.filter { $0.description.contains("ACCEPTED") && $0.subsystem == "COMMAND" }.count, 2)
        do {
            try await controller.armGate()
            XCTFail("Arm from permissive must retain the gate's rejection")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .invalidTransition(from: .permissiveGranted, to: .armed))
        }
        await controller.stop()
    }

    func testAbortAliasesPreserveExactReasonsAndResetAliasesNeverAutoArm() async throws {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        let exactReason = "VERBATIM_OPERATOR_REASON_17"
        await controller.tripAbort(reason: exactReason)
        var history = await gate.transitionHistory
        XCTAssertEqual(history.last?.reason, exactReason)
        XCTAssertTrue(controller.auditRows.contains { $0.subsystem == "INTERLOCK" && $0.description.hasSuffix(exactReason) })
        try await controller.resetAbort()
        XCTAssertEqual(controller.currentStatus, .locked)
        await controller.tripAbort()
        await controller.resetEmergencyAbort()
        XCTAssertEqual(controller.currentStatus, .locked)
        await controller.emergencyAbort()
        await controller.perform(.resetEmergencyAbort)
        XCTAssertEqual(controller.currentStatus, .locked)
        await controller.perform(.emergencyAbort)
        history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.emergencyAbort, .locked, .emergencyAbort, .locked, .emergencyAbort, .locked, .emergencyAbort])
        XCTAssertEqual(history.filter { $0.to == .emergencyAbort }.map(\.reason), [exactReason, "MANUAL_OPERATOR_OVERRIDE", "MANUAL_OPERATOR_OVERRIDE", "MANUAL_OPERATOR_OVERRIDE"])
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" }.count, 7)
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        await controller.stop()
    }

    func testUnboundTTLDoesNotInventExpiryTransitionsAcrossLifecycle() async throws {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        try await controller.armGate()
        await controller.start()
        await controller.stop()
        await controller.start()
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        XCTAssertEqual(controller.currentStatus, .armed)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.reason), ["ARM_COMMAND_ACCEPTED"])
        await controller.stop()
    }

    func testCancelledBeforeEntryRejectsCapturedRequestAndCurrentCommandWithoutMutation() async throws {
        for capturedRequest in [true, false] {
            let gate = HardwareInterlockGate()
            let controller = ConsoleStateController(interlockGate: gate)
            await controller.start()
            try await controller.armGate()
            let request = controller.commandRequest(.grantPermissive)
            XCTAssertEqual(request.command, .grantPermissive)
            let callerReady = ConsoleTestLatch()
            let releaseCaller = ConsoleTestLatch()
            let caller = Task {
                await callerReady.signal()
                await releaseCaller.wait()
                if capturedRequest {
                    await controller.perform(request)
                } else {
                    await controller.perform(.grantPermissive)
                }
            }
            await callerReady.wait()
            caller.cancel()
            await releaseCaller.signal()
            await caller.value
            XCTAssertEqual(controller.currentStatus, .armed)
            XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: CANCELLED")
            XCTAssertEqual(controller.pendingCommandCount, 0)
            let history = await gate.transitionHistory
            XCTAssertEqual(history.map(\.to), [.armed])
            XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" && $0.description == "GRANT REJECTED: CANCELLED" }.count, 1)
            await controller.stop()
            let subscribers = await gate.activeSubscribersCount
            XCTAssertEqual(subscribers, 0)
        }
    }

    func testCancelledThrowingAliasPropagatesTypedCancellationWithoutMutation() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        let callerReady = ConsoleTestLatch()
        let releaseCaller = ConsoleTestLatch()
        let caller = Task {
            await callerReady.signal()
            await releaseCaller.wait()
            try await controller.armGate()
        }
        await callerReady.wait()
        caller.cancel()
        await releaseCaller.signal()
        switch await caller.result {
        case .success:
            XCTFail("A cancelled throwing command must not report acceptance")
        case let .failure(error):
            XCTAssertEqual(error as? ConsoleStateControllerError, .cancelled)
        }
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(controller.pendingCommandCount, 0)
        XCTAssertEqual(controller.lastCommandResult, "ARM REJECTED: CANCELLED")
        await controller.stop()
    }

    func testButtonRequestCapturedBeforeCloseCannotAdoptRestartedSession() async throws {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()
        try await controller.armGate()
        let oldRequest = controller.commandRequest(.grantPermissive)
        await controller.stop()
        await controller.start()
        XCTAssertEqual(controller.currentStatus, .armed, "The retained gate remains armed")
        await controller.perform(oldRequest) // Deliberately not cancelled: generation alone must reject it.
        XCTAssertEqual(controller.currentStatus, .armed)
        XCTAssertEqual(controller.auditRows.last?.description, "GRANT REJECTED: EXPIRED SESSION")
        XCTAssertEqual(controller.pendingCommandCount, 0)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed])
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "INTERLOCK" }.map(\.metric), ["#1"])
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 1)
        await controller.stop()
    }

    func testCancellationWhileGateAdmissionIsSuspendedRevokesPendingMutation() async throws {
        let gate = HardwareInterlockGate()
        let admissionEntered = ConsoleTestLatch()
        let releaseAdmission = ConsoleTestLatch()
        let controller = ConsoleStateController(
            interlockGate: gate, observationDeliveryBarrier: nil,
            commandAdmissionBarrier: { command in
                if command == .grantPermissive {
                    await admissionEntered.signal()
                    await releaseAdmission.wait()
                }
            }
        )
        await controller.start()
        try await controller.armGate()
        let request = controller.commandRequest(.grantPermissive)
        let caller = Task { await controller.perform(request) }
        await admissionEntered.wait()
        XCTAssertEqual(controller.pendingCommandCount, 1)
        caller.cancel()
        await releaseAdmission.signal()
        await caller.value
        XCTAssertEqual(controller.currentStatus, .armed)
        XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: CANCELLED")
        XCTAssertEqual(controller.pendingCommandCount, 0)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed])
        await controller.stop()
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 0)
    }

    func testStopRevokesAndSettlesOwnedAdmissionBeforeOldTaskCanMutateRestartedGate() async throws {
        let gate = HardwareInterlockGate()
        let admissionEntered = ConsoleTestLatch()
        let releaseAdmission = ConsoleTestLatch()
        let invalidated = ConsoleTestLatch()
        let controller = ConsoleStateController(
            interlockGate: gate, observationDeliveryBarrier: nil,
            commandAdmissionBarrier: { command in
                if command == .grantPermissive {
                    await admissionEntered.signal()
                    await releaseAdmission.wait()
                }
            }
        )
        await controller.start()
        try await controller.armGate()
        let oldRequest = controller.commandRequest(.grantPermissive)
        let oldCaller = Task { await controller.perform(oldRequest) }
        await admissionEntered.wait()
        XCTAssertEqual(controller.pendingCommandCount, 1)
        let invalidationObservation = controller.$isObserving.dropFirst().sink { observing in
            if !observing { Task { await invalidated.signal() } }
        }
        let oldStop = Task { await controller.stop() }
        await invalidated.wait() // stop has synchronously revoked and cancelled old admission.
        invalidationObservation.cancel()
        await controller.start()
        XCTAssertEqual(controller.currentStatus, .armed)
        await controller.perform(oldRequest)
        XCTAssertEqual(controller.auditRows.last?.description, "GRANT REJECTED: EXPIRED SESSION")
        await controller.perform(controller.commandRequest(.armGate))
        XCTAssertEqual(controller.lastCommandResult, "ARM NO-OP: GATE UNCHANGED")
        await releaseAdmission.signal()
        await oldCaller.value
        await oldStop.value // Settles the controller-owned gate task, not just the old subscriber.
        XCTAssertEqual(controller.currentStatus, .armed)
        XCTAssertEqual(controller.pendingCommandCount, 0)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed])
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "INTERLOCK" }.map(\.metric), ["#1"])
        XCTAssertFalse(controller.auditRows.contains { $0.subsystem == "COMMAND" && $0.description == "GRANT ACCEPTED: GATE ONLY" })
        let survivingSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(survivingSubscribers, 1)
        await controller.stop()
        let finalSubscribers = await gate.activeSubscribersCount
        XCTAssertEqual(finalSubscribers, 0)
    }

    func testAbortRemainsIndependentOfSuspendedGrantAdmission() async throws {
        let gate = HardwareInterlockGate()
        let admissionEntered = ConsoleTestLatch()
        let releaseAdmission = ConsoleTestLatch()
        let controller = ConsoleStateController(
            interlockGate: gate, observationDeliveryBarrier: nil,
            commandAdmissionBarrier: { command in
                if command == .grantPermissive {
                    await admissionEntered.signal()
                    await releaseAdmission.wait()
                }
            }
        )
        await controller.start()
        try await controller.armGate()
        let request = controller.commandRequest(.grantPermissive)
        let grant = Task { await controller.perform(request) }
        await admissionEntered.wait()
        await controller.emergencyAbort() // Must complete while grant is still held.
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.pendingCommandCount, 1)
        grant.cancel()
        await releaseAdmission.signal()
        await grant.value
        XCTAssertEqual(controller.currentStatus, .emergencyAbort)
        XCTAssertEqual(controller.lastCommandResult, "ABORT ACCEPTED: GATE ONLY")
        XCTAssertEqual(controller.pendingCommandCount, 0)
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed, .emergencyAbort])
        await controller.stop()
    }

    func testCancellationAfterAcceptedMutationDoesNotRollBackOrFalsifyOutcome() async throws {
        let gate = HardwareInterlockGate()
        let accepted = ConsoleTestLatch()
        let releaseCompletion = ConsoleTestLatch()
        let controller = ConsoleStateController(interlockGate: gate, observationDeliveryBarrier: nil, commandCompletionBarrier: { command in
            if command == .grantPermissive {
                await accepted.signal()
                await releaseCompletion.wait()
            }
        })
        await controller.start()
        try await controller.armGate()
        let request = controller.commandRequest(.grantPermissive)
        let caller = Task { await controller.perform(request) }
        await accepted.wait()
        let acceptedStatus = await gate.currentStatus
        XCTAssertEqual(acceptedStatus, .permissiveGranted)
        XCTAssertEqual(controller.pendingCommandCount, 0)
        caller.cancel()
        await releaseCompletion.signal()
        await caller.value
        XCTAssertEqual(controller.currentStatus, .permissiveGranted)
        XCTAssertEqual(controller.lastCommandResult, "GRANT ACCEPTED: GATE ONLY")
        XCTAssertEqual(controller.auditRows.filter { $0.subsystem == "COMMAND" && $0.description == "GRANT ACCEPTED: GATE ONLY" }.count, 1)
        XCTAssertFalse(controller.auditRows.contains { $0.description == "GRANT REJECTED: CANCELLED" })
        let history = await gate.transitionHistory
        XCTAssertEqual(history.map(\.to), [.armed, .permissiveGranted])
        await controller.stop()
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 0)
    }
}
