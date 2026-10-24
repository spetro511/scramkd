import Foundation
import ScramKCore
import XCTest
import os
@testable import ScramKVirtualization

final class BridgeAuthorizationTests: XCTestCase {
    func testOpaqueTupleBusyAndLocalApplicationOrigin() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data(#"{"originPID":1,"isHighRiskAction":false}"#.utf8), generation: session.info.generation) }
            defer { work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            XCTAssertEqual(pending.originTrust, .appProcess)
            XCTAssertEqual(pending.originPID, ProcessInfo.processInfo.processIdentifier)
            XCTAssertEqual(pending.payloadBytes, pending.commandPayload.count)
            XCTAssertEqual(pending.approval, BridgeAdmissionFence.key(requestID: pending.approval.requestID,
                                                                      generation: session.info.generation, frame: pending.commandPayload))
            do {
                _ = try await session.bridge.submitTool(name: "another", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
                XCTFail("A second privileged request was queued")
            } catch let error as BridgeError { XCTAssertEqual(error, .busy) }
            let wrongID = BridgeApprovalKey(requestID: UUID(), sha256: pending.approval.sha256, connectionGeneration: session.info.generation)
            let wrongHash = BridgeApprovalKey(requestID: pending.approval.requestID, sha256: "wrong", connectionGeneration: session.info.generation)
            let wrongGeneration = BridgeApprovalKey(requestID: pending.approval.requestID, sha256: pending.approval.sha256, connectionGeneration: UUID())
            for (key, expected) in [(wrongID, BridgeError.staleApproval), (wrongHash, .wrongHash), (wrongGeneration, .staleGeneration)] {
                do { _ = try await session.bridge.approve(key); XCTFail("Invalid approval accepted") }
                catch let error as BridgeError { XCTAssertEqual(error, expected) }
            }
            _ = try await session.bridge.approve(pending.approval)
            let result = try await work.value
            XCTAssertEqual(result.receipt.approval, pending.approval)
            XCTAssertEqual(result.receipt.bytesWritten, pending.payloadBytes)
            do { _ = try await session.bridge.approve(pending.approval); XCTFail("Completed key reused") }
            catch let error as BridgeError { XCTAssertEqual(error, .staleApproval) }
        }
    }

    func testBareCoreGrantDoesNotReleasePendingRequest() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let release = BridgeOneShot<Void>()
        let hooks = BridgeTestHooks(pendingPublished: { pending in
            intercept.finish(.success(pending))
            do { try await release.value() } catch { XCTFail("Fixture barrier failed") }
        })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { release.finish(.success(())); work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            try await session.gate.grantPermissive()
            let snapshot = await session.bridge.snapshot()
            XCTAssertEqual(snapshot.pendingIntercept?.phase, .awaitingApproval)
            do {
                _ = try await session.bridge.approve(pending.approval)
                XCTFail("Previous/bare permissive state is not request-bound approval")
            } catch let error as BridgeError {
                guard case .gateRejected = error else { return XCTFail("Unexpected error: \(error)") }
            }
            let receipt = try await session.bridge.cancel(pending.approval)
            XCTAssertEqual(receipt.bytesWritten, 0)
            release.finish(.success(()))
            do { _ = try await work.value; XCTFail("Bare grant released tool bytes") }
            catch { XCTAssertTrue(error is BridgeError) }
        }
    }

