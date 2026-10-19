import Foundation
import TacticalCore
import XCTest
import os
@testable import TacticalVirtualization

/// Internal barriers suspend only outside admission/completion locks and outside
/// actual I/O. Real-clock waits below are failure watchdogs, not race ordering.
private final class BridgeRegressionBarrier: Sendable {
    private let entered = MCPIOCompletion<Void>()
    private let exited = MCPIOCompletion<Void>()
    private let release = BridgeOneShot<Void>()
    private let opened = OSAllocatedUnfairLock(initialState: false)

    var isOpen: Bool { opened.withLock { $0 } }

    func pause() async {
        entered.finish(.success(()))
        do { try await release.value() }
        catch { XCTFail("Regression barrier consumed more than once: \(error)") }
        exited.finish(.success(()))
    }

    func waitUntilEntered() async throws {
        try await entered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
    }

    func waitUntilExited() async throws {
        try await exited.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
    }

    func open() {
        opened.withLock { $0 = true }
        release.finish(.success(()))
    }
}

private final class BridgeRetirementProbe: Sendable {
    let clock = BridgeManualClock()
    let stop = BridgeRegressionBarrier()
    let timer = BridgeRegressionBarrier()
    let bothObservers = MCPIOCompletion<Void>()
    private let observerCount = OSAllocatedUnfairLock(initialState: 0)
    private let stopCount = OSAllocatedUnfairLock(initialState: 0)

    var cleanupAttempts: Int { stopCount.withLock { $0 } }
    var observers: Int { observerCount.withLock { $0 } }

    func hooks(holdTimer: Bool = false) -> BridgeTestHooks {
        var hooks = BridgeTestHooks()
        hooks.beforeRetirementCompletion = { _, succeeded in
            self.stopCount.withLock { $0 += 1 }
            XCTAssertTrue(succeeded, "The inert fixture must stop before the completion barrier")
            await self.stop.pause()
        }
        hooks.detachObserverRegistered = { _ in
            let count = self.observerCount.withLock { count in count += 1; return count }
            if count == 2 { self.bothObservers.finish(.success(())) }
        }
        if holdTimer { hooks.beforeRetirementTimerClaim = { _ in await self.timer.pause() } }
        return hooks
    }

    func waitUntilBothObserve() async throws {
        try await bothObservers.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
    }
}

final class BridgeSecurityRegressionTests: XCTestCase {
    private enum InjectedSessionFailure: Error, Sendable, Equatable {
        case afterObserversRegistered
    }

    private static func detachTask(
        _ bridge: ContainerSocketBridge, result: MCPIOCompletion<BridgeDetachReceipt>
    ) -> Task<Void, Never> {
        Task {
            let receipt = await bridge.detach()
            result.finish(.success(receipt))
        }
    }

    private static func result(_ completion: MCPIOCompletion<BridgeDetachReceipt>) async throws -> BridgeDetachReceipt {
        try await completion.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
    }

    private static func watchClosure(
        _ observation: BridgeObservation, completion: MCPIOCompletion<BridgeDetachReceipt>
    ) -> Task<Void, Never> {
        Task {
            for await event in observation.events {
                if case .detached(let receipt) = event.kind, receipt.outcome == .detached, receipt.handlesClosed {
                    completion.finish(.success(receipt))
                    return
                }
            }
        }
    }

    func testOneShotRejectsSecondConsumerWithoutOverwritingFirst() async throws {
        let registered = MCPIOCompletion<Void>()
        let firstResult = MCPIOCompletion<Int>()
        let completion = BridgeOneShot<Int>(onConsumerRegistered: { registered.finish(.success(())) })
        let first = Task {
            do { firstResult.finish(.success(try await completion.value())) }
            catch { firstResult.finish(.failure(error)) }
        }
        defer { completion.finish(.failure(BridgeError.detached)); first.cancel() }
        try await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        do {
            _ = try await completion.value()
            XCTFail("A second consumer replaced the first continuation")
        } catch let error as BridgeCompletionError { XCTAssertEqual(error, .multipleConsumers) }
        XCTAssertTrue(completion.finish(.success(7)))
        let observed = try await firstResult.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(observed, 7)
        do { _ = try await completion.value(); XCTFail("Repeated single-consumer await accepted") }
        catch let error as BridgeCompletionError { XCTAssertEqual(error, .multipleConsumers) }
        XCTAssertFalse(completion.finish(.success(8)))
    }

