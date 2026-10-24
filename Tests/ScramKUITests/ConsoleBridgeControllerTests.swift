import Combine
import Foundation
import ScramKCore
import ScramKVirtualization
import XCTest
@testable import ScramKUI

private actor ConsoleBridgeSignal<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func send(_ value: Value) {
        if case .some = self.value { return }
        self.value = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private enum ConsoleBridgeFixtureFailure: Error, Sendable {
    case pythonUnavailable
}

private actor ConsoleBridgeFirstUse {
    private var used = false
    func claim() -> Bool {
        if used { return false }
        used = true
        return true
    }
}

@MainActor
final class ConsoleBridgeControllerTests: XCTestCase {
    func testConfiguredStartObservesWithoutAttachingOrArming() async throws {
        let gate = HardwareInterlockGate()
        let bridge = try fixtureBridge(gate: gate)
        let controller = ConsoleStateController(interlockGate: gate, bridge: bridge)
        XCTAssertTrue(controller.isBridgeConfigured)
        XCTAssertNil(controller.bridgeSnapshot)
        XCTAssertNil(controller.pendingIntercept)
        XCTAssertNil(controller.serverInfo)
        XCTAssertNil(controller.latestBridgeTransfer)
        XCTAssertEqual(controller.bridgeConnectionState, .detached)
        await controller.start()
        XCTAssertNotNil(controller.bridgeSnapshot)
        XCTAssertEqual(controller.bridgeConnectionState, .detached)
        XCTAssertEqual(controller.currentStatus, .locked)
        XCTAssertEqual(controller.countdownTTL, "UNBOUND")
        let history = await gate.transitionHistory
        XCTAssertTrue(history.isEmpty)
        await controller.stop()
        XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 0)
    }

    func testConfiguredDetachedGrantNeverFallsBackToBareCoreGrant() async throws {
        try await withFixture { gate, _, controller in
            try await controller.armGate()
            do {
                try await controller.grantPermissive()
                XCTFail("Configured mode must not use legacy Core grant")
            } catch let error as ConsoleStateControllerError {
                XCTAssertEqual(error, .noPendingIntercept)
            }
            XCTAssertEqual(controller.currentStatus, .armed)
            XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: NO PENDING INTERCEPT")
            let history = await gate.transitionHistory
            XCTAssertEqual(history.map(\.to), [.armed])
        }
    }

    func testMissingKeyAtButtonPressCannotAdoptLaterInterceptAndPayloadIsNotLogged() async throws {
        try await withFixture { gate, _, controller in
            try await controller.attachBridge()
            let missingKey = controller.commandRequest(.grantPermissive)
            try await controller.armGate()
            let secret = "CONTROLLER_FIXTURE_SECRET_NOT_FOR_AUDIT"
            let call = Task {
                try await controller.submitTool(
                    name: "controller_fixture", argumentsJSON: Data("{\"secret\":\"\(secret)\"}".utf8)
                )
            }
            let snapshot = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let pending = try XCTUnwrap(snapshot.pendingIntercept)
            XCTAssertEqual(pending.payloadBytes, pending.commandPayload.count)
            XCTAssertEqual(pending.commandPayload.last, 0x0A)
            XCTAssertTrue(String(decoding: pending.commandPayload, as: UTF8.self).contains(secret))
            XCTAssertEqual(pending.originTrust, .appProcess)
            XCTAssertEqual(pending.originPID, ProcessInfo.processInfo.processIdentifier)
            await controller.perform(missingKey)
            XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: NO PENDING INTERCEPT")
            let ungranted = await gate.currentStatus
            XCTAssertEqual(ungranted, .armed)
            XCTAssertEqual(controller.pendingIntercept?.approval, pending.approval)
            await controller.perform(controller.commandRequest(.grantPermissive))
            let result = try await call.value
            XCTAssertEqual(result.receipt.approval, pending.approval)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            XCTAssertEqual(result.receipt.transmissionStage, .complete)
            await controller.start()
            XCTAssertEqual(controller.currentStatus, .locked, "Full-frame write must relock before reuse")
            XCTAssertFalse(controller.auditRows.contains { $0.description.contains(secret) || $0.metric.contains(secret) })
            XCTAssertTrue(controller.auditRows.contains { $0.description.contains("APPROVAL ACCEPTED") })
            XCTAssertFalse(controller.auditRows.contains { $0.description.contains("EXECUTION SUCCESS") })
            let requestID = result.receipt.requestID.uuidString
            let chunks = controller.auditRows.filter {
                $0.subsystem == "STDIO" && $0.description == "PIPE WRITE; LOCAL ACCEPTANCE ONLY" && $0.metric.contains(requestID)
            }
            var observedBytes = 0
            for row in chunks {
                let prefix = try XCTUnwrap(row.metric.split(separator: " ").first)
                observedBytes += try XCTUnwrap(Int(prefix.dropFirst()))
            }
            XCTAssertEqual(chunks.count, result.receipt.writeChunks)
            XCTAssertEqual(observedBytes, result.receipt.bytesWritten)
            XCTAssertTrue(controller.auditRows.contains {
                $0.subsystem == "STDIO" && $0.metric.contains(requestID) &&
                $0.metric.contains("WRITE \(result.receipt.bytesWritten) B/\(result.receipt.writeChunks)") &&
                $0.metric.contains("\(result.receipt.elapsedNanoseconds) ns")
            })
            let stableRows = controller.auditRows.map(\.id)
            await controller.start()
            await controller.start()
            XCTAssertEqual(controller.auditRows.map(\.id), stableRows)
        }
    }

    func testConsumedApprovalCannotAuthorizeReplacementAndConcurrentAttemptIsBusy() async throws {
        try await withFixture { _, _, controller in
            try await controller.attachBridge()
            try await controller.armGate()
            let first = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{\"attempt\":1}".utf8)) }
            let firstSnapshot = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let firstKey = try XCTUnwrap(firstSnapshot.pendingIntercept?.approval)
            let firstRequest = controller.commandRequest(.grantPermissive)
            do {
                _ = try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{\"attempt\":2}".utf8))
                XCTFail("A second privileged attempt must return Busy, not queue")
            } catch let error as BridgeError {
                XCTAssertEqual(error, .busy)
            }
            await controller.perform(firstRequest)
            let firstResult = try await first.value
            XCTAssertEqual(firstResult.receipt.approval, firstKey)
            await controller.start()
            XCTAssertEqual(controller.currentStatus, .locked)
            try await controller.armGate()
            let second = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{\"attempt\":3}".utf8)) }
            let secondSnapshot = await waitForSnapshot(controller) {
                $0.pendingIntercept?.phase == .awaitingApproval && $0.pendingIntercept?.approval != firstKey
            }
            let secondKey = try XCTUnwrap(secondSnapshot.pendingIntercept?.approval)
            XCTAssertNotEqual(secondKey.requestID, firstKey.requestID)
            XCTAssertNotEqual(secondKey.sha256, firstKey.sha256)
            await controller.perform(firstRequest)
            XCTAssertTrue(controller.lastCommandResult.hasPrefix("GRANT REJECTED:"))
            await controller.start()
            XCTAssertEqual(controller.pendingIntercept?.approval, secondKey)
            XCTAssertEqual(controller.pendingIntercept?.phase, .awaitingApproval)
            XCTAssertEqual(controller.currentStatus, .armed)
            await controller.perform(controller.commandRequest(.grantPermissive))
            let secondResult = try await second.value
            XCTAssertEqual(secondResult.receipt.approval, secondKey)
        }
    }

    func testMetadataSurfaceCannotSubmitToolsOrUnboundedJSON() async throws {
        try await withFixture { gate, _, controller in
            try await controller.attachBridge()
            let ping = Data("{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"ping\"}".utf8)
            let response = try await controller.dispatchMCPCommand(ping)
            let responseObject = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            XCTAssertNotNil(responseObject?["id"])
            XCTAssertNotNil(responseObject?["result"])
            do {
                _ = try await controller.dispatchMCPCommand(Data("{\"jsonrpc\":\"2.0\",\"id\":72,\"method\":\"tools/call\",\"params\":{}}".utf8))
                XCTFail("Raw controller metadata entry must not accept tools/call")
            } catch let error as BridgeError {
                guard case .unsupportedMethod = error else { throw error }
            }
            do {
                _ = try await controller.dispatchMCPCommand(Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8))
                XCTFail("Depth must be bounded before Foundation JSON parsing")
            } catch let error as BridgeError {
                XCTAssertEqual(error, .limitExceeded(.jsonDepth))
            }
            let history = await gate.transitionHistory
            XCTAssertTrue(history.isEmpty)
            XCTAssertEqual(controller.currentStatus, .locked)
        }
    }

    func testAwaitingResponseAtPressIsBusyAndCannotAdoptGrantableStateLater() async throws {
        try await withFixture { gate, _, controller in
            try await controller.attachBridge()
            try await controller.armGate()
            let call = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{}".utf8)) }
            let snapshot = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let pending = try XCTUnwrap(snapshot.pendingIntercept)
            // DTO projection unit seam: a non-grantable visible phase must never
            // call approve, even when that exact backend key could be admitted.
            let notGrantable = PendingIntercept(
                approval: pending.approval, toolHook: pending.toolHook,
                commandPayload: pending.commandPayload, originPID: pending.originPID,
                originTrust: pending.originTrust, phase: .awaitingResponse,
                approvalDeadline: pending.approvalDeadline
            )
            controller.applyBridgeSnapshot(BridgeSnapshot(
                cursor: snapshot.cursor, connectionState: snapshot.connectionState, generation: snapshot.generation,
                serverInfo: snapshot.serverInfo, pendingIntercept: notGrantable,
                latestTransfer: snapshot.latestTransfer, events: [], omittedEventCount: 0
            ))
            let request = controller.commandRequest(.grantPermissive)
            await controller.start() // Current source is grantable again; old press must stay Busy.
            await controller.perform(request)
            XCTAssertEqual(controller.lastCommandResult, "GRANT REJECTED: BUSY")
            let ungranted = await gate.currentStatus
            XCTAssertEqual(ungranted, .armed)
            XCTAssertEqual(controller.pendingIntercept?.phase, .awaitingApproval)
            await controller.perform(controller.commandRequest(.grantPermissive))
            let result = try await call.value
            XCTAssertEqual(result.receipt.approval, pending.approval)
        }
    }

    func testDelayedOwnedAttachIsCancelledAndSettledBeforeFreshAttach() async throws {
        let entered = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        let invalidated = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                bridgeAttachBarrier: { await entered.send(()); await release.wait() }
            )
        }) { gate, _, controller in
            let oldAttach = Task { try await controller.attachBridge() }
            await entered.wait()
            XCTAssertEqual(controller.pendingBridgeOperationCount, 1)
            let observation = controller.$isObserving.dropFirst().sink { observing in
                if !observing { Task { await invalidated.send(()) } }
            }
            let oldStop = Task { await controller.stop() }
            await invalidated.wait()
            observation.cancel()
            await controller.start()
            let newAttach = Task { try await controller.attachBridge() }
            await release.send(())
            switch await oldAttach.result {
            case .success: XCTFail("An obsolete held attach must not become a new-session attach")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError || error as? ConsoleStateControllerError == .cancelled || error as? ConsoleStateControllerError == .expiredGeneration)
            }
            await oldStop.value
            try await newAttach.value
            XCTAssertEqual(controller.bridgeConnectionState, .attached)
            XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
            XCTAssertNotNil(controller.serverInfo)
            let subscribers = await gate.activeSubscribersCount
            XCTAssertEqual(subscribers, 1)
        }
    }

    func testAbortRevokesBridgeBeforeSuspendedCoreAbortAndDoesNotWaitForGrant() async throws {
        let entered = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                commandAdmissionBarrier: { command in
                    if command == .emergencyAbort { await entered.send(()); await release.wait() }
                }
            )
        }) { gate, bridge, controller in
            try await controller.attachBridge()
            try await controller.armGate()
            let call = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{}".utf8)) }
            let snapshot = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let key = try XCTUnwrap(snapshot.pendingIntercept?.approval)
            let abort = Task { await controller.emergencyAbort() }
            await entered.wait() // Core abort has not run; bridge revocation must already have happened.
            do {
                _ = try await bridge.approve(key)
                XCTFail("Bridge admission must be revoked before waiting for Core/transport")
            } catch let error as BridgeError {
                XCTAssertTrue(Self.isAdmissionRevocation(error))
            }
            let beforeCoreAbort = await gate.currentStatus
            XCTAssertNotEqual(beforeCoreAbort, .permissiveGranted)
            await release.send(())
            await abort.value
            switch await call.result {
            case .success: XCTFail("Unapproved revoked call must not receive a tool result")
            case let .failure(error):
                if let error = error as? BridgeError { XCTAssertTrue(Self.isExpectedTeardown(error) || Self.isAdmissionRevocation(error)) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertEqual(controller.currentStatus, .emergencyAbort)
            XCTAssertEqual(controller.bridgeConnectionState, .detached)
            XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
        }
    }

    func testLateAcceptedApprovalCannotOverwriteAbortOrReplacementGeneration() async throws {
        let accepted = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                commandCompletionBarrier: { command in
                    if command == .grantPermissive { await accepted.send(()); await release.wait() }
                }
            )
        }) { _, _, controller in
            try await controller.attachBridge()
            let oldGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            try await controller.armGate()
            let call = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{}".utf8)) }
            _ = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let request = controller.commandRequest(.grantPermissive)
            let approval = Task { await controller.perform(request) }
            await accepted.wait()
            await controller.emergencyAbort()
            await controller.stop()
            await controller.start()
            try await controller.resetAbort()
            try await controller.attachBridge()
            let newGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            XCTAssertNotEqual(oldGeneration, newGeneration)
            let outcomeBeforeRelease = controller.lastCommandResult
            let rowsBeforeRelease = controller.auditRows.map(\.id)
            await release.send(())
            await approval.value
            switch await call.result {
            case .success(let result):
                XCTAssertEqual(result.receipt.connectionGeneration, oldGeneration)
                XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            case .failure(let error):
                if let error = error as? BridgeError {
                    XCTAssertTrue(Self.isExpectedTeardown(error))
                } else {
                    XCTAssertTrue(error is CancellationError)
                }
            }
            XCTAssertEqual(controller.bridgeSnapshot?.generation, newGeneration)
            XCTAssertEqual(controller.currentStatus, .locked)
            XCTAssertEqual(controller.lastCommandResult, outcomeBeforeRelease)
            XCTAssertEqual(controller.auditRows.map(\.id), rowsBeforeRelease)
        }
    }

    func testLateAbortCompletionCannotRetireReplacementConnectionWithinSameSession() async throws {
        let accepted = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                commandCompletionBarrier: { command in
                    if command == .emergencyAbort { await accepted.send(()); await release.wait() }
                }
            )
        }) { gate, bridge, controller in
            try await controller.attachBridge()
            let firstGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            let oldAbort = Task { await controller.emergencyAbort() }
            await accepted.wait() // Core accepted abort; only its presentation completion is held.
            let aborted = await gate.currentStatus
            XCTAssertEqual(aborted, .emergencyAbort)
            await controller.detachBridge()
            try await controller.resetAbort()
            try await controller.attachBridge()
            let replacementGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            XCTAssertNotEqual(firstGeneration, replacementGeneration)
            XCTAssertTrue(controller.isObserving)
            // Deliberately no stop/start: the UI session stays S throughout G1 -> G2.
            let before = await bridge.snapshot()
            let gateHistoryBefore = await gate.transitionHistory
            let rowsBefore = controller.auditRows.map(\.id)
            let rowIDsBefore = Set(rowsBefore)
            let latestCommandBefore = controller.lastCommandResult
            XCTAssertFalse(controller.auditRows.contains {
                $0.subsystem == "COMMAND" && $0.description == "ABORT ACCEPTED: GATE ONLY"
            })
            await release.send(())
            await oldAbort.value

            let after = await bridge.snapshot(after: before.cursor)
            XCTAssertEqual(after.cursor, before.cursor, "Old completion must not create a new revoke/detach event")
            XCTAssertTrue(after.events.isEmpty)
            XCTAssertEqual(after.generation, replacementGeneration)
            XCTAssertEqual(after.connectionState, .attached)
            XCTAssertEqual(controller.bridgeSnapshot?.generation, replacementGeneration)
            XCTAssertEqual(controller.lastCommandResult, latestCommandBefore)
            let gateHistoryAfter = await gate.transitionHistory
            XCTAssertEqual(gateHistoryAfter, gateHistoryBefore)
            XCTAssertEqual(controller.auditRows.filter { rowIDsBefore.contains($0.id) }.map(\.id), rowsBefore)
            XCTAssertEqual(controller.auditRows.filter { !rowIDsBefore.contains($0.id) }.map(\.description), ["ABORT ACCEPTED: GATE ONLY"])
            XCTAssertEqual(controller.auditRows.filter {
                $0.subsystem == "COMMAND" && $0.description == "ABORT ACCEPTED: GATE ONLY"
            }.count, 1)
            XCTAssertEqual(controller.pendingCommandCount, 0)
            XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
            // Confirm G2 is physically usable, not just a stale attached projection.
            let response = try await controller.dispatchMCPCommand(Data("{\"jsonrpc\":\"2.0\",\"id\":401,\"method\":\"ping\"}".utf8))
            XCTAssertFalse(response.isEmpty)
            XCTAssertEqual(controller.latestBridgeTransfer?.connectionGeneration, replacementGeneration)
        }
    }

    func testLateAbortCompletionCannotRevokeReplacementToolLeaseWithinSameSession() async throws {
        let accepted = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                commandCompletionBarrier: { command in
                    if command == .emergencyAbort { await accepted.send(()); await release.wait() }
                }
            )
        }) { gate, bridge, controller in
            try await controller.attachBridge()
            let firstGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            try await controller.armGate()
            let oldCall = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{\"connection\":1}".utf8)) }
            _ = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let oldAbort = Task { await controller.emergencyAbort() }
            await accepted.wait()
            await controller.detachBridge() // Settles the captured G1 I/O and approval ownership.
            switch await oldCall.result {
            case .success:
                XCTFail("G1 had no tool approval and must not receive a tool result")
            case .failure(let error):
                if let error = error as? BridgeError {
                    XCTAssertTrue(Self.isExpectedTeardown(error) || Self.isAdmissionRevocation(error))
                } else {
                    XCTAssertTrue(error is CancellationError)
                }
            }
            try await controller.resetAbort()
            try await controller.attachBridge()
            let replacementGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            XCTAssertNotEqual(firstGeneration, replacementGeneration)
            try await controller.armGate()
            let replacementCall = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{\"connection\":2}".utf8)) }
            let replacement = await waitForSnapshot(controller) {
                $0.generation == replacementGeneration && $0.pendingIntercept?.phase == .awaitingApproval
            }
            let replacementKey = try XCTUnwrap(replacement.pendingIntercept?.approval)
            let replacementGrant = controller.commandRequest(.grantPermissive)
            let before = await bridge.snapshot()
            let gateHistoryBefore = await gate.transitionHistory
            let rowsBefore = controller.auditRows.map(\.id)
            let rowIDsBefore = Set(rowsBefore)
            let latestCommandBefore = controller.lastCommandResult
            oldAbort.cancel() // Already accepted: cancellation must not retarget teardown at G2.
            await release.send(())
            await oldAbort.value

            let after = await bridge.snapshot(after: before.cursor)
            XCTAssertEqual(after.cursor, before.cursor, "G2's pending lease must not receive an old abort's revocation")
            XCTAssertTrue(after.events.isEmpty)
            XCTAssertEqual(after.connectionState, .attached)
            XCTAssertEqual(after.generation, replacementGeneration)
            XCTAssertEqual(after.pendingIntercept?.approval, replacementKey)
            XCTAssertEqual(after.pendingIntercept?.phase, .awaitingApproval)
            XCTAssertEqual(controller.currentStatus, .armed)
            XCTAssertEqual(controller.lastCommandResult, latestCommandBefore)
            let gateHistoryAfter = await gate.transitionHistory
            XCTAssertEqual(gateHistoryAfter, gateHistoryBefore)
            XCTAssertEqual(controller.auditRows.filter { rowIDsBefore.contains($0.id) }.map(\.id), rowsBefore)
            XCTAssertEqual(controller.auditRows.filter { !rowIDsBefore.contains($0.id) }.map(\.description), ["ABORT ACCEPTED: GATE ONLY"])
            XCTAssertEqual(controller.auditRows.filter {
                $0.subsystem == "COMMAND" && $0.description == "ABORT ACCEPTED: GATE ONLY"
            }.count, 1)
            await controller.perform(replacementGrant)
            let result = try await replacementCall.value
            XCTAssertEqual(result.receipt.approval, replacementKey)
            XCTAssertEqual(result.receipt.connectionGeneration, replacementGeneration)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
        }
    }

    func testBridgeDTOAuditUsesActualPositiveChunksAndDeduplicatesCursors() {
        let controller = ConsoleStateController(interlockGate: HardwareInterlockGate())
        let generation = UUID()
        let request = UUID()
        let receipt = BridgeTransferReceipt(
            requestID: request, connectionGeneration: generation, approval: nil,
            bytesWritten: 12, writeChunks: 2, bytesRead: 17, readChunks: 1,
            elapsedNanoseconds: 61, transmissionStage: .complete,
            hasCorrelatedResponse: false, outcome: .revoked(.operatorAbort)
        )
        let events = [
            BridgeEvent(cursor: 1, generation: generation, monotonicTimeNanoseconds: 11,
                        kind: .chunkWritten(requestID: request, bytes: 7, totalWritten: 7, elapsedNanoseconds: 23)),
            BridgeEvent(cursor: 2, generation: generation, monotonicTimeNanoseconds: 12,
                        kind: .chunkWritten(requestID: request, bytes: 0, totalWritten: 7, elapsedNanoseconds: 29)),
            BridgeEvent(cursor: 3, generation: generation, monotonicTimeNanoseconds: 13,
                        kind: .chunkWritten(requestID: request, bytes: 5, totalWritten: 12, elapsedNanoseconds: 41)),
            BridgeEvent(cursor: 4, generation: generation, monotonicTimeNanoseconds: 14, kind: .transferFinished(receipt)),
            BridgeEvent(cursor: 5, generation: generation, monotonicTimeNanoseconds: 15,
                        kind: .failure(.transportFailed(reason: "SECRET_RAW_DIAGNOSTIC", receipt: nil)))
        ]
        let snapshot = BridgeSnapshot(cursor: 5, connectionState: .attached, generation: generation,
                                      serverInfo: nil, pendingIntercept: nil, latestTransfer: receipt,
                                      events: events, omittedEventCount: 0)
        controller.applyBridgeSnapshot(snapshot)
        let identities = controller.auditRows.map(\.id)
        controller.applyBridgeSnapshot(snapshot)
        XCTAssertEqual(controller.auditRows.map(\.id), identities)
        XCTAssertEqual(controller.auditRows.count, 4)
        XCTAssertEqual(controller.auditRows[0].subsystem, "STDIO")
        XCTAssertTrue(controller.auditRows[0].metric.contains("+7 B · TOTAL 7 B · 23 ns"))
        XCTAssertTrue(controller.auditRows[1].metric.contains("+5 B · TOTAL 12 B · 41 ns"))
        XCTAssertTrue(controller.auditRows[2].description.contains("EXECUTION UNKNOWN"))
        XCTAssertTrue(controller.auditRows[2].metric.contains("WRITE 12 B/2 · STDOUT 17 B/1 · 61 ns"))
        XCTAssertEqual(controller.latestBridgeTransfer, receipt)
        XCTAssertFalse(controller.auditRows.contains { $0.description.contains("SHM") || $0.description.contains("SECRET_RAW_DIAGNOSTIC") })
    }

    func testStopRevokesInstalledConnectionBeforeHeldApprovalCanReachBackend() async throws {
        let entered = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        let invalidated = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                commandAdmissionBarrier: { command in
                    if command == .grantPermissive { await entered.send(()); await release.wait() }
                }
            )
        }) { gate, bridge, controller in
            try await controller.attachBridge()
            try await controller.armGate()
            let call = Task { try await controller.submitTool(name: "controller_fixture", argumentsJSON: Data("{}".utf8)) }
            let snapshot = await waitForSnapshot(controller) { $0.pendingIntercept?.phase == .awaitingApproval }
            let key = try XCTUnwrap(snapshot.pendingIntercept?.approval)
            let request = controller.commandRequest(.grantPermissive)
            let approval = Task { await controller.perform(request) }
            await entered.wait()
            let observation = controller.$isObserving.dropFirst().sink { observing in
                if !observing { Task { await invalidated.send(()) } }
            }
            let oldStop = Task { await controller.stop() }
            await invalidated.wait()
            observation.cancel()
            do {
                _ = try await bridge.approve(key)
                XCTFail("stop must revoke the installed connection before its first await")
            } catch let error as BridgeError {
                XCTAssertTrue(Self.isAdmissionRevocation(error))
            }
            await controller.start()
            await release.send(())
            await approval.value
            await oldStop.value
            switch await call.result {
            case .success: XCTFail("A held, unapproved request must not be transmitted by stale work")
            case let .failure(error):
                if let error = error as? BridgeError { XCTAssertTrue(Self.isExpectedTeardown(error) || Self.isAdmissionRevocation(error)) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            await controller.start()
            let status = await gate.currentStatus
            XCTAssertNotEqual(status, .permissiveGranted)
            XCTAssertEqual(controller.bridgeConnectionState, .detached)
            XCTAssertEqual(controller.pendingCommandCount, 0)
            XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
            let subscribers = await gate.activeSubscribersCount
            XCTAssertEqual(subscribers, 1)
        }
    }

    func testHeldOldBridgeObservationSettlesBeforeFreshConnectionCanAttach() async throws {
        let entered = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        let invalidated = ConsoleBridgeSignal<Void>()
        try await withFixture(makeController: { gate, bridge in
            ConsoleStateController(
                interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
                bridgeObservationDeliveryBarrier: { await entered.send(()); await release.wait() }
            )
        }) { gate, _, controller in
            try await controller.attachBridge()
            await entered.wait()
            let oldGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            let observation = controller.$isObserving.dropFirst().sink { observing in
                if !observing { Task { await invalidated.send(()) } }
            }
            let oldStop = Task { await controller.stop() }
            await invalidated.wait()
            observation.cancel()
            await controller.start()
            let freshAttach = Task { try await controller.attachBridge() }
            // New attach owns a wait on old cleanup; it cannot race an old detach
            // or inherit the held callback's request/connection generation.
            await release.send(())
            await oldStop.value
            try await freshAttach.value
            let newGeneration = try XCTUnwrap(controller.bridgeSnapshot?.generation)
            XCTAssertNotEqual(oldGeneration, newGeneration)
            XCTAssertEqual(controller.bridgeConnectionState, .attached)
            XCTAssertEqual(controller.currentStatus, .locked)
            XCTAssertNil(controller.pendingIntercept)
            let identities = controller.auditRows.map(\.id)
            await controller.start()
            XCTAssertEqual(controller.auditRows.map(\.id), identities)
            let subscribers = await gate.activeSubscribersCount
            XCTAssertEqual(subscribers, 1)
        }
    }

    func testHeldBridgeBootstrapUnsubscribesBothOldSourcesWithoutClobberingRebind() async throws {
        let gate = HardwareInterlockGate()
        let bridge = try fixtureBridge(gate: gate)
        let firstUse = ConsoleBridgeFirstUse()
        let registered = ConsoleBridgeSignal<Void>()
        let release = ConsoleBridgeSignal<Void>()
        let invalidated = ConsoleBridgeSignal<Void>()
        let controller = ConsoleStateController(
            interlockGate: gate, bridge: bridge, observationDeliveryBarrier: nil,
            bridgeBootstrapDeliveryBarrier: { _ in
                if await firstUse.claim() { await registered.send(()); await release.wait() }
            }
        )
        let oldStart = Task { await controller.start() }
        await registered.wait()
        XCTAssertFalse(controller.isObserving)
        let observation = controller.$isObserving.dropFirst().sink { observing in
            if !observing { Task { await invalidated.send(()) } }
        }
        let oldStop = Task { await controller.stop() }
        await invalidated.wait()
        observation.cancel()
        await controller.start()
        await release.send(())
        await oldStart.value
        await oldStop.value
        do {
            try await controller.attachBridge()
            let oldRequestID = controller.latestBridgeTransfer?.requestID
            _ = try await bridge.dispatchMCPCommand(Data("{\"jsonrpc\":\"2.0\",\"id\":301,\"method\":\"ping\"}".utf8))
            _ = await waitForSnapshot(controller) {
                $0.latestTransfer?.hasCorrelatedResponse == true && $0.latestTransfer?.requestID != oldRequestID
            }
            XCTAssertTrue(controller.isObserving)
            XCTAssertEqual(controller.bridgeConnectionState, .attached)
            let subscribers = await gate.activeSubscribersCount
            XCTAssertEqual(subscribers, 1)
            await controller.stop()
            let finalSubscribers = await gate.activeSubscribersCount
            XCTAssertEqual(finalSubscribers, 0)
        } catch {
            await controller.stop()
            throw error
        }
    }

    func testBridgeDTOGapReconciliationAndDisplayRetentionRemainMarked() {
        let controller = ConsoleStateController(interlockGate: HardwareInterlockGate())
        let generation = UUID()
        let request = UUID()
        let suffix = (18...300).map { cursor in
            BridgeEvent(cursor: UInt64(cursor), generation: generation, monotonicTimeNanoseconds: UInt64(cursor),
                        kind: .chunkWritten(requestID: request, bytes: 1, totalWritten: cursor, elapsedNanoseconds: UInt64(cursor)))
        }
        controller.applyBridgeSnapshot(BridgeSnapshot(
            cursor: 300, connectionState: .attached, generation: generation,
            serverInfo: nil, pendingIntercept: nil, latestTransfer: nil,
            events: suffix, omittedEventCount: 17
        ))
        XCTAssertEqual(controller.auditRows.count, ConsoleStateController.auditRowLimit)
        XCTAssertEqual(controller.auditRows.first?.subsystem, "OBSERVATION")
        XCTAssertTrue(controller.auditRows.first?.metric.contains("17 BRIDGE EVENTS OMITTED") == true)
        XCTAssertTrue(controller.auditRows.first?.metric.contains("DISPLAY ROWS TRUNCATED") == true)
        let identities = controller.auditRows.map(\.id)
        controller.applyBridgeSnapshot(BridgeSnapshot(
            cursor: 299, connectionState: .detached, generation: nil,
            serverInfo: nil, pendingIntercept: nil, latestTransfer: nil,
            events: [], omittedEventCount: 0
        ))
        XCTAssertEqual(controller.bridgeSnapshot?.cursor, 300)
        XCTAssertEqual(controller.bridgeConnectionState, .attached)
        XCTAssertEqual(controller.auditRows.map(\.id), identities)
    }

    private func waitForSnapshot(
        _ controller: ConsoleStateController,
        matching predicate: @escaping @Sendable (BridgeSnapshot) -> Bool
    ) async -> BridgeSnapshot {
        let signal = ConsoleBridgeSignal<BridgeSnapshot>()
        let subscription = controller.$bridgeSnapshot.compactMap { $0 }.filter(predicate).prefix(1).sink { snapshot in
            Task { await signal.send(snapshot) }
        }
        let result = await signal.wait()
        subscription.cancel()
        return result
    }

    private func withFixture(
        makeController: (@MainActor (HardwareInterlockGate, ContainerSocketBridge) -> ConsoleStateController)? = nil,
        _ body: @MainActor (HardwareInterlockGate, ContainerSocketBridge, ConsoleStateController) async throws -> Void
    ) async throws {
        let gate = HardwareInterlockGate()
        let bridge = try fixtureBridge(gate: gate)
        let controller = makeController?(gate, bridge) ?? ConsoleStateController(interlockGate: gate, bridge: bridge)
        await controller.start()
        do {
            try await body(gate, bridge, controller)
            await controller.stop()
            await assertFixtureStopped(gate: gate, bridge: bridge, controller: controller)
        } catch {
            await controller.stop()
            await assertFixtureStopped(gate: gate, bridge: bridge, controller: controller)
            throw error
        }
    }

    private func assertFixtureStopped(
        gate: HardwareInterlockGate, bridge: ContainerSocketBridge, controller: ConsoleStateController
    ) async {
        let snapshot = await bridge.snapshot()
        XCTAssertEqual(snapshot.connectionState, .detached)
        XCTAssertNil(snapshot.pendingIntercept)
        XCTAssertFalse(controller.isObserving)
        XCTAssertEqual(controller.pendingBridgeOperationCount, 0)
        XCTAssertEqual(controller.pendingCommandCount, 0)
        XCTAssertNotEqual(controller.lastCommandResult, "DETACH INCOMPLETE: LOCAL CLEANUP")
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 0)
        for event in snapshot.events {
            if case .detached(let receipt) = event.kind {
                XCTAssertNotEqual(receipt.outcome, .cleanupIncomplete)
                XCTAssertTrue(receipt.handlesClosed)
            }
        }
    }

    private func fixtureBridge(gate: HardwareInterlockGate) throws -> ContainerSocketBridge {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw ConsoleBridgeFixtureFailure.pythonUnavailable }
        return ContainerSocketBridge(
            interlockGate: gate, executableURL: URL(fileURLWithPath: python),
            arguments: ["-u", "-c", Self.pythonStub]
        )
    }

    private static func isAdmissionRevocation(_ error: BridgeError) -> Bool {
        switch error {
        case .revoked, .cancelled, .detached, .staleGeneration, .staleApproval, .declined: true
        default: false
        }
    }

    private static func isExpectedTeardown(_ error: BridgeError) -> Bool {
        switch error {
        case .revoked, .cancelled, .detached, .staleGeneration, .endOfStream, .processExited: true
        case .gateRejected(let error, _):
            error == .emergencyAbortActive || error == .gateLocked || error == .taskCancelled
        default: false
        }
    }

    // Owned local protocol fixture. It executes no tools and never contacts Docker/network.
    private static let pythonStub = #"""
    import json, sys
    for line in sys.stdin.buffer:
        request = json.loads(line)
        method = request.get("method")
        if "id" not in request:
            continue
        if method == "initialize":
            result = {"protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
                      "capabilities": {"tools": {"listChanged": False}},
                      "serverInfo": {"name": "controller-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "controller_fixture", "description": "Owned inert test fixture",
                                  "inputSchema": {"type": "object"}}]}
        elif method == "ping":
            result = {}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "fixture protocol result; no tool executed"}], "isError": False}
        else:
            response = {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "unsupported fixture method"}}
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
            continue
        response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    """#
}