    func testSingleFiveSecondBudgetAndExactExpiryWithControlledClock() async throws {
        let clock = BridgeManualClock()
        let intercept = MCPIOCompletion<PendingIntercept>()
        let release = BridgeOneShot<Void>()
        let hooks = BridgeTestHooks(pendingPublished: { pending in
            intercept.finish(.success(pending))
            do { try await release.value() } catch { XCTFail("Fixture barrier failed") }
        })
        try await BridgeFixture.withSession(timing: clock.timing, hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { release.finish(.success(())); work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            clock.advance(seconds: 5)
            XCTAssertEqual(clock.timing.now(), pending.approvalDeadline)
            do { _ = try await session.bridge.approve(pending.approval); XCTFail("Approval at exact deadline accepted") }
            catch let error as BridgeError { XCTAssertEqual(error, .expired) }
            release.finish(.success(()))
            do { _ = try await work.value; XCTFail("Expired request completed") }
            catch let error as BridgeError {
                guard case .timedOut(.approval, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.elapsedNanoseconds, 5_000_000_000)
            }
            let snapshot = await session.bridge.snapshot()
            XCTAssertEqual(snapshot.latestTransfer?.bytesWritten, 0)
            XCTAssertEqual(snapshot.latestTransfer?.elapsedNanoseconds, 5_000_000_000)
            XCTAssertNil(snapshot.pendingIntercept)
        }
    }

    func testCompleteTransmissionWithoutResponseIsNotExecutionSuccess() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let transmitted = MCPIOCompletion<Void>()
        let target = OSAllocatedUnfairLock<(UUID, Int)?>(initialState: nil)
        let hooks = BridgeTestHooks(afterWrite: { id, offset in
            if target.withLock({ $0?.0 == id && $0?.1 == offset }) { transmitted.finish(.success(())) }
        }, pendingPublished: { pending in
            target.withLock { $0 = (pending.approval.requestID, pending.payloadBytes) }
            intercept.finish(.success(pending))
        })
        try await BridgeFixture.withSession(mode: "withhold", hooks: hooks) { session in
            try await session.gate.arm()
            let work = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { work.cancel() }
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            _ = try await session.bridge.approve(pending.approval)
            try await transmitted.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let status = await session.gate.currentStatus
            XCTAssertEqual(status, .locked)
            let cancelled = try await session.bridge.cancel(pending.approval)
            XCTAssertEqual(cancelled.bytesWritten, pending.payloadBytes)
            XCTAssertEqual(cancelled.transmissionStage, .complete)
            XCTAssertFalse(cancelled.hasCorrelatedResponse)
            XCTAssertEqual(cancelled.outcome, .declined)
            do { _ = try await work.value; XCTFail("No response was sent") }
            catch let error as BridgeError {
                guard case .revoked(_, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.transmissionStage, .complete)
                XCTAssertFalse(receipt?.hasCorrelatedResponse ?? true)
            }
        }
    }

