import Foundation
import ScramKCore
import ScramKVirtualization
import XCTest
@testable import ScramKUI

@MainActor
final class MakerBreakerUISecurityTests: XCTestCase {
    // MARK: - MB-07: SemanticInterceptInspector Fail-Closed Classification & Provenance Truth

    func testSemanticInterceptInspectorClassifiesCriticalPayloadAndFailClosedMalformedJSON() {
        let validDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        // 1. Critical container creation payload with Privileged=true and Binds
        let criticalJSON = #"""
        {
          "jsonrpc": "2.0",
          "id": "req-1",
          "method": "tools/call",
          "params": {
            "name": "docker_create",
            "arguments": {
              "HostConfig": {
                "Privileged": true,
                "Binds": ["/:/host:rw"],
                "NetworkMode": "host"
              }
            }
          }
        }
        """#
        let criticalSummary = SemanticInterceptInspector.inspect(
            jsonString: criticalJSON,
            sha256: validDigest,
            toolHook: "tools/call:docker_create",
            status: .armed,
            securityProfile: .strictAirgap,
            isHoldActive: false,
            isCriticalReadGuardSatisfied: false,
            originTrust: .appProcess,
            originPID: 4242,
            originUID: 501
        )
        XCTAssertFalse(criticalSummary.isFailClosedMalformed)
        XCTAssertEqual(criticalSummary.riskLevel, .critical)
        XCTAssertFalse(criticalSummary.isCriticalReadGuardSatisfied)
        XCTAssertEqual(criticalSummary.provenanceBadge, .verifiedPID)
        XCTAssertEqual(criticalSummary.provenanceBadge.rawValue, "VERIFIED PID")
        XCTAssertTrue(criticalSummary.fieldDiffs.contains { $0.riskLevel == .critical })

        // Satisfying critical read guard updates read guard status
        let guardedSummary = SemanticInterceptInspector.inspect(
            jsonString: criticalJSON,
            sha256: validDigest,
            toolHook: "tools/call:docker_create",
            status: .armed,
            securityProfile: .strictAirgap,
            isHoldActive: true,
            isCriticalReadGuardSatisfied: true,
            originTrust: .appProcess,
            originPID: 4242,
            originUID: 501
        )
        XCTAssertTrue(guardedSummary.isCriticalReadGuardSatisfied)
        XCTAssertEqual(guardedSummary.criticalReadGuardBadge, "1.5s DWELL GUARD READY (1500ms)")

        // 2. Malformed / truncated JSON must fail closed to .critical
        let malformedSummary = SemanticInterceptInspector.inspect(
            jsonString: #"{"jsonrpc":"2.0","params":{"truncated":true"#,
            sha256: validDigest,
            toolHook: "tools/call:unknown",
            status: .armed,
            originTrust: .claimed
        )
        XCTAssertTrue(malformedSummary.isFailClosedMalformed)
        XCTAssertEqual(malformedSummary.riskLevel, .critical)
        XCTAssertEqual(malformedSummary.provenanceBadge, .claimedUnverified)
        XCTAssertEqual(malformedSummary.provenanceBadge.rawValue, "CLAIMED (UNVERIFIED)")

        // 3. Duplicate JSON key (including Unicode-escaped duplicate) in intercept payload must fail closed to .critical
        let duplicateKeySummary = SemanticInterceptInspector.inspect(
            jsonString: #"{"params":{"\u0050rivileged":false,"Privileged":true}}"#,
            sha256: validDigest,
            toolHook: "tools/call:test",
            status: .armed,
            originTrust: .unknown
        )
        XCTAssertTrue(duplicateKeySummary.isFailClosedMalformed)
        XCTAssertEqual(duplicateKeySummary.riskLevel, .critical)
        XCTAssertEqual(duplicateKeySummary.provenanceBadge, .unknown)
        XCTAssertEqual(duplicateKeySummary.provenanceBadge.rawValue, "UNKNOWN")
    }

    func testF12NotImplementedTruthfulnessAndInspectorDrawerHoldLifecycle() async {
        let gate = HardwareInterlockGate()
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()

        // Verify control strip badges explicitly mark F12 as NOT IMPLEMENTED
        XCTAssertTrue(SemanticInterceptInspector.defaultControlStripBadges.contains("F12 (NOT IMPLEMENTED)"))
        XCTAssertEqual(SemanticInterceptInspector.defaultControlStripBadges, [
            "SPACE (GRANT)",
            "HOLD (INSPECT)",
            "ESC (ABORT)",
            "F12 (NOT IMPLEMENTED)"
        ])

        // Verify invoking forceAirgapDump reports truthful F12 NOT IMPLEMENTED status
        await controller.forceAirgapDump()
        XCTAssertEqual(controller.lastCommandResult, "F12 NOT IMPLEMENTED")
        XCTAssertTrue(controller.auditRows.contains {
            $0.subsystem == "COMMAND" && $0.description == "F12 NOT IMPLEMENTED"
        })

        // Verify expanding/collapsing inspector drawer toggles state deterministically
        XCTAssertFalse(controller.isInspectorDrawerExpanded)
        XCTAssertFalse(controller.isAuthorizationHoldActive)

        _ = await controller.expandInspectorDrawer()
        XCTAssertTrue(controller.isInspectorDrawerExpanded)

        _ = await controller.collapseInspectorDrawer()
        XCTAssertFalse(controller.isInspectorDrawerExpanded)
        XCTAssertFalse(controller.isAuthorizationHoldActive)

        await controller.stop()
    }

    // MARK: - UX-03: APFS Path Normalization & Field Limit Fail-Closed Escalation

    func testSemanticInspectorAPFSPathNormalizationAndFieldLimitFailClosed() {
        let validDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        // 1. APFS Case Insensitivity: uppercase path "/ETC/sudoers" must be flagged as .critical
        let upperPathJSON = #"""
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "tools/call",
          "params": {
            "name": "read_file",
            "arguments": {
              "path": "/ETC/sudoers"
            }
          }
        }
        """#
        let upperPathSummary = SemanticInterceptInspector.inspect(
            jsonString: upperPathJSON,
            sha256: validDigest,
            toolHook: "tools/call:read_file",
            status: .armed,
            securityProfile: .strictAirgap
        )
        XCTAssertEqual(upperPathSummary.riskLevel, .critical)
        XCTAssertTrue(upperPathSummary.fieldDiffs.contains { $0.riskLevel == .critical })

        // 2. Traversal Normalization: "/tmp/../etc/shadow" must standardize to "/etc/shadow" and classify as .critical
        let traversalJSON = #"""
        {
          "jsonrpc": "2.0",
          "id": 2,
          "method": "tools/call",
          "params": {
            "name": "read_file",
            "arguments": {
              "path": "/tmp/../etc/shadow"
            }
          }
        }
        """#
        let traversalSummary = SemanticInterceptInspector.inspect(
            jsonString: traversalJSON,
            sha256: validDigest,
            toolHook: "tools/call:read_file",
            status: .armed,
            securityProfile: .strictAirgap
        )
        XCTAssertEqual(traversalSummary.riskLevel, .critical)
        XCTAssertTrue(traversalSummary.fieldDiffs.contains { $0.riskLevel == .critical })

        // 3. >64 fields limit: 65 benign fields must fail-closed to .critical due to field evaluation limit
        var dict: [String: String] = [:]
        for i in 0..<65 {
            dict["benign_key_\(i)"] = "benign_val_\(i)"
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "benign_tool",
                "arguments": dict
            ]
        ])
        let sixtyFiveJSON = String(data: data, encoding: .utf8)!
        let fieldCapSummary = SemanticInterceptInspector.inspect(
            jsonString: sixtyFiveJSON,
            sha256: validDigest,
            toolHook: "tools/call:benign_tool",
            status: .armed,
            securityProfile: .strictAirgap
        )
        XCTAssertEqual(fieldCapSummary.riskLevel, .critical)
        XCTAssertEqual(fieldCapSummary.fieldDiffs.count, 64)
        XCTAssertTrue(fieldCapSummary.riskReasons.contains { $0.contains("limit exceeded; fail-closed to CRITICAL") })
    }

    // MARK: - UX-01 & UX-06: Simulated Intercept Lifecycle & Dwell Guard Timing

    func testCriticalDwellGuardDurationAndSimulatedInterceptLifecycle() async {
        let gate = HardwareInterlockGate(initialStatus: .armed)
        let controller = ConsoleStateController(interlockGate: gate)
        await controller.start()

        // 1. Initially no simulated intercept
        XCTAssertNil(controller.simulatedIntercept)
        XCTAssertNil(controller.currentSemanticInterceptSummary)

        // 2. Simulate intercept preview
        let intercept = controller.simulateInterceptPreview()
        XCTAssertNotNil(controller.simulatedIntercept)
        XCTAssertEqual(controller.simulatedIntercept?.toolHook, "bash")
        XCTAssertEqual(intercept.phase, .awaitingApproval)

        // 3. Before hold is active, critical read guard is not satisfied
        let initialSummary = controller.currentSemanticInterceptSummary
        XCTAssertNotNil(initialSummary)
        XCTAssertEqual(initialSummary?.riskLevel, .critical)
        XCTAssertFalse(initialSummary?.isCriticalReadGuardSatisfied ?? true)

        // 4. Begin hold via expanding drawer
        _ = await controller.expandInspectorDrawer()
        XCTAssertTrue(controller.isAuthorizationHoldActive)
        XCTAssertNotNil(controller.holdStartedAt)

        // Immediately upon hold start, elapsed time is < 1.5s, so dwell guard is NOT satisfied
        let holdingSummary = controller.currentSemanticInterceptSummary
        XCTAssertFalse(holdingSummary?.isCriticalReadGuardSatisfied ?? true)

        // 5. Clear simulated intercept flushes all state
        controller.clearSimulatedIntercept()
        XCTAssertNil(controller.simulatedIntercept)
        XCTAssertNil(controller.holdStartedAt)
        XCTAssertFalse(controller.isAuthorizationHoldActive)
        XCTAssertNil(controller.currentSemanticInterceptSummary)

        await controller.stop()
    }
}
