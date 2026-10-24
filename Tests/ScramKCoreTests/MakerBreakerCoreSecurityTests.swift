import Foundation
import os
import XCTest
@testable import ScramKCore

final class MakerBreakerCoreSecurityTests: XCTestCase {
    // MARK: - MB-01: PermissivePermit Request-Scoped Capability Token

    func testPermissivePermitRejectsIssuanceWhenEmergencyAbortActive() async throws {
        let gate = HardwareInterlockGate()
        let reqID = UUID()
        let t0 = ContinuousClock.now

        // Issuing while .emergencyAbort must fail with emergencyAbortActive
        await gate.tripEmergencyAbort(reason: "MB01_TEST_ABORT")
        do {
            _ = try await gate.issuePermissivePermit(forRequestID: reqID, ttl: .seconds(5), now: t0)
            XCTFail("Aborted gate must not issue a permissive permit")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .emergencyAbortActive)
        }

        // Consuming while .emergencyAbort must also fail with emergencyAbortActive
        try await gate.resetEmergencyAbort()
        try await gate.arm()
        let permit = try await gate.issuePermissivePermit(forRequestID: reqID, ttl: .seconds(5), now: t0)
        await gate.tripEmergencyAbort(reason: "MB01_CONSUME_ABORT")
        do {
            try await gate.consumePermissivePermit(permit, forRequestID: reqID, now: t0)
            XCTFail("Aborted gate must not allow consuming a permissive permit")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .emergencyAbortActive)
        }
    }

    func testPermissivePermitSingleConsumptionAndAntiReplay() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()

        let reqA = UUID()
        let t0 = ContinuousClock.now
        let permit = try await gate.issuePermissivePermit(forRequestID: reqA, ttl: .seconds(5), now: t0)

        let grantedStatus = await gate.currentStatus
        XCTAssertEqual(grantedStatus, .permissiveGranted)

        // First consumption with matching requestID succeeds and relocks gate
        try await gate.consumePermissivePermit(permit, forRequestID: reqA, now: t0.advanced(by: .seconds(1)))
        let afterConsumeStatus = await gate.currentStatus
        XCTAssertEqual(afterConsumeStatus, .locked)

        // Replay of consumed permit must fail closed
        do {
            try await gate.consumePermissivePermit(permit, forRequestID: reqA, now: t0.advanced(by: .seconds(1)))
            XCTFail("Replayed permit must be rejected")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        }

        // Re-arming and granting bare permissive still rejects the stale permit from an earlier stateVersion
        try await gate.arm()
        try await gate.grantPermissive()
        do {
            try await gate.consumePermissivePermit(permit, forRequestID: reqA, now: t0.advanced(by: .seconds(2)))
            XCTFail("Stale permit from prior stateVersion must be rejected even if gate is permissiveGranted")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        }
    }

    func testPermissivePermitRejectsCrossRequestHijackAndForgedFields() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()

        let reqA = UUID()
        let reqB = UUID()
        let t0 = ContinuousClock.now
        let permit = try await gate.issuePermissivePermit(forRequestID: reqA, ttl: .seconds(5), now: t0)

        // Request B attempting to consume Request A's permit must be rejected
        do {
            try await gate.consumePermissivePermit(permit, forRequestID: reqB, now: t0.advanced(by: .seconds(1)))
            XCTFail("Cross-request permit hijack must fail")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        }

        // Forged permitID with matching requestID must be rejected
        let forgedPermitID = PermissivePermit(
            permitID: UUID(),
            requestID: reqA,
            issuedStateVersion: permit.issuedStateVersion,
            expiresAt: permit.expiresAt
        )
        do {
            try await gate.consumePermissivePermit(forgedPermitID, forRequestID: reqA, now: t0.advanced(by: .seconds(1)))
            XCTFail("Forged permitID must fail")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        }

        // Forged stateVersion with matching permitID and requestID must be rejected
        let forgedStateVersion = PermissivePermit(
            permitID: permit.permitID,
            requestID: reqA,
            issuedStateVersion: permit.issuedStateVersion &+ 1,
            expiresAt: permit.expiresAt
        )
        do {
            try await gate.consumePermissivePermit(forgedStateVersion, forRequestID: reqA, now: t0.advanced(by: .seconds(1)))
            XCTFail("Forged issuedStateVersion must fail")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .gateLocked)
        }

        // Legitimate Request A permit remains valid and consumable once
        try await gate.consumePermissivePermit(permit, forRequestID: reqA, now: t0.advanced(by: .seconds(1)))
        let finalStatus = await gate.currentStatus
        XCTAssertEqual(finalStatus, .locked)
    }

    func testPermissivePermitExactExpirationRelocksGateAndThrowsTimedOut() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()

        let reqA = UUID()
        let t0 = ContinuousClock.now
        let permit = try await gate.issuePermissivePermit(forRequestID: reqA, ttl: .seconds(5), now: t0)

        // At exact expiration boundary (t0 + 5s), permit must fail closed with timedOut and relock gate
        do {
            try await gate.consumePermissivePermit(permit, forRequestID: reqA, now: t0.advanced(by: .seconds(5)))
            XCTFail("Expired permit at exact TTL boundary must fail closed")
        } catch let error as HardwareInterlockError {
            XCTAssertEqual(error, .timedOut)
        }

        let statusAfterExpiry = await gate.currentStatus
        let history = await gate.transitionHistory
        XCTAssertEqual(statusAfterExpiry, .locked)
        XCTAssertEqual(history.last?.reason, "PERMISSIVE_PERMIT_EXPIRED")
    }

    func testConcurrentPermissivePermitConsumptionAllowsExactlyOneWinner() async throws {
        for _ in 0..<25 {
            let gate = HardwareInterlockGate()
            try await gate.arm()
            let reqID = UUID()
            let t0 = ContinuousClock.now
            let permit = try await gate.issuePermissivePermit(forRequestID: reqID, ttl: .seconds(5), now: t0)

            let contenders = 16
            let winners = OSAllocatedUnfairLock(initialState: 0)
            let rejections = OSAllocatedUnfairLock(initialState: 0)

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<contenders {
                    group.addTask {
                        do {
                            try await gate.consumePermissivePermit(permit, forRequestID: reqID, now: t0.advanced(by: .seconds(1)))
                            winners.withLock { $0 += 1 }
                        } catch is HardwareInterlockError {
                            rejections.withLock { $0 += 1 }
                        } catch {
                            XCTFail("Unexpected error: \(error)")
                        }
                    }
                }
                await group.waitForAll()
            }

            XCTAssertEqual(winners.withLock { $0 }, 1, "Exactly one contender may consume a single-use permit")
            XCTAssertEqual(rejections.withLock { $0 }, contenders - 1)
            let finalStatus = await gate.currentStatus
            XCTAssertEqual(finalStatus, .locked)
        }
    }

    // MARK: - MB-06: ActiveHoldPolicy Temporal Bounds

    func testActiveHoldPolicyDefaultAndCustomInvariants() {
        let policy = ActiveHoldPolicy()
        XCTAssertEqual(policy.initialWindow, .seconds(5))
        XCTAssertEqual(policy.maxHoldDuration, .seconds(120))
        XCTAssertEqual(policy.criticalReadGuardDuration, .milliseconds(1500))

        let custom = ActiveHoldPolicy(
            initialWindow: .seconds(10),
            maxHoldDuration: .seconds(90),
            criticalReadGuardDuration: .milliseconds(2000)
        )
        XCTAssertEqual(custom.initialWindow, .seconds(10))
        XCTAssertEqual(custom.maxHoldDuration, .seconds(90))
        XCTAssertEqual(custom.criticalReadGuardDuration, .milliseconds(2000))
        XCTAssertNotEqual(policy, custom)
    }
}
