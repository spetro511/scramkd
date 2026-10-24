import Foundation
import ScramKCore
@testable import ScramKVirtualization
import XCTest

final class ContainerSocketBridgeFaultTests: XCTestCase {
    func testLargePayloadHandlingDoesNotCrash() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            let arguments = Data(("{\"text\":\"" + String(repeating: "A", count: 524_288) + "\"}").utf8)
            let result = try await BridgeFixture.approveNext(session, intercept: intercept, arguments: arguments)
            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(1)))
            XCTAssertEqual(result.receipt.bytesWritten, pending.commandPayload.count)
            XCTAssertGreaterThan(result.receipt.writeChunks, 1)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            XCTAssertEqual(result.receipt.transmissionStage, .complete)
        }
    }

    func testMalformedJSONRPCPayloadHandledGracefully() async throws {
        try await BridgeFixture.withSession { session in
            do {
                _ = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":42,"method":"ping""#.utf8))
                XCTFail("Malformed JSON must not reach stdin")
            } catch let error as BridgeError { XCTAssertEqual(error, .malformedRequest) }
            let active = await session.bridge.isBridgeActive
            XCTAssertTrue(active)
        }
    }

    func testProcessTerminationMidReadHandledGracefully() async throws {
        try await BridgeFixture.withSession(mode: "truncated") { session in
            do {
                _ = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
                XCTFail("Partial response followed by EOF cannot be success")
            } catch let error as BridgeError {
                guard case .endOfStream(let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.transmissionStage, .complete)
                XCTAssertFalse(receipt?.hasCorrelatedResponse ?? true)
                XCTAssertGreaterThan(receipt?.bytesRead ?? 0, 0)
            }
        }
    }

    func testBridgeIsInactiveAfterTerminate() async throws {
        try await BridgeFixture.withSession { session in
            let before = await session.bridge.isBridgeActive
            XCTAssertTrue(before)
            await session.bridge.terminateBridge()
            let after = await session.bridge.isBridgeActive
            XCTAssertFalse(after)
            let snapshot = await session.bridge.snapshot()
            XCTAssertEqual(snapshot.connectionState, .detached)
        }
    }

    func testHighRiskCommandBlocksWhenGateArmed() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            try await session.gate.arm()
            let task = Task { try await session.bridge.submitTool(name: "dangerous_action", argumentsJSON: Data("{}".utf8), generation: session.info.generation) }
            defer { task.cancel() }
            let request = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let snapshot = await session.bridge.snapshot()
            XCTAssertEqual(snapshot.pendingIntercept?.approval, request.approval)
            XCTAssertEqual(snapshot.pendingIntercept?.phase, .awaitingApproval)
            let receipt = try await session.bridge.cancel(request.approval)
            XCTAssertEqual(receipt.bytesWritten, 0)
            XCTAssertEqual(receipt.transmissionStage, .none)
            do { _ = try await task.value; XCTFail("No keyed approval occurred") }
            catch let error as BridgeError {
                guard case .revoked(.operatorDeclined, _) = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }
}
