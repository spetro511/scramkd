import Foundation
import os
import ScramKCore
import XCTest
@testable import ScramKVirtualization

final class MakerBreakerVirtualizationSecurityTests: XCTestCase {
    // MARK: - MB-02: ContainerCreationPolicy Fail-Closed JSON Inspection

    func testContainerCreationPolicyAcceptsStrictAirgapCompliantPayload() throws {
        let validJSON = #"""
        {
          "Image": "scramk-runtime:local",
          "HostConfig": {
            "Privileged": false,
            "NetworkMode": "none",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"],
            "CapAdd": []
          }
        }
        """#
        XCTAssertNoThrow(try ContainerCreationPolicy.inspectContainerCreatePayload(
            Data(validJSON.utf8),
            profile: .strictAirgap
        ))
    }

    func testContainerCreationPolicyRejectsPrivilegedNetworkHostBindsAndCaps() {
        let privilegedPayload = #"""
        {
          "HostConfig": {
            "Privileged": true,
            "NetworkMode": "none",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(privilegedPayload.utf8))) { error in
            XCTAssertEqual(
                error as? ContainerCreationPolicyError,
                .forbiddenDirective(key: "privileged", detail: "Privileged container execution is forbidden.")
            )
        }

        let hostNetworkPayload = #"""
        {
          "HostConfig": {
            "Privileged": false,
            "NetworkMode": "host",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(hostNetworkPayload.utf8), profile: .strictAirgap)) { error in
            guard case .forbiddenDirective(let key, _) = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected forbiddenDirective for NetworkMode=host, got \(error)")
            }
            XCTAssertEqual(key, "networkmode")
        }

        let bindsPayload = #"""
        {
          "HostConfig": {
            "Privileged": false,
            "NetworkMode": "none",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"],
            "Binds": ["/:/host:rw"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(bindsPayload.utf8))) { error in
            guard case .forbiddenDirective(let key, _) = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected forbiddenDirective for Binds, got \(error)")
            }
            XCTAssertEqual(key, "binds")
        }