    func testSharedCompletionSupportsMultipleObserversAndImmutableFirstResult() async throws {
        let completion = BridgeSharedCompletion<Int>()
        let firstResult = MCPIOCompletion<Int>()
        let secondResult = MCPIOCompletion<Int>()
        let first = Task {
            do { firstResult.finish(.success(try await completion.value())) }
            catch { firstResult.finish(.failure(error)) }
        }
        let second = Task {
            do { secondResult.finish(.success(try await completion.value())) }
            catch { secondResult.finish(.failure(error)) }
        }
        defer { completion.finish(.failure(BridgeError.detached)); first.cancel(); second.cancel() }
        first.cancel() // Observer cancellation must not cancel the owned producer.
        XCTAssertTrue(completion.finish(.success(9)))
        XCTAssertFalse(completion.finish(.failure(BridgeError.timedOut(.detach, receipt: nil))))
        let one = try await firstResult.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        let two = try await secondResult.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        let cached = try await completion.value()
        XCTAssertEqual(one, 9)
        XCTAssertEqual(two, 9)
        XCTAssertEqual(cached, 9)
    }

    func testConcurrentDetachObserversShareSuccessWithoutCancellingCleanup() async throws {
        let probe = BridgeRetirementProbe()
        defer { probe.stop.open(); probe.timer.open() }
        try await BridgeFixture.withSession(timing: probe.clock.timing, hooks: probe.hooks()) { session in
            defer { probe.stop.open(); probe.timer.open() }
            let one = MCPIOCompletion<BridgeDetachReceipt>()
            let two = MCPIOCompletion<BridgeDetachReceipt>()
            let first = Self.detachTask(session.bridge, result: one)
            let second = Self.detachTask(session.bridge, result: two)
            defer { first.cancel(); second.cancel() }
            try await probe.waitUntilBothObserve()
            try await probe.stop.waitUntilEntered()
            XCTAssertEqual(probe.cleanupAttempts, 1)
            first.cancel()
            probe.stop.open()
            let receiptOne = try await Self.result(one)
            let receiptTwo = try await Self.result(two)
            XCTAssertEqual(receiptOne, receiptTwo)
            // Inspect cached results from the uncancelled test task, not the
            // Void producer API or the deliberately cancelled detach observer.
            let cachedOne = try await Self.result(one)
            let cachedTwo = try await Self.result(two)
            XCTAssertEqual(cachedOne, receiptOne)
            XCTAssertEqual(cachedTwo, receiptTwo)
            XCTAssertEqual(receiptOne.outcome, .detached)
            XCTAssertTrue(receiptOne.handlesClosed)
            XCTAssertEqual(probe.observers, 2)
            XCTAssertEqual(probe.cleanupAttempts, 1)
            let snapshot = await session.bridge.snapshot()
            XCTAssertEqual(snapshot.connectionState, .detached)
            XCTAssertNil(snapshot.generation)
        }
    }