    func testActualChunkEventsMatchReceiptNotFixedMetrics() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            let args = Data(("{\"text\":\"" + String(repeating: "b", count: 65_536) + "\"}").utf8)
            let result = try await BridgeFixture.approveNext(session, intercept: intercept, arguments: args)
            let snapshot = await session.bridge.snapshot()
            let chunks = snapshot.events.compactMap { event -> (Int, Int, UInt64)? in
                if case .chunkWritten(let id, let bytes, let total, let elapsed) = event.kind,
                   id == result.receipt.requestID { return (bytes, total, elapsed) }
                return nil
            }
            XCTAssertEqual(chunks.count, result.receipt.writeChunks)
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.0 }, result.receipt.bytesWritten)
            XCTAssertEqual(chunks.last?.1, result.receipt.bytesWritten)
            XCTAssertTrue(chunks.allSatisfy { $0.0 > 0 && $0.0 <= 16_384 && $0.2 <= result.receipt.elapsedNanoseconds })
        }
    }

    func testRemoteJSONRPCAndToolErrorsPreserveCorrelatedEvidence() async throws {
        for mode in ["remoteError", "toolError"] {
            let intercept = MCPIOCompletion<PendingIntercept>()
            let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
            try await BridgeFixture.withSession(mode: mode, hooks: hooks) { session in
                do {
                    _ = try await BridgeFixture.approveNext(session, intercept: intercept)
                    XCTFail("Remote failure reported as success")
                } catch let error as BridgeError {
                    let receipt: BridgeTransferReceipt
                    switch error {
                    case .remoteError(let code, _, let observed): XCTAssertEqual(code, -32602); receipt = observed
                    case .toolError(let observed): receipt = observed
                    default: return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertTrue(receipt.hasCorrelatedResponse)
                    XCTAssertEqual(receipt.transmissionStage, .complete)
                    let status = await session.gate.currentStatus
                    XCTAssertEqual(status, .locked)
                }
            }
        }
    }

    func testOutOfOrderResponsesAreCorrelatedNotFIFO() async throws {
        try await BridgeFixture.withSession(mode: "reverse") { session in
            async let ping = session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            async let list = session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
            let (pingData, listData) = try await (ping, list)
            let pingEnvelope = try XCTUnwrap(try MCPJSONCodec.decode(pingData).object)
            let listEnvelope = try XCTUnwrap(try MCPJSONCodec.decode(listData).object)
            XCTAssertEqual(pingEnvelope["result"], .object([:]))
            XCTAssertNotNil(listEnvelope["result"]?.object?["tools"]?.array)
            XCTAssertNotEqual(pingEnvelope["id"], listEnvelope["id"])
        }
    }

    func testCoalescedNotificationDoesNotStealResponse() async throws {
        try await BridgeFixture.withSession(mode: "notify") { session in
            let data = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTAssertEqual(try MCPJSONCodec.decode(data).object?["result"], .object([:]))
            let snapshot = await session.bridge.snapshot()
            XCTAssertTrue(snapshot.latestTransfer?.hasCorrelatedResponse ?? false)
        }
    }

    func testMalformedInboundFrameFailsWithActualTransferReceipt() async throws {
        try await BridgeFixture.withSession(mode: "malformed") { session in
            do {
                _ = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
                XCTFail("Malformed server frame accepted")
            } catch let error as BridgeError {
                guard case .protocolViolation(_, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.transmissionStage, .complete)
                XCTAssertGreaterThan(receipt?.bytesRead ?? 0, 0)
                XCTAssertFalse(receipt?.hasCorrelatedResponse ?? true)
            }
        }
    }

    func testUnknownAndNonexactResponseIDsFailClosed() async throws {
        for mode in ["wrongID", "lowercaseID"] {
            try await BridgeFixture.withSession(mode: mode) { session in
                do {
                    _ = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
                    XCTFail("Unowned response ID accepted")
                } catch let error as BridgeError {
                    guard case .protocolViolation(_, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                    XCTAssertFalse(receipt?.hasCorrelatedResponse ?? true)
                    XCTAssertEqual(receipt?.transmissionStage, .complete)
                }
            }
        }
    }

    func testInvalidInitializeNeverPublishesAttached() async throws {
        let bridge = ContainerSocketBridge(interlockGate: HardwareInterlockGate(), configuration: BridgeFixture.configuration(mode: "badInit"))
        do { _ = try await bridge.attach(); XCTFail("Unsupported protocol accepted") }
        catch let error as BridgeError {
            guard case .protocolViolation = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let snapshot = await bridge.snapshot()
        XCTAssertFalse(snapshot.events.contains { $0.kind == .connectionChanged(.attached) })
        let receipt = await bridge.detach()
        XCTAssertNotEqual(receipt.outcome, .cleanupIncomplete)
    }

    func testObservationRetentionAndBootstrapHaveExplicitGap() async throws {
        try await BridgeFixture.withSession { session in
            let observation = await session.bridge.observe()
            XCTAssertEqual(observation.snapshot.connectionState, .attached)
            for _ in 0..<140 {
                _ = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            }
            let snapshot = await session.bridge.snapshot(after: observation.snapshot.cursor)
            XCTAssertEqual(snapshot.events.count, BridgeLimits.eventRetention)
            XCTAssertGreaterThan(snapshot.omittedEventCount, 0)
            var iterator = observation.events.makeAsyncIterator()
            let first = await iterator.next()
            XCTAssertGreaterThan(first?.cursor ?? 0, observation.snapshot.cursor + 1)
            await session.bridge.unsubscribe(id: observation.id)
        }
    }

    func testDetachReattachRejectsOldGenerationAndDoesNotInheritRevocation() async throws {
        try await BridgeFixture.withSession { session in
            let detached = await session.bridge.detach()
            XCTAssertEqual(detached.outcome, .detached)
            let replacement = try await session.bridge.attach()
            XCTAssertNotEqual(replacement.generation, session.info.generation)
            session.bridge.revokeAdmissions(scope: .connection(generation: session.info.generation), reason: .windowClosed)
            _ = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            do {
                _ = try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
                XCTFail("Old generation submitted a tool")
            } catch let error as BridgeError { XCTAssertEqual(error, .staleGeneration) }
            let unknown = BridgeApprovalKey(requestID: UUID(), sha256: "unknown", connectionGeneration: replacement.generation)
            do { _ = try await session.bridge.cancel(unknown); XCTFail("Unknown cancel invented counters") }
            catch let error as BridgeError { XCTAssertEqual(error, .staleApproval) }
        }
    }
}
