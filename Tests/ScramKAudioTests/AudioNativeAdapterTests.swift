import AVFoundation
import CScramKAudioRealtime
import Foundation
@testable import ScramKAudio
import XCTest

final class AudioNativeAdapterTests: XCTestCase {
    func testFailureBeforeMarkerAdmissionLeavesRetirementWithCaller() throws {
        let storage = try AudioRealtimeStorage.cpuForTesting(configuration: .output)
        let probe = try XCTUnwrap(tart_create_source_probe_for_testing(
            storage.pointer, UInt32(TART_NATIVE_PROBE_BEFORE_MARKER)))
        XCTAssertEqual(probe.status, UInt32(TART_NATIVE_SOURCE_INJECTED_BEFORE_MARKER))
        XCTAssertFalse(probe.retirementOwned)
        XCTAssertFalse(tart_callback_is_retired(storage.pointer))
        tart_mark_producer_detached(storage.pointer)
        // Explicit pre-admission evidence, not node-result inference.
        if !probe.retirementOwned { tart_mark_callback_retired(storage.pointer) }
        XCTAssertTrue(tart_is_quiescent(storage.pointer))
    }

    func testNilAfterNativeBlockCopyKeepsRetirementOwnedAndDelayed() async throws {
        try await assertDelayedNativeFailure(behavior: UInt32(TART_NATIVE_PROBE_NIL_AFTER_BLOCK_COPY),
                                            expectedStatus: UInt32(TART_NATIVE_SOURCE_NODE_NIL))
    }

    func testExceptionAfterNativeBlockCopyIsContainedWithoutFakeRetirement() async throws {
        try await assertDelayedNativeFailure(behavior: UInt32(TART_NATIVE_PROBE_EXCEPTION_AFTER_BLOCK_COPY),
                                            expectedStatus: UInt32(TART_NATIVE_SOURCE_EXCEPTION))
    }

    func testNativeSourceNodeOwnsMarkerUntilFinalManagedNodeRelease() async throws {
        // Node lifetime only: no engine, output route, input, or render operation.
        var storage: AudioRealtimeStorage? = try AudioRealtimeStorage.cpuForTesting(configuration: .output)
        let control: AudioReclamationControl
        let id: UUID
        var node: AVAudioSourceNode?
        do {
            let handle = try XCTUnwrap(storage)
            control = handle.reclamation
            id = handle.allocationID
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 48000, channels: 2, interleaved: false))
            var status: UInt32 = UInt32(TART_NATIVE_SOURCE_INVALID_INPUT)
            var owned = false
            node = tart_create_source_node(handle.pointer, format, &status, &owned)
            XCTAssertNotNil(node)
            XCTAssertEqual(status, UInt32(TART_NATIVE_SOURCE_OK))
            XCTAssertTrue(owned)
            XCTAssertFalse(tart_callback_is_retired(handle.pointer))
            tart_mark_producer_detached(handle.pointer)
        }
        storage = nil
        try await control.waitForHandleRelease(id: id)
        let premature = await control.evidence(id: id)
        XCTAssertNil(premature)
        node = nil
        let evidence = try await control.waitForReclamation(id: id)
        XCTAssertTrue(evidence.onControlActor)
    }
}

private func assertDelayedNativeFailure(behavior: UInt32, expectedStatus: UInt32) async throws {
    var storage: AudioRealtimeStorage? = try AudioRealtimeStorage.cpuForTesting(configuration: .output)
    let control: AudioReclamationControl
    let id: UUID
    var probe: TARTNativeSourceProbe?
    do {
        let handle = try XCTUnwrap(storage)
        control = handle.reclamation
        id = handle.allocationID
        probe = tart_create_source_probe_for_testing(handle.pointer, behavior)
        let result = try XCTUnwrap(probe)
        XCTAssertEqual(result.status, expectedStatus)
        XCTAssertTrue(result.retirementOwned)
        XCTAssertFalse(tart_callback_is_retired(handle.pointer))
        tart_mark_producer_detached(handle.pointer)
        // A failed node result does NOT prove no callback ownership remains.
        if !result.retirementOwned { tart_mark_callback_retired(handle.pointer) }
        XCTAssertFalse(tart_is_quiescent(handle.pointer))
    }
    storage = nil
    try await control.waitForHandleRelease(id: id)
    let premature = await control.evidence(id: id)
    XCTAssertNil(premature)
    probe = nil // Native copied-block dispose, then final native marker retirement.
    let evidence = try await control.waitForReclamation(id: id)
    XCTAssertTrue(evidence.onControlActor)
}
