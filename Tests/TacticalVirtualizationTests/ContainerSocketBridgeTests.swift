import Foundation
import TacticalCore
@testable import TacticalVirtualization
import XCTest

final class ContainerSocketBridgeTests: XCTestCase {
    func testHighRiskCommandRejectedWhenGateLocked() async throws {
        try await BridgeFixture.withSession { session in
            do {
                _ = try await session.bridge.submitTool(name: "click", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
                XCTFail("Locked gate must reject every tool")
            } catch let error as BridgeError {
                guard case .gateRejected(.gateLocked, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.bytesWritten, 0)
                XCTAssertEqual(receipt?.transmissionStage, BridgeTransmissionStage.none)
            }
        }
    }

    func testHighRiskCommandRejectedWhenEmergencyAbort() async throws {
        try await BridgeFixture.withSession { session in
            await session.gate.tripEmergencyAbort()
            do {
                _ = try await session.bridge.submitTool(name: "press_hotkey", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
                XCTFail("Abort must reject every tool")
            } catch let error as BridgeError {
                guard case .gateRejected(.emergencyAbortActive, let receipt) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(receipt?.bytesWritten, 0)
            }
        }
    }

    func testUninitializedBridgeThrowsSubsystemFailure() async throws {
        let bridge = ContainerSocketBridge(interlockGate: HardwareInterlockGate(), configuration: BridgeFixture.configuration())
        do {
            _ = try await bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTFail("Detached bridge must reject dispatch")
        } catch let error as BridgeError { XCTAssertEqual(error, .detached) }
    }

    func testCommandExecutionUnderPermissiveGateState() async throws {
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })
        try await BridgeFixture.withSession(hooks: hooks) { session in
            let result = try await BridgeFixture.approveNext(session, intercept: intercept)
            XCTAssertEqual(result.receipt.transmissionStage, .complete)
            XCTAssertTrue(result.receipt.hasCorrelatedResponse)
            XCTAssertEqual(result.receipt.outcome, .responseReceived)
            XCTAssertGreaterThan(result.receipt.bytesWritten, 0)
            XCTAssertGreaterThan(result.receipt.bytesRead, 0)
            let status = await session.gate.currentStatus
            XCTAssertEqual(status, .locked)
        }
    }

    func testLowRiskCommandBypassesInterlockRequirement() async throws {
        // Only exact metadata schemas are exempt; tool names are never risk labels.
        try await BridgeFixture.withSession { session in
            let data = try await session.bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":200,"method":"tools/list","params":{}}"#.utf8))
            let response = try XCTUnwrap(try MCPJSONCodec.decode(data).object)
            XCTAssertNotNil(response["result"]?.object?["tools"]?.array)
            let status = await session.gate.currentStatus
            XCTAssertEqual(status, .locked)
            let snapshot = await session.bridge.snapshot()
            XCTAssertNil(snapshot.latestTransfer?.approval)
            XCTAssertNil(snapshot.pendingIntercept)
        }
    }

    /// Separate live acceptance only. Infrastructure/protocol failures throw; no
    /// catch-return or swallowed initialization errors can produce a green test.
    func testLiveContainerHandshakeUnderPermissiveGateState() async throws {
        let bridge = ContainerSocketBridge(interlockGate: HardwareInterlockGate())
        do {
            let info = try await bridge.attach()
            XCTAssertTrue(BridgeLimits.supportedProtocols.contains(info.protocolVersion))
            XCTAssertFalse(info.advertisedName.isEmpty)
            XCTAssertFalse(info.advertisedVersion.isEmpty)
            let snapshot = await bridge.snapshot()
            XCTAssertEqual(snapshot.connectionState, .attached)
            XCTAssertEqual(snapshot.serverInfo, info)
            if await bridge.advertisesTools {
                let data = try await bridge.dispatchMCPCommand(Data(#"{"jsonrpc":"2.0","id":"live-catalog","method":"tools/list"}"#.utf8))
                let envelope = try XCTUnwrap(try MCPJSONCodec.decode(data).object)
                XCTAssertEqual(envelope["jsonrpc"], .string("2.0"))
                XCTAssertNotNil(envelope["id"]?.string.flatMap(UUID.init(uuidString:)))
                XCTAssertNotNil(envelope["result"]?.object?["tools"]?.array)
            }
            let receipt = await bridge.detach()
            XCTAssertEqual(receipt.outcome, .detached)
        } catch {
            let receipt = await bridge.detach()
            XCTAssertNotEqual(receipt.outcome, .cleanupIncomplete)
            throw error
        }
    }
}