    func testConcurrentDetachObserversShareCleanupIncompleteAndLaterReleaseOwnership() async throws {
        let probe = BridgeRetirementProbe()
        defer { probe.stop.open(); probe.timer.open() }
        try await BridgeFixture.withSession(timing: probe.clock.timing, hooks: probe.hooks()) { session in
            defer { probe.stop.open(); probe.timer.open() }
            let observation = await session.bridge.observe()
            let closed = MCPIOCompletion<BridgeDetachReceipt>()
            let watcher = Self.watchClosure(observation, completion: closed)
            defer { watcher.cancel() }
            let one = MCPIOCompletion<BridgeDetachReceipt>()
            let two = MCPIOCompletion<BridgeDetachReceipt>()
            let first = Self.detachTask(session.bridge, result: one)
            let second = Self.detachTask(session.bridge, result: two)
            defer { first.cancel(); second.cancel() }
            try await probe.waitUntilBothObserve()
            try await probe.stop.waitUntilEntered()
            probe.clock.advance(seconds: 3)
            let receiptOne = try await Self.result(one)
            let receiptTwo = try await Self.result(two)
            XCTAssertEqual(receiptOne, receiptTwo)
            XCTAssertEqual(receiptOne.outcome, .cleanupIncomplete)
            XCTAssertFalse(receiptOne.handlesClosed)
            XCTAssertEqual(receiptOne.elapsedNanoseconds, 3_000_000_000)
            let held = await session.bridge.snapshot()
            XCTAssertEqual(held.generation, session.info.generation)
            XCTAssertEqual(held.connectionState, .detaching)
            do { _ = try await session.bridge.attach(); XCTFail("Unretired ownership admitted a replacement") }
            catch let error as BridgeError { XCTAssertEqual(error, .busy) }
            probe.stop.open()
            let eventual = try await Self.result(closed)
            XCTAssertEqual(eventual.outcome, .detached)
            XCTAssertTrue(eventual.handlesClosed)
            let cached = try await Self.result(one)
            XCTAssertEqual(cached, receiptOne)
            XCTAssertEqual(probe.cleanupAttempts, 1)
            let after = await session.bridge.snapshot()
            XCTAssertEqual(after.connectionState, .detached)
            XCTAssertNil(after.generation)
            await session.bridge.unsubscribe(id: observation.id)
        }
    }

    private static func heldTimerLateCleanup(advance seconds: Int64) async throws {
        let probe = BridgeRetirementProbe()
        defer { probe.stop.open(); probe.timer.open() }
        try await BridgeFixture.withSession(timing: probe.clock.timing, hooks: probe.hooks(holdTimer: true)) { session in
            defer { probe.stop.open(); probe.timer.open() }
            let observation = await session.bridge.observe()
            let closed = MCPIOCompletion<BridgeDetachReceipt>()
            let watcher = Self.watchClosure(observation, completion: closed)
            defer { watcher.cancel() }
            let one = MCPIOCompletion<BridgeDetachReceipt>()
            let two = MCPIOCompletion<BridgeDetachReceipt>()
            let first = Self.detachTask(session.bridge, result: one)
            let second = Self.detachTask(session.bridge, result: two)
            defer { first.cancel(); second.cancel() }
            try await probe.waitUntilBothObserve()
            try await probe.stop.waitUntilEntered()
            probe.clock.advance(seconds: seconds)
            try await probe.timer.waitUntilEntered()
            // The scheduled timeout has not claimed anything. Cleanup itself
            // must classify its first completion using the authoritative clock.
            probe.stop.open()
            let receiptOne = try await Self.result(one)
            let receiptTwo = try await Self.result(two)
            XCTAssertEqual(receiptOne, receiptTwo)
            XCTAssertEqual(receiptOne.outcome, .cleanupIncomplete)
            XCTAssertTrue(receiptOne.handlesClosed, "Closure is verified, but was not claimed within budget")
            XCTAssertEqual(receiptOne.elapsedNanoseconds, UInt64(seconds) * 1_000_000_000)
            let eventual = try await Self.result(closed)
            XCTAssertEqual(eventual.outcome, .detached)
            XCTAssertTrue(eventual.handlesClosed)
            probe.timer.open()
            try await probe.timer.waitUntilExited()
            let stillFirst = try await Self.result(one)
            XCTAssertEqual(stillFirst, receiptOne)
            XCTAssertEqual(probe.cleanupAttempts, 1)
            let snapshot = await session.bridge.snapshot()
            XCTAssertEqual(snapshot.connectionState, .detached)
            XCTAssertNil(snapshot.generation)
            let active = await session.bridge.isBridgeActive
            XCTAssertFalse(active)
            let status = await session.gate.currentStatus
            XCTAssertEqual(status, .locked)
            await session.bridge.unsubscribe(id: observation.id)
        }
    }