        let writableRootfsPayload = #"""
        {
          "HostConfig": {
            "Privileged": false,
            "NetworkMode": "none",
            "ReadonlyRootfs": false,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(writableRootfsPayload.utf8))) { error in
            guard case .forbiddenDirective(let key, _) = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected forbiddenDirective for ReadonlyRootfs=false, got \(error)")
            }
            XCTAssertEqual(key, "readonlyrootfs")
        }

        let capAddPayload = #"""
        {
          "HostConfig": {
            "Privileged": false,
            "NetworkMode": "none",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"],
            "CapAdd": ["SYS_ADMIN"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(capAddPayload.utf8))) { error in
            guard case .forbiddenDirective(let key, _) = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected forbiddenDirective for CapAdd, got \(error)")
            }
            XCTAssertEqual(key, "capadd")
        }

        let missingRequiredDirectives = #"""
        {
          "Image": "alpine:latest",
          "HostConfig": {
            "Privileged": false
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(missingRequiredDirectives.utf8), profile: .strictAirgap)) { error in
            guard case .missingRequiredDirective = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected missingRequiredDirective, got \(error)")
            }
        }
    }

    func testContainerCreationPolicyRejectsDuplicateCanonicalKeysUnicodeSmugglingAndExcessiveDepth() {
        // Case-variant duplicate key smuggling: Privileged: true followed by privileged: false
        let duplicateCaseVariant = #"""
        {
          "HostConfig": {
            "Privileged": true,
            "privileged": false,
            "NetworkMode": "none",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(duplicateCaseVariant.utf8))) { error in
            XCTAssertEqual(error as? ContainerCreationPolicyError, .duplicateCanonicalKey("privileged"))
        }

        // Unicode escape duplicate key smuggling: \u0050rivileged vs Privileged
        let unicodeSmuggledDuplicate = #"""
        {
          "HostConfig": {
            "\u0050rivileged": true,
            "Privileged": false,
            "NetworkMode": "none",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(unicodeSmuggledDuplicate.utf8))) { error in
            XCTAssertEqual(error as? ContainerCreationPolicyError, .duplicateCanonicalKey("privileged"))
        }

        // Excessive JSON nesting depth (> 32)
        let deepPrefix = String(repeating: #"{"a":"#, count: 35)
        let deepSuffix = String(repeating: "}", count: 35)
        let deepPayload = deepPrefix + "1" + deepSuffix
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(Data(deepPayload.utf8))) { error in
            XCTAssertEqual(error as? ContainerCreationPolicyError, .nestingDepthExceeded(maxDepth: 32))
        }
    }

    // MARK: - MB-03: BridgeOneShot Cancellation & Single-Consumer Race Safety

    func testBridgeOneShotCancellationClearsContinuationAndPreventsLateDoubleResume() async throws {
        let registered = MCPIOCompletion<Void>()
        let oneShot = BridgeOneShot<Int>(onConsumerRegistered: {
            registered.finish(.success(()))
        })

        let waiter = Task {
            try await withTaskCancellationHandler {
                try await oneShot.value()
            } onCancel: {
                _ = oneShot.finish(.failure(CancellationError()))
            }
        }

        try await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Cancelled BridgeOneShot consumer must throw CancellationError")
        } catch is CancellationError {
            // Expected fail-closed cancellation
        }

        // Subsequent finish after cancellation must return false and never double-resume
        XCTAssertFalse(oneShot.finish(.success(99)))
    }

    func testBridgeOneShotConcurrentCancelVsFinishStress() async {
        for iteration in 0..<50 {
            let registered = MCPIOCompletion<Void>()
            let oneShot = BridgeOneShot<Int>(onConsumerRegistered: {
                registered.finish(.success(()))
            })
            let waiter = Task {
                try await withTaskCancellationHandler {
                    try await oneShot.value()
                } onCancel: {
                    _ = oneShot.finish(.failure(CancellationError()))
                }
            }
            try? await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    waiter.cancel()
                }
                group.addTask {
                    _ = oneShot.finish(.success(iteration))
                }
                await group.waitForAll()
            }

            _ = await waiter.result
            XCTAssertFalse(oneShot.finish(.success(-1)))
        }
    }

    // MARK: - MB-04: DefaultSubprocessEnvironmentScrubber Allowlist & Sanitization

    func testSubprocessEnvironmentScrubberStripsInjectionAndSecretVariables() {
        let dirtyEnv: [String: String] = [
            "PATH": "/tmp/attacker:/usr/bin:.:/bin:/var/tmp/exploit:/usr/sbin:/sbin",
            "HOME": "/Users/operator",
            "USER": "operator",
            "LOGNAME": "operator",
            "TMPDIR": "/var/folders/scramk",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8\nINJECTED=1",
            "DYLD_INSERT_LIBRARIES": "/tmp/rootkit.dylib",
            "DYLD_FRAMEWORK_PATH": "/tmp/frameworks",
            "LD_PRELOAD": "/tmp/preload.so",
            "DOCKER_TLS_VERIFY": "0",
            "DOCKER_HOST": "tcp://0.0.0.0:2375",
            "AWS_SECRET_ACCESS_KEY": "AKIA_TOP_SECRET",
            "ANTHROPIC_API_KEY": "sk-ant-secret",
            "OPENAI_API_KEY": "sk-openai-secret",
            "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock"
        ]

        let scrubbed = DefaultSubprocessEnvironmentScrubber.scrub(dirtyEnv)

        XCTAssertNil(scrubbed["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(scrubbed["DYLD_FRAMEWORK_PATH"])
        XCTAssertNil(scrubbed["LD_PRELOAD"])
        XCTAssertNil(scrubbed["DOCKER_TLS_VERIFY"])
        XCTAssertNil(scrubbed["DOCKER_HOST"])
        XCTAssertNil(scrubbed["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(scrubbed["ANTHROPIC_API_KEY"])
        XCTAssertNil(scrubbed["OPENAI_API_KEY"])
        XCTAssertNil(scrubbed["SSH_AUTH_SOCK"])

        XCTAssertTrue(Set(scrubbed.keys).isSubset(of: DefaultSubprocessEnvironmentScrubber.allowedKeys))
        XCTAssertEqual(scrubbed["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(scrubbed["LC_ALL"], "en_US.UTF-8INJECTED=1")
    }

    // MARK: - MB-05: Constant-Time SHA-256 Digest Comparison

    func testConstantTimeHexEqualsEnforcesStrict64CharHexDigestEquivalence() {
        let lowerDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let upperDigest = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"

        XCTAssertTrue(constantTimeHexEquals(lowerDigest, lowerDigest))
        XCTAssertTrue(constantTimeHexEquals(lowerDigest, upperDigest))

        // First-nibble flip
        let firstFlip = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        XCTAssertFalse(constantTimeHexEquals(lowerDigest, firstFlip))

        // Middle-nibble flip
        let midFlip = "0123456789abcdef0123456789abcdef1123456789abcdef0123456789abcdef"
        XCTAssertFalse(constantTimeHexEquals(lowerDigest, midFlip))

        // Last-nibble flip
        let lastFlip = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdee"
        XCTAssertFalse(constantTimeHexEquals(lowerDigest, lastFlip))

        // Invalid lengths (63, 65, 0)
        XCTAssertFalse(constantTimeHexEquals(String(lowerDigest.dropLast()), lowerDigest))
        XCTAssertFalse(constantTimeHexEquals(lowerDigest + "0", lowerDigest))
        XCTAssertFalse(constantTimeHexEquals("", ""))

        // Non-hex ASCII characters of length 64 must return false even if identical on both sides
        let nonHex64 = String(repeating: "g", count: 64)
        XCTAssertFalse(constantTimeHexEquals(nonHex64, nonHex64))
    }

    // MARK: - MB-06: ActiveHoldPolicy Lease Extension & Hard Cap in ContainerSocketBridge

    func testAuthorizationHoldExtendsLeasePast5sWindowAndEnforces120sHardCap() async throws {
        // 1. Without hold, advancing 5 seconds expires the intercept
        let clock1 = BridgeManualClock()
        let intercept1 = MCPIOCompletion<PendingIntercept>()
        let hooks1 = BridgeTestHooks(pendingPublished: { intercept1.finish(.success($0)) })

        try await BridgeFixture.withSession(timing: clock1.timing, hooks: hooks1) { session in
            try await session.gate.arm()
            let callTask = Task {
                try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
            }
            defer { callTask.cancel() }

            _ = try await intercept1.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            clock1.advance(seconds: 5)

            do {
                _ = try await callTask.value
                XCTFail("Unheld intercept must expire after 5s initial window")
            } catch let error as BridgeError {
                guard case .timedOut(.approval, _) = error else {
                    return XCTFail("Expected approval timeout, got \(error)")
                }
            }
        }

        // 2. With active hold, advancing 10 seconds (past 5s window, within 120s cap) preserves lease for approval
        let clock2 = BridgeManualClock()
        let intercept2 = MCPIOCompletion<PendingIntercept>()
        let hooks2 = BridgeTestHooks(pendingPublished: { intercept2.finish(.success($0)) })

        try await BridgeFixture.withSession(timing: clock2.timing, hooks: hooks2) { session in
            try await session.gate.arm()
            let callTask = Task {
                try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
            }
            defer { callTask.cancel() }

            let pending = try await intercept2.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let holdDeadline = await session.bridge.beginAuthorizationHold()
            XCTAssertNotNil(holdDeadline)
            let isHolding = await session.bridge.isAuthorizationHoldActive
            XCTAssertTrue(isHolding)

            // Advance 10 seconds: past initial 5s TTL, well inside 120s maxHoldDuration
            clock2.advance(seconds: 10)

            _ = await session.bridge.endAuthorizationHold()
            _ = try await session.bridge.approve(pending.approval)
            let result = try await callTask.value
            XCTAssertEqual(result.receipt.outcome, .responseReceived)
        }

        // 3. Even with active hold engaged, advancing past 120s hard cap expires the intercept
        let clock3 = BridgeManualClock()
        let intercept3 = MCPIOCompletion<PendingIntercept>()
        let hooks3 = BridgeTestHooks(pendingPublished: { intercept3.finish(.success($0)) })

        try await BridgeFixture.withSession(timing: clock3.timing, hooks: hooks3) { session in
            try await session.gate.arm()
            let callTask = Task {
                try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
            }
            defer { callTask.cancel() }

            _ = try await intercept3.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            _ = await session.bridge.beginAuthorizationHold()

            clock3.advance(seconds: 121)

            do {
                _ = try await callTask.value
                XCTFail("Active hold must still expire at the 120s hard cap")
            } catch let error as BridgeError {
                guard case .timedOut(.approval, _) = error else {
                    return XCTFail("Expected approval timeout at 120s hard cap, got \(error)")
                }
            }
        }
    }

    // MARK: - SYS-01: Strict Airgap Container Creation Rejection

    func testContainerCreationPolicyStrictAirgapRejectsNonNoneNetworkMode() {
        // 1. HostConfig NetworkMode == "bridge" must be rejected under .strictAirgap
        let bridgeNetworkJSON = #"""
        {
          "HostConfig": {
            "Privileged": false,
            "NetworkMode": "bridge",
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(
            Data(bridgeNetworkJSON.utf8),
            profile: .strictAirgap
        )) { error in
            guard case .forbiddenDirective(let key, let detail) = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected forbiddenDirective, got \(error)")
            }
            XCTAssertEqual(key, "networkmode")
            XCTAssertTrue(detail.contains("Strict airgap profile requires NetworkMode 'none'"))
        }

        // 2. Top-level NetworkMode: "none" shadowing missing HostConfig.NetworkMode must be rejected
        let shadowingJSON = #"""
        {
          "NetworkMode": "none",
          "HostConfig": {
            "Privileged": false,
            "ReadonlyRootfs": true,
            "CapDrop": ["ALL"]
          }
        }
        """#
        XCTAssertThrowsError(try ContainerCreationPolicy.inspectContainerCreatePayload(
            Data(shadowingJSON.utf8),
            profile: .strictAirgap
        )) { error in
            guard case .missingRequiredDirective(let key) = error as? ContainerCreationPolicyError else {
                return XCTFail("Expected missingRequiredDirective, got \(error)")
            }
            XCTAssertEqual(key, "networkmode")
        }
    }

    // MARK: - SYS-05: ContainerSocketBridge endAuthorizationHold Invariant

    func testEndAuthorizationHoldRequiresActiveHold() async throws {
        let clock = BridgeManualClock()
        let intercept = MCPIOCompletion<PendingIntercept>()
        let hooks = BridgeTestHooks(pendingPublished: { intercept.finish(.success($0)) })

        try await BridgeFixture.withSession(timing: clock.timing, hooks: hooks) { session in
            try await session.gate.arm()

            // 1. Calling endAuthorizationHold when hold is NOT active returns nil
            let prematureEnd = await session.bridge.endAuthorizationHold()
            XCTAssertNil(prematureEnd)
            let holdActiveBefore = await session.bridge.isAuthorizationHoldActive
            XCTAssertFalse(holdActiveBefore)

            // 2. Start a tool call to produce a pending intercept
            let callTask = Task {
                try await session.bridge.submitTool(name: "fixture", argumentsJSON: Data("{}".utf8), generation: session.info.generation)
            }
            defer { callTask.cancel() }

            let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))

            // 3. Before beginAuthorizationHold, endAuthorizationHold returns nil
            let unheldEnd = await session.bridge.endAuthorizationHold()
            XCTAssertNil(unheldEnd)

            // 4. Begin hold
            let holdDeadline = await session.bridge.beginAuthorizationHold()
            XCTAssertNotNil(holdDeadline)
            let isHolding = await session.bridge.isAuthorizationHoldActive
            XCTAssertTrue(isHolding)

            // 5. First endAuthorizationHold succeeds and resets active hold
            let validEnd = await session.bridge.endAuthorizationHold()
            XCTAssertNotNil(validEnd)
            let isHoldingAfter = await session.bridge.isAuthorizationHoldActive
            XCTAssertFalse(isHoldingAfter)

            // 6. Second immediate endAuthorizationHold returns nil because hold is no longer active
            let redundantEnd = await session.bridge.endAuthorizationHold()
            XCTAssertNil(redundantEnd)

            _ = try await session.bridge.approve(pending.approval)
            let result = try await callTask.value
            XCTAssertEqual(result.receipt.outcome, .responseReceived)
        }
    }
}
