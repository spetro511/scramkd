import Foundation
import XCTest
import TacticalCore
@testable import TacticalUI
@testable import TacticalVirtualization

private actor BridgeInspectionTestLatch {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class BridgePresentationTests: XCTestCase {
    func testLiveGrantRequiresObservedArmedAttachedAwaitingApproval() {
        let states: [InterlockStatus] = [.locked, .armed, .permissiveGranted, .emergencyAbort]
        let connections: [BridgeConnectionState] = [.detached, .attaching, .attached, .detaching, .failed]
        let phases: [BridgeInterceptPhase?] = [nil, .awaitingApproval, .approved, .writing, .awaitingResponse]
        for status in states {
            for connection in connections {
                for phase in phases {
                    for observing in [false, true] {
                        XCTAssertEqual(
                            BridgePresentation.canGrant(status: status, isObserving: observing,
                                isConfigured: true, connection: connection, phase: phase),
                            observing && status == .armed && connection == .attached && phase == .awaitingApproval
                        )
                    }
                }
            }
        }
    }

    func testExplicitNilBridgeModePreservesLegacyCoreAvailability() {
        XCTAssertTrue(BridgePresentation.canGrant(status: .armed, isObserving: true,
            isConfigured: false, connection: .detached, phase: nil))
        XCTAssertFalse(BridgePresentation.canGrant(status: .locked, isObserving: true,
            isConfigured: false, connection: .detached, phase: nil))
        XCTAssertFalse(BridgePresentation.canGrant(status: .armed, isObserving: false,
            isConfigured: false, connection: .detached, phase: nil))
        XCTAssertEqual(BridgePresentation.connection(.attached, configured: false, observing: true), "UNBOUND")
        XCTAssertEqual(BridgePresentation.connection(.attached, configured: true, observing: false), "UNOBSERVED")
    }

    func testDisplayEscapesControlsBidiAndLiteralEscapeIntroducers() {
        let hostile = "A\n\r\t\u{1B}\u{202E}\u{2066}\u{200D}\u{2028}\\\"Z"
        let escaped = BridgeDisplayText.escaped(hostile)
        XCTAssertFalse(escaped.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) })
        XCTAssertTrue(escaped.contains("\\n\\r\\t"))
        XCTAssertTrue(escaped.contains("\\u{202E}"))
        XCTAssertTrue(escaped.contains("\\u{2066}"))
        XCTAssertTrue(escaped.contains("\\\\\\\"Z"))
        XCTAssertEqual(BridgeDisplayText.escaped("abcdef", limit: 3), "abc… [TRUNCATED]")
    }

    func testCompleteWireIncludesFinalLFAndAllArgumentsPreserveNumericTokens() async throws {
        let number = "1234567890123456789012345678901234567890.12345678901234567890e-120"
        let padding = String(repeating: "x", count: 240)
        let json = "{\"jsonrpc\":\"2.0\",\"id\":\"request\",\"method\":\"tools/call\",\"params\":{\"name\":\"test.tool\",\"arguments\":{\"aaa\":\"\(padding)\",\"number\":\(number),\"zzz\":{\"exec\":\"NO_EXECUTION_FIXTURE\",\"values\":[true,null,-0]}}}}\n"
        let data = Data(json.utf8)
        let document = try await BridgePayloadDecoder().decode(data)
        XCTAssertNil(document.issue)
        XCTAssertEqual(document.escapedWire, BridgeDisplayText.escaped(json))
        XCTAssertTrue(document.escapedWire.hasSuffix("\\n"))
        XCTAssertTrue(document.allArguments.contains(number))
        XCTAssertTrue(document.allArguments.contains("NO_EXECUTION_FIXTURE"))
        XCTAssertTrue(document.allArguments.contains("[true, null, -0]"))
        XCTAssertFalse(document.preview.contains("NO_EXECUTION_FIXTURE"))
        XCTAssertTrue(document.preview.contains("TRUNCATED; INSPECT ALL"))
        XCTAssertEqual(data, Data(json.utf8), "Inspection must never alter frozen wire bytes")
    }

    func testDecodedStringControlsRemainEscapedAndNeverBecomeUIFormatting() async throws {
        let data = Data((#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"test","arguments":{"command":"line\nnext\u202eTAIL","other":"\\u202e"}}}"# + "\n").utf8)
        let document = try await BridgePayloadDecoder().decode(data)
        XCTAssertNil(document.issue)
        XCTAssertTrue(document.allArguments.contains("line\\nnext\\u{202E}TAIL"))
        XCTAssertFalse(document.allArguments.contains("\u{202E}"))
        XCTAssertFalse(document.allArguments.contains("\n"))
        XCTAssertTrue(document.allArguments.contains("\\\\u202e"), "Literal escape text stays distinguishable from a bidi scalar")
    }

    func testInvalidUTF8DoesNotUseReplacementDecoding() async throws {
        let document = try await BridgePayloadDecoder().decode(Data([0xFF, 0x0A]))
        XCTAssertEqual(document.issue, "INVALID UTF-8 // NO REPLACEMENT DECODING")
        XCTAssertFalse(document.escapedWire.contains("\u{FFFD}"))
    }

    func testMissingOrExtraFramingLFIsExplicitlyRejected() async throws {
        let data = frame(arguments: "{}")
        let missing = try await BridgePayloadDecoder().decode(Data(data.dropLast()))
        let extra = try await BridgePayloadDecoder().decode(data + Data([0x0A]))
        XCTAssertEqual(missing.issue, "INVALID FRAME // FINAL LF REQUIRED")
        XCTAssertEqual(extra.issue, "INVALID FRAME // FINAL LF REQUIRED")
        XCTAssertFalse(extra.escapedWire.isEmpty, "Complete valid-UTF8 wire remains inspectable even when framing is rejected")
    }

    func testDuplicateDecodedKeysDoNotHideAnArgument() async throws {
        let data = frame(arguments: #"{"command":"FIRST","\u0063ommand":"SECOND"}"#)
        let document = try await BridgePayloadDecoder().decode(data)
        XCTAssertEqual(document.issue, "DUPLICATE JSON KEY // AMBIGUOUS ARGUMENTS")
        XCTAssertTrue(document.escapedWire.contains("FIRST"))
        XCTAssertTrue(document.escapedWire.contains("SECOND"))
    }

    func testInspectionBoundsBytesAndDepthBeforeUnboundedDecode() async throws {
        let overLimit = try await BridgePayloadDecoder().decode(Data(repeating: 0x20, count: 1_048_577))
        XCTAssertEqual(overLimit.issue, "INSPECTION BYTE LIMIT EXCEEDED")
        XCTAssertLessThan(overLimit.escapedWire.count, 100)
        let nested = "{\"v\":" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}"
        let tooDeep = try await BridgePayloadDecoder().decode(frame(arguments: nested))
        XCTAssertEqual(tooDeep.issue, "JSON DEPTH LIMIT EXCEEDED")
    }

    func testInvalidJSONNumberIsNotAcceptedAsDisplayData() async throws {
        for number in ["01", "+1", "1.", "1e", "NaN"] {
            let document = try await BridgePayloadDecoder().decode(frame(arguments: "{\"n\":\(number)}"))
            XCTAssertNotNil(document.issue, number)
        }
    }

    func testPresentationCacheRequiresFullOpaqueKeyAndClearsOnDetach() async {
        let request = UUID()
        let hash = String(repeating: "0", count: 64)
        let old = BridgeApprovalKey(requestID: request, sha256: hash, connectionGeneration: UUID())
        let replacement = BridgeApprovalKey(requestID: request, sha256: hash, connectionGeneration: UUID())
        let model = BridgePayloadPresentationModel()
        await model.load(pending(old, origin: .appProcess))
        XCTAssertNotNil(model.document(for: old))
        XCTAssertNil(model.document(for: replacement))
        await model.load(pending(replacement, origin: .unknown))
        XCTAssertNil(model.document(for: old))
        XCTAssertNotNil(model.document(for: replacement))
        await model.load(nil)
        XCTAssertNil(model.document(for: replacement))
        XCTAssertNil(model.key)
    }

    func testOriginAndTransferLabelsDoNotInventAgentIdentityOrExecution() {
        let key = BridgeApprovalKey(requestID: UUID(), sha256: String(repeating: "a", count: 64), connectionGeneration: UUID())
        XCTAssertEqual(BridgePresentation.origin(pending(key, origin: .appProcess)), "SOURCE APPLICATION PID 42")
        XCTAssertEqual(BridgePresentation.origin(pending(key, origin: .claimed)), "CLAIMED PID 42 // NOT VERIFIED")
        XCTAssertTrue(BridgePresentation.origin(pending(key, origin: .unknown)).contains("UNKNOWN"))
        XCTAssertEqual(BridgePresentation.transfer(nil), "PIPE OUT: -- // CHUNKS: -- // ELAPSED: --")
        let receipt = BridgeTransferReceipt(requestID: key.requestID, connectionGeneration: key.connectionGeneration,
            approval: key, bytesWritten: 17, writeChunks: 2, bytesRead: 9, readChunks: 1,
            elapsedNanoseconds: 9876, transmissionStage: .partial, hasCorrelatedResponse: false, outcome: .endOfStream)
        XCTAssertEqual(BridgePresentation.transfer(receipt), "PIPE OUT: 17 B / 2 CH // 9876 ns")
        XCTAssertEqual(BridgePresentation.outcome(receipt.outcome), "PIPE EOF")
        XCTAssertEqual(BridgePresentation.outcome(.responseReceived), "PROTOCOL RESPONSE")
    }

    func testCancelledInspectionWrapperCannotAdoptReplacementKey() async {
        let old = BridgeApprovalKey(requestID: UUID(), sha256: String(repeating: "a", count: 64), connectionGeneration: UUID())
        let replacement = BridgeApprovalKey(requestID: UUID(), sha256: String(repeating: "b", count: 64), connectionGeneration: UUID())
        let model = BridgePayloadPresentationModel()
        await model.load(pending(old, origin: .appProcess))
        let newPending = pending(replacement, origin: .appProcess)
        let latch = BridgeInspectionTestLatch()
        let wrapper = Task { @MainActor in
            await latch.wait()
            await model.load(newPending)
        }
        wrapper.cancel()
        await latch.open()
        await wrapper.value
        XCTAssertNotNil(model.document(for: old))
        XCTAssertNil(model.document(for: replacement))
        XCTAssertEqual(model.key, old)
    }

    func testNilFramebufferFeatureKeepsUnboundPresentation() {
        let frame = ConsoleFramePresentation(snapshot: nil, isConfigured: false, isObserving: true)
        XCTAssertEqual(frame.stateLabel, "UNBOUND")
        XCTAssertEqual(frame.badge, "[FRAMEBUFFER UNBOUND]")
        XCTAssertFalse(frame.hasReceivedFrame)
        XCTAssertNil(frame.diagnostic)
        XCTAssertTrue(frame.statisticsLabel.contains("RX: -- B"))
    }

    func testConfiguredFramebufferStandsByUntilAnActualFrameArrives() {
        let initial = ConsoleFramePresentation(snapshot: nil, isConfigured: true, isObserving: true)
        XCTAssertEqual(initial.stateLabel, "DETACHED")
        XCTAssertEqual(initial.badge, "[STANDBY // CONTAINER DETACHED]")
        for state in [FrameConnectionState.connecting, .negotiating, .connected] {
            let frame = ConsoleFramePresentation(snapshot: frameSnapshot(state: state),
                isConfigured: true, isObserving: true)
            XCTAssertFalse(frame.hasReceivedFrame)
            XCTAssertEqual(frame.badge, "[STANDBY // CONTAINER DETACHED]")
            XCTAssertEqual(frame.stateLabel, state == .connected ? "AWAITING FRAME" : state.rawValue.uppercased())
        }
        let initialized = ConsoleFramePresentation(snapshot: frameSnapshot(state: .connected),
            isConfigured: true, isObserving: true)
        XCTAssertEqual(initialized.sourceLabel, "RFB SIZE: 1920×1080 // AWAITING PIXELS")
    }

    func testReceivedFrameReportsSourcePixelsAndAssumedNotVerifiedProfile() {
        let frame = ConsoleFramePresentation(snapshot: frameSnapshot(state: .connected, receivedFrame: true),
            isConfigured: true, isObserving: true)
        XCTAssertTrue(frame.hasReceivedFrame)
        XCTAssertEqual(frame.stateLabel, "STREAMING")
        XCTAssertEqual(frame.sourceLabel, "SOURCE: 1920×1080 PX // ASSUMED sRGB")
        XCTAssertEqual(frame.badge, "[READ-ONLY SOURCE // FRAME RECEIVED]")
        XCTAssertTrue(frame.accessibilitySummary.contains("not GPU presentation FPS"))
    }

    func testRetiredOrFailedSourceNeverLabelsStaleFrameAsStreaming() {
        for state in [FrameConnectionState.detached, .disconnecting, .failed] {
            let frame = ConsoleFramePresentation(snapshot: frameSnapshot(state: state, receivedFrame: true),
                isConfigured: true, isObserving: true)
            XCTAssertFalse(frame.hasReceivedFrame)
            XCTAssertNotEqual(frame.stateLabel, "STREAMING")
            XCTAssertEqual(frame.badge, "[STANDBY // CONTAINER DETACHED]")
            XCTAssertFalse(frame.sourceLabel.contains("1920×1080"))
        }
        let failed = ConsoleFramePresentation(snapshot: frameSnapshot(state: .connected, receivedFrame: true,
            failure: .timedOut(.update)), isConfigured: true, isObserving: true)
        XCTAssertFalse(failed.hasReceivedFrame)
        XCTAssertEqual(failed.stateLabel, "FAILED")
        XCTAssertEqual(failed.diagnostic, "TIMEOUT // UPDATE")
        let unobserved = ConsoleFramePresentation(snapshot: frameSnapshot(state: .connected, receivedFrame: true),
            isConfigured: true, isObserving: false)
        XCTAssertEqual(unobserved.stateLabel, "UNOBSERVED")
        XCTAssertFalse(unobserved.hasReceivedFrame)
    }

    func testFramebufferCountersUseActualValuesWithoutSyntheticPresentationRate() {
        var statistics = FrameStatistics()
        statistics.receivedBinaryPayloadBytes = 12345
        statistics.receivedBinaryMessages = 7
        statistics.completedUpdates = 9
        statistics.noChangeUpdates = 2
        statistics.publishedFrames = 5
        statistics.replacedFrameDeliveries = 3
        let frame = ConsoleFramePresentation(snapshot: frameSnapshot(state: .connected, receivedFrame: true,
            statistics: statistics), isConfigured: true, isObserving: true)
        XCTAssertEqual(frame.statisticsLabel,
            "RX: 12345 B / 7 MSG // UPDATES: 9 // SAME: 2 // SRC: 5 // REPLACED: 3")
        XCTAssertFalse(frame.statisticsLabel.contains("FPS"))
        XCTAssertTrue(frame.accessibilitySummary.contains("not a total dropped-frame metric"))
    }

    private func frameSnapshot(
        state: FrameConnectionState, receivedFrame: Bool = false,
        failure: FrameError? = nil, statistics: FrameStatistics = FrameStatistics()
    ) -> FrameSnapshot {
        FrameSnapshot(revision: 1, generation: UUID(), state: state, width: 1920, height: 1080,
            lastTrafficAt: nil, lastFrameAt: receivedFrame ? ContinuousClock.now : nil,
            statistics: statistics, failure: failure)
    }

    private func frame(arguments: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\"test\",\"method\":\"tools/call\",\"params\":{\"name\":\"test.tool\",\"arguments\":\(arguments)}}\n".utf8)
    }

    private func pending(_ key: BridgeApprovalKey, origin: OriginTrustKind) -> PendingIntercept {
        PendingIntercept(approval: key, toolHook: "test.tool", commandPayload: frame(arguments: "{}"),
            originPID: 42, originTrust: origin, phase: .awaitingApproval,
            approvalDeadline: ContinuousClock().now.advanced(by: .seconds(5)))
    }
}