    func testLateCleanupFirstClaimUsesDeadlineWhileTimerIsHeld() async throws {
        try await Self.heldTimerLateCleanup(advance: 3)
    }

    func testExactRetirementDeadlineIsBudgetExhaustionWhileTimerHeld() async throws {
        try await Self.heldTimerLateCleanup(advance: 2)
    }

    func testTimelyRetirementResultSurvivesLateTimer() async throws {
        let probe = BridgeRetirementProbe()
        defer { probe.stop.open(); probe.timer.open() }
        try await BridgeFixture.withSession(timing: probe.clock.timing, hooks: probe.hooks()) { session in
            defer { probe.stop.open(); probe.timer.open() }
            let one = MCPIOCompletion<BridgeDetachReceipt>()
            let two = MCPIOCompletion<BridgeDetachReceipt>()
            let first = Self.detachTask(session.bridge, result: one)
            let second = Self.detachTask(session.bridge, result: two)
            defer { first.cancel(); second.cancel() }
            try await probe.waitUntilBothObserve()
            try await probe.stop.waitUntilEntered()
            probe.stop.open()
            let accepted = try await Self.result(one)
            let peer = try await Self.result(two)
            XCTAssertEqual(accepted, peer)
            XCTAssertEqual(accepted.outcome, .detached)
            probe.clock.advance(seconds: 3)
            let cached = try await Self.result(one)
            XCTAssertEqual(cached, accepted)
            let snapshot = await session.bridge.snapshot()
            XCTAssertFalse(snapshot.events.contains {
                if case .detached(let receipt) = $0.kind { return receipt.outcome == .cleanupIncomplete }
                return false
            })
            XCTAssertEqual(snapshot.connectionState, .detached)
            XCTAssertEqual(probe.cleanupAttempts, 1)
        }
    }

