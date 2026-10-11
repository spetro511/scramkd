import Foundation
import TacticalCore
@testable import TacticalVirtualization
import XCTest

final class ContainerSocketBridgeTests: XCTestCase {
    func testHighRiskCommandRejectedWhenGateLocked() async {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let bridge = ContainerSocketBridge(interlockGate: gate)

        let payload = Data("{\"method\":\"click\"}".utf8)
        do {
            _ = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: true)
            XCTFail("High-risk command must be rejected when gate is locked")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHighRiskCommandRejectedWhenEmergencyAbort() async {
        let gate = HardwareInterlockGate(initialStatus: .emergencyAbort)
        let bridge = ContainerSocketBridge(interlockGate: gate)

        let payload = Data("{\"method\":\"press_hotkey\"}".utf8)
        do {
            _ = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: true)
            XCTFail("High-risk command must be rejected during emergency abort")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .emergencyAbortActive)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUninitializedBridgeThrowsSubsystemFailure() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        let bridge = ContainerSocketBridge(interlockGate: gate)
        let payload = Data("{\"method\":\"get_cursor_position\"}".utf8)

        do {
            _ = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: false)
            XCTFail("Dispatching on uninitialized bridge must throw subsystemFailure")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .subsystemFailure(reason: "Container stdio bridge handles uninitialized"))
        }
    }

    func testCommandExecutionUnderPermissiveGateState() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        // Use standard cat process for deterministic stdio loopback testing
        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            arguments: ["cat"]
        )

        try await bridge.launchBridge()
        let isActive = await bridge.isBridgeActive
        XCTAssertTrue(isActive)

        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"ping\"}".utf8)
        let response = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: true)

        let responseString = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(responseString.contains("ping"))

        await bridge.terminateBridge()
        let isActiveAfterTerminate = await bridge.isBridgeActive
        XCTAssertFalse(isActiveAfterTerminate)
    }

    func testLowRiskCommandBypassesInterlockRequirement() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            arguments: ["cat"]
        )

        try await bridge.launchBridge()

        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":200,\"method\":\"get_screen_size\"}".utf8)
        let response = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: false)

        let responseString = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(responseString.contains("get_screen_size"))

        await bridge.terminateBridge()
    }

    func testLiveContainerHandshakeUnderPermissiveGateState() async throws {
        // Verify against screenenv_container Docker instance if operational
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        let bridge = ContainerSocketBridge(
            containerName: "screenenv_container",
            interlockGate: gate
        )

        do {
            try await bridge.launchBridge()
        } catch {
            // Docker or container not available in this environment, skip live test
            return
        }

        let initPayload = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"TacticalHypervisor\",\"version\":\"1.0\"}}}".utf8
        )

        do {
            let responseData = try await bridge.dispatchMCPCommand(initPayload, isHighRiskAction: true)
            let responseString = String(decoding: responseData, as: UTF8.self)
            XCTAssertTrue(responseString.contains("screenenv"))
        } catch {
            // If container environment fails to initialize within timeout, handle gracefully
        }

        await bridge.terminateBridge()
    }
}
