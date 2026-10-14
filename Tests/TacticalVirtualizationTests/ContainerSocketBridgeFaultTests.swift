import Foundation
import TacticalCore
@testable import TacticalVirtualization
import XCTest

/// Adversarial I/O fault injection and container boundary stress tests for ContainerSocketBridge.
final class ContainerSocketBridgeFaultTests: XCTestCase {

    // MARK: - a) Large Payload Stress

    /// Writes a 1MB+ payload via a cat-backed bridge and verifies no crash or unhandled exception.
    func testLargePayloadHandlingDoesNotCrash() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            arguments: ["cat"]
        )
        try await bridge.launchBridge()

        // Build a 1 MB payload of repeated 'A' bytes (0x41).
        let oneMegabyte = 1_024 * 1_024
        let largePayload = Data(repeating: 0x41, count: oneMegabyte)

        do {
            // We don't assert on response content — only that the call terminates
            // without crashing or propagating an unhandled raw POSIX/Cocoa error.
            _ = try await bridge.dispatchMCPCommand(largePayload, isHighRiskAction: false)
        } catch let error as HardwareInterlockError {
            // Broken-pipe or any I/O fault must be wrapped in subsystemFailure, not naked.
            if case .subsystemFailure = error {
                // Accepted: bridge correctly wrapped the I/O fault.
            } else {
                XCTFail("Expected subsystemFailure, got HardwareInterlockError: \(error)")
            }
        } catch {
            // Any other error type means the bridge leaked a raw Foundation/POSIX error.
            XCTFail("Large payload write leaked raw error: \(error)")
        }

        await bridge.terminateBridge()
    }

    // MARK: - b) Malformed JSON-RPC Transport Resilience

    /// Injects a truncated JSON-RPC frame (missing closing brace) through the transport
    /// and verifies the bridge does not crash or hang — it is purely a transport layer.
    func testMalformedJSONRPCPayloadHandledGracefully() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            arguments: ["cat"]
        )
        try await bridge.launchBridge()

        // Deliberately malformed: missing closing brace, truncated mid-field.
        let malformed = Data("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"ping\"".utf8)

        do {
            let response = try await bridge.dispatchMCPCommand(malformed, isHighRiskAction: false)
            // Transport layer must survive corrupt frames; content is whatever cat echoes back.
            // We only assert that the call returns (possibly with the corrupt echo) without crashing.
            let _ = response
        } catch let error as HardwareInterlockError {
            if case .subsystemFailure = error {
                // Acceptable — I/O fault wrapped correctly.
            } else {
                XCTFail("Unexpected HardwareInterlockError: \(error)")
            }
        } catch {
            XCTFail("Transport failed to contain malformed-frame fault: \(error)")
        }

        await bridge.terminateBridge()
    }

    // MARK: - c) Process Termination Mid-Read

    /// Launches a bridge backed by a short-lived `echo` process, waits for it to
    /// exit, then attempts a dispatch and verifies the error is contained.
    func testProcessTerminationMidReadHandledGracefully() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        // `echo hello` exits almost immediately after writing its output.
        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )
        try await bridge.launchBridge()

        // Give the echo process time to exit naturally.
        try await Task.sleep(for: .milliseconds(200))

        let payload = Data("{\"method\":\"post_exit_dispatch\"}".utf8)
        do {
            _ = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: false)
            // Dispatching after exit may succeed (empty data returned) or throw —
            // both outcomes are acceptable as long as no unhandled crash propagates.
        } catch let error as HardwareInterlockError {
            if case .subsystemFailure = error {
                // Correct: broken-pipe/closed-handle wrapped as subsystemFailure.
            } else {
                XCTFail("Expected subsystemFailure after process exit, got: \(error)")
            }
        } catch {
            // Any raw POSIX/CocoaError leaking here is a test failure — it must be wrapped.
            XCTFail("Post-exit dispatch leaked raw error: \(error)")
        }

        await bridge.terminateBridge()
    }

    // MARK: - d) Bridge Inactive After Terminate

    /// Verifies that `isBridgeActive` transitions from true → false after `terminateBridge()`.
    func testBridgeIsInactiveAfterTerminate() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        try await gate.grantPermissive()

        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            arguments: ["cat"]
        )

        try await bridge.launchBridge()

        let activeBeforeTerminate = await bridge.isBridgeActive
        XCTAssertTrue(activeBeforeTerminate, "Bridge must be active immediately after launchBridge()")

        await bridge.terminateBridge()

        let activeAfterTerminate = await bridge.isBridgeActive
        XCTAssertFalse(activeAfterTerminate, "Bridge must be inactive after terminateBridge()")
    }

    // MARK: - e) High-Risk Command Blocks When Gate Armed

    /// Confirms that `dispatchMCPCommand(_:isHighRiskAction:true)` suspends indefinitely
    /// when the gate is in `.armed` state (no permissive granted), and times out
    /// via the `requestPermissive(timeout:)` path, surfacing `.timedOut`.
    func testHighRiskCommandBlocksWhenGateArmed() async throws {
        let gate = HardwareInterlockGate()
        // Arm but do NOT grant permissive — gate remains in armed/blocking state.
        try await gate.arm()

        let bridge = ContainerSocketBridge(
            interlockGate: gate,
            arguments: ["cat"]
        )
        try await bridge.launchBridge()

        let payload = Data("{\"method\":\"dangerous_action\"}".utf8)

        // We override the bridge's built-in 5-second timeout by wrapping in a
        // short-lived task that cancels itself, triggering taskCancelled or timedOut.
        // More precisely: the armed-gate requestPermissive(timeout:) path in
        // dispatchMCPCommand uses .seconds(5); we race it with a 50 ms sleep
        // via a task group so the test completes quickly.
        do {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await bridge.dispatchMCPCommand(payload, isHighRiskAction: true)
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(50))
                    throw HardwareInterlockError.timedOut
                }
                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
            XCTFail("High-risk command must not complete when gate is armed and no permissive granted")
        } catch let error as HardwareInterlockError {
            // Either timedOut (from our racing task) or taskCancelled (from group cancellation)
            // are acceptable — both confirm the bridge is correctly blocked by the interlock.
            switch error {
            case .timedOut, .taskCancelled:
                break // ✓ interlock is blocking as expected
            default:
                XCTFail("Expected timedOut or taskCancelled, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-HardwareInterlockError: \(error)")
        }

        await bridge.terminateBridge()
    }
}