    func testInjectedSessionErrorReleasesBarriersBeforeFixtureCleanup() async throws {
        let probe = BridgeRetirementProbe()
        defer { probe.stop.open(); probe.timer.open() }
        let one = MCPIOCompletion<BridgeDetachReceipt>()
        let two = MCPIOCompletion<BridgeDetachReceipt>()
        let captured = MCPIOCompletion<(
            bridge: ContainerSocketBridge, first: Task<Void, Never>, second: Task<Void, Never>
        )>()
        do {
            try await BridgeFixture.withSession(timing: probe.clock.timing, hooks: probe.hooks(holdTimer: true)) { session in
                // This defer must run before withSession's catch awaits detach.
                // Neither watchdog failure nor the deliberate error can leave
                // the fixture's owned cleanup behind a body-owned barrier.
                defer { probe.stop.open(); probe.timer.open() }
                let first = Self.detachTask(session.bridge, result: one)
                let second = Self.detachTask(session.bridge, result: two)
                captured.finish(.success((session.bridge, first, second)))
                defer { first.cancel(); second.cancel() }
                try await probe.waitUntilBothObserve()
                try await probe.stop.waitUntilEntered()
                XCTAssertFalse(probe.stop.isOpen)
                XCTAssertFalse(probe.timer.isOpen)
                // Logical time stays before the retirement deadline. The failure
                // is deliberate, not manufactured by waiting for a watchdog.
                throw InjectedSessionFailure.afterObserversRegistered
            }
            XCTFail("The injected body error did not propagate")
        } catch let error as InjectedSessionFailure {
            XCTAssertEqual(error, .afterObserversRegistered)
        }
        XCTAssertTrue(probe.stop.isOpen)
        XCTAssertTrue(probe.timer.isOpen)
        try await probe.stop.waitUntilExited()
        let handles = try await captured.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        let first = try await Self.result(one)
        let second = try await Self.result(two)
        await handles.first.value
        await handles.second.value
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.outcome, .detached)
        XCTAssertTrue(first.handlesClosed)
        XCTAssertEqual(probe.cleanupAttempts, 1)
        XCTAssertGreaterThanOrEqual(probe.observers, 2)
        let snapshot = await handles.bridge.snapshot()
        XCTAssertEqual(snapshot.connectionState, .detached)
        XCTAssertNil(snapshot.generation)
    }

    func testCancelledApproveAtAPIEntryCannotReachAdmission() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let start = BridgeOneShot<Void>()
        let admissions = OSAllocatedUnfairLock(initialState: 0)
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) },
                                    beforeApprovalAdmission: { _ in admissions.withLock { $0 += 1 } })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { start.finish(.success(())); work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let approval = Task {
                try await start.value()
                return try await session.bridge.approve(pending.approval)
            }
            defer { approval.cancel() }
            approval.cancel()
            start.finish(.success(()))
            do { _ = try await approval.value; XCTFail("Cancelled API entry granted") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(admissions.withLock { $0 }, 0)
            let history = await session.gate.transitionHistory
            XCTAssertFalse(history.contains { $0.to == .permissiveGranted })
            let receipt = try await session.bridge.cancel(pending.approval)
            XCTAssertEqual(receipt.bytesWritten, 0)
            do { _ = try await work.value; XCTFail("An unapproved dispatch ran") }
            catch { XCTAssertTrue(error is BridgeError) }
        }
    }

    func testCancellationBeforeCoreAdmissionCannotGrantDifferentDispatchTask() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let beforeAdmission = BridgeRegressionBarrier()
        defer { beforeAdmission.open() }
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) },
                                    beforeApprovalAdmission: { _ in await beforeAdmission.pause() })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let approval = Task { try await session.bridge.approve(pending.approval) }
            defer { approval.cancel() }
            try await beforeAdmission.waitUntilEntered()
            approval.cancel()
            beforeAdmission.open()
            do { _ = try await approval.value; XCTFail("Cancelled queued approval granted") }
            catch { XCTAssertTrue(error is CancellationError) }
            let history = await session.gate.transitionHistory
            XCTAssertFalse(history.contains { $0.to == .permissiveGranted })
            let snapshot = await session.bridge.snapshot()
            XCTAssertFalse(snapshot.events.contains {
                if case .approvalAdmitted = $0.kind { return true }
                return false
            })
            XCTAssertFalse(snapshot.events.contains {
                if case .chunkWritten(let id, _, _, _) = $0.kind { return id == pending.approval.requestID }
                return false
            })
            let receipt = try await session.bridge.cancel(pending.approval)
            XCTAssertEqual(receipt.bytesWritten, 0)
            XCTAssertEqual(receipt.transmissionStage, .none)
            do { _ = try await work.value; XCTFail("Uncancelled dispatch inherited a cancelled approval") }
            catch { XCTAssertTrue(error is BridgeError) }
        }
    }

    func testAdmissionBeforeCancellationReturnsActualAcceptedReceipt() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let admitted = MCPIOCompletion<BridgeApprovalReceipt>()
        let afterAdmission = BridgeRegressionBarrier()
        let beforeWrite = BridgeRegressionBarrier()
        let target = OSAllocatedUnfairLock<UUID?>(initialState: nil)
        defer { afterAdmission.open(); beforeWrite.open() }
        let hooks = BridgeTestHooks(beforeWrite: { id, _ in
            if target.withLock({ $0 == id }) { await beforeWrite.pause() }
        }, pendingPublished: { pending in
            target.withLock { $0 = pending.approval.requestID }
            intercept.finish(.success(pending))
        }, afterApprovalAdmission: { receipt in
            admitted.finish(.success(receipt))
            await afterAdmission.pause()
        })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let approval = Task { try await session.bridge.approve(pending.approval) }
            defer { approval.cancel() }
            let accepted = try await admitted.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            try await afterAdmission.waitUntilEntered()
            approval.cancel()
            afterAdmission.open()
            let delivered = try await approval.value
            XCTAssertEqual(delivered, accepted)
            XCTAssertEqual(delivered.key, pending.approval)
            let history = await session.gate.transitionHistory
            XCTAssertEqual(history.filter { $0.to == .permissiveGranted }.count, 1)
            XCTAssertEqual(UInt64(history.count), delivered.admittedGateCursor)
            beforeWrite.open()
            let result = try await work.value
            XCTAssertEqual(result.receipt.transmissionStage, .complete)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
        }
    }
}
