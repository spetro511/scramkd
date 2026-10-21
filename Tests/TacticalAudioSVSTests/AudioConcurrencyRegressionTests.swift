import CTacticalAudioRealtime
import Foundation
import TacticalCore
@testable import TacticalAudioSVS
import XCTest

final class AudioConcurrencyRegressionTests: XCTestCase {
    func testFreshEpochCueSurvivesRenderPausedAfterSnapshot() throws {
        for rapidMute in [false, true] {
            let fixture = try AudioCPUFixture()
            // Deterministic pause, no hooks/locks/tasks are installed in the callback.
            let bounds = tart_capture_input_bounds_for_testing(fixture.storage.pointer)
            let paused = tart_complete_snapshot_for_testing(fixture.storage.pointer, bounds)
            fixture.control(epoch: 2, muted: rapidMute)
            if rapidMute { fixture.control(epoch: 2, muted: false) }
            XCTAssertEqual(try fixture.enqueue(.permissivePulse, epoch: 2), UInt32(TART_OK))
            _ = try AudioCPUFixture.render(storage: fixture.storage, frames: 256, snapshot: paused)
            XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 0)
            _ = try fixture.render(frames: 256)
            XCTAssertEqual(fixture.storage.observedCue(epoch: 2), .permissivePulse)
            XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 1)
        }
    }

    func testAcquiredFreshHeadObservesUnmuteAndOlderSnapshotPreservesTail() throws {
        let fixture = try AudioCPUFixture()
        let old = tart_complete_snapshot_for_testing(fixture.storage.pointer,
            tart_capture_input_bounds_for_testing(fixture.storage.pointer))
        fixture.control(epoch: 2, muted: true)
        fixture.control(epoch: 2, muted: false)
        _ = try fixture.enqueue(.ping, epoch: 2)
        let bounds = tart_capture_input_bounds_for_testing(fixture.storage.pointer)
        let coherent = tart_complete_snapshot_for_testing(fixture.storage.pointer, bounds)
        XCTAssertEqual(UInt32(truncatingIfNeeded: coherent.control >> 32), 2)
        XCTAssertEqual(coherent.control & UInt64(TART_MUTED), 0)
        // Adversarial old-control/new-head combination cannot occur in production,
        // but the defensive epoch check must still leave the new slot unconsumed.
        var mixed = bounds
        mixed.control = old.control
        _ = try AudioCPUFixture.render(storage: fixture.storage, frames: 256, snapshot: mixed)
        _ = try fixture.render(frames: 256)
        XCTAssertEqual(fixture.storage.observedCue(epoch: 2), .ping)
        XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 1)
    }

    func testUrgentPublicationAfterPausedBoundsIsNotAcknowledgedOrLostEarly() throws {
        let fixture = try AudioCPUFixture()
        let bounds = tart_capture_input_bounds_for_testing(fixture.storage.pointer)
        fixture.control(epoch: 2)
        tart_publish_abort(fixture.storage.pointer, 2, 9)
        let paused = tart_complete_snapshot_for_testing(fixture.storage.pointer, bounds)
        _ = try AudioCPUFixture.render(storage: fixture.storage, frames: 256, snapshot: paused)
        XCTAssertEqual(tart_load_abort_ack(fixture.storage.pointer), 0)
        _ = try fixture.render(frames: 256)
        XCTAssertEqual(tart_load_abort_ack(fixture.storage.pointer), (UInt64(2) << 32) | 9)
        XCTAssertEqual(fixture.storage.observedCue(epoch: 2), .emergencyAbortTrip)
    }

    func testRawCallbackTokenDoesNotOwnLastStorageHandle() async throws {
        var storage: AudioRealtimeStorage? = try AudioRealtimeStorage.cpuForTesting(configuration: .output)
        let weakStorage = AudioWeakStorageProbe(storage)
        let control: AudioReclamationControl
        let id: UUID
        var token: NSObject?
        do {
            let handle = try XCTUnwrap(storage)
            control = handle.reclamation
            id = handle.allocationID
            token = tart_create_retirement_marker_for_testing(handle.pointer)
            tart_mark_producer_detached(handle.pointer)
        }
        XCTAssertNotNil(token)
        storage = nil
        XCTAssertNil(weakStorage.value) // A callback token cannot be an owning ARC tail.
        try await control.waitForHandleRelease(id: id)
        let premature = await control.evidence(id: id)
        XCTAssertNil(premature)
        token = nil // Final operation is a raw release-store; no Task/free/owner release.
        let evidence = try await control.waitForReclamation(id: id)
        XCTAssertTrue(evidence.onControlActor)
    }

    func testRetirementPublicationCanRaceTrivialTokenTailWithoutCallbackFree() async throws {
        var storage: AudioRealtimeStorage? = try AudioRealtimeStorage.cpuForTesting(configuration: .output)
        let control: AudioReclamationControl
        let id: UUID
        let rawTail: AudioRawAddress
        do {
            let handle = try XCTUnwrap(storage)
            control = handle.reclamation
            id = handle.allocationID
            rawTail = handle.address
            tart_mark_producer_detached(handle.pointer)
        }
        storage = nil
        try await control.waitForHandleRelease(id: id)
        tart_mark_callback_retired(rawTail.pointer) // Same final C operation as token deinit.
        let evidence = try await control.waitForReclamation(id: id)
        XCTAssertTrue(evidence.onControlActor)
        // Models the token's still-live field tail AFTER control has reclaimed C.
        // This trivial value has no destructor and performs no further pointer access.
        withExtendedLifetime(rawTail) {}
    }

    func testUnconfirmedLastOwnerQuarantineBlocksReplacementUntilRawRetirement() async throws {
        let control = AudioReclamationControl()
        var storage: AudioRealtimeStorage? = try await control.allocate(configuration: .output)
        let id: UUID
        let address: AudioRawAddress
        do {
            let handle = try XCTUnwrap(storage)
            id = handle.allocationID
            address = handle.address
            tart_mark_producer_detached(handle.pointer)
        }
        storage = nil
        try await control.waitForHandleRelease(id: id)
        do { _ = try await control.allocate(configuration: .output); XCTFail("QUARANTINE_REPLACED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .cleanupIncomplete) }
        tart_mark_callback_retired(address.pointer)
        let evidence = try await control.waitForReclamation(id: id)
        XCTAssertTrue(evidence.onControlActor)
    }

    func testCumulativeRenderStartsRemainMonotonicDuringHeldStopAndFinalRender() async throws {
        let graph = AudioGraphDouble(holdStop: true)
        let synth = TacticalToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        let pending = await synth.realtimeStorageForTesting()
        let context = try XCTUnwrap(pending)
        _ = try await synth.enqueueCue(.armedPulse)
        _ = try AudioCPUFixture.render(storage: context, frames: 256)
        _ = try await synth.enqueueCue(.permissivePulse)
        let inFlight = tart_complete_snapshot_for_testing(context.pointer,
            tart_capture_input_bounds_for_testing(context.pointer))
        let before = await synth.totalTonesSynthesized
        let stopping = Task { await synth.disableOutput() }
        defer { graph.releaseAllGates(); stopping.cancel() }
        try await graph.waitForStopEntered()
        let during = await synth.totalTonesSynthesized
        XCTAssertEqual(before, 1)
        XCTAssertGreaterThanOrEqual(during, before)
        // This buffer had acquired its inputs before disable, and finishes while
        // stop is held. The retiring context must still represent its final start.
        _ = try AudioCPUFixture.render(storage: context, frames: 256, snapshot: inFlight)
        let finalInFlight = await synth.totalTonesSynthesized
        XCTAssertEqual(finalInFlight, 2)
        let joining = Task { await synth.disableOutput() }
        defer { joining.cancel() }
        graph.releaseStop() // Unconditional release precedes either teardown await.
        await stopping.value
        await joining.value
        let after = await synth.totalTonesSynthesized
        XCTAssertEqual(after, finalInFlight)
        await synth.disableOutput()
        let repeated = await synth.totalTonesSynthesized
        XCTAssertEqual(repeated, after)
    }

    func testOneShotRealClockWatchdogAndPreinstallCancellationAreBounded() async throws {
        let missing = AudioWaitSignal()
        do { try await missing.wait(timeout: .milliseconds(30)); XCTFail("MISSING_SIGNAL_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .waitTimedOut) }
        let cancelled = AudioWaitSignal()
        let worker = Task { try await cancelled.wait() }
        defer { worker.cancel() }
        worker.cancel()
        do { try await worker.value; XCTFail("CANCELLED_WAIT_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .operationCancelled) }
        let original = AudioWaitSignal()
        original.fail(.deviceUnavailable)
        original.succeed() // Teardown release must not replace the first failure.
        do { try await original.wait(); XCTFail("ORIGINAL_ERROR_LOST") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .deviceUnavailable) }
    }

    func testIncompleteCleanupStillRepresentsFinalInFlightStartsUntilOneFold() async throws {
        let graph = AudioGraphDouble(retireOnStop: false)
        defer { graph.releaseAllGates() }
        let synth = TacticalToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        let pending = await synth.realtimeStorageForTesting()
        let context = try XCTUnwrap(pending)
        _ = try await synth.enqueueCue(.armedPulse)
        _ = try AudioCPUFixture.render(storage: context, frames: 256)
        _ = try await synth.enqueueCue(.permissivePulse)
        let inFlight = tart_complete_snapshot_for_testing(context.pointer,
            tart_capture_input_bounds_for_testing(context.pointer))
        await synth.disableOutput()
        let duringQuarantine = await synth.totalTonesSynthesized
        XCTAssertEqual(duringQuarantine, 1)
        _ = try AudioCPUFixture.render(storage: context, frames: 256, snapshot: inFlight)
        let finalStart = await synth.totalTonesSynthesized
        XCTAssertEqual(finalStart, 2)
        graph.releaseAllGates()
        await graph.finishRetirement()
        await synth.disableOutput()
        let after = await synth.totalTonesSynthesized
        XCTAssertEqual(after, finalStart)
    }

    func testFixtureMissingProducerAndHeldStartWorkerHaveIndependentWatchdogs() async throws {
        let absent = AudioGraphDouble()
        defer { absent.releaseAllGates() }
        do { try await absent.waitForStart(timeout: .milliseconds(30)); XCTFail("ABSENT_START_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .waitTimedOut) }
        do { try await absent.waitForStop(timeout: .milliseconds(30)); XCTFail("ABSENT_STOP_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .waitTimedOut) }
        let held = AudioGraphDouble(holdStart: true, watchdog: .milliseconds(30))
        let synth = TacticalToneSynthesizer(graphDriver: held)
        let worker = Task { try await synth.enableOutput() }
        defer { held.releaseAllGates(); worker.cancel() }
        // Worker timeout remains authoritative even if it fires before this waiter enters.
        do { try await held.waitForStart() }
        catch { XCTAssertEqual(error as? TacticalAudioError, .waitTimedOut) }
        do { try await worker.value; XCTFail("HELD_WORKER_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .waitTimedOut) }
    }

    func testStopWatchdogPreservesInjectedFailureBeforeFixtureTeardown() async throws {
        let graph = AudioGraphDouble(holdStop: true, stopError: .deviceUnavailable, watchdog: .milliseconds(30))
        defer { graph.releaseAllGates() }
        let synth = TacticalToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        await synth.disableOutput()
        let status = await synth.outputStatus()
        XCTAssertEqual(status.lastError, .deviceUnavailable)
        XCTAssertEqual(status.cleanupError, .deviceUnavailable)
        graph.releaseAllGates()
        await graph.finishRetirement()
        await synth.disableOutput()
    }

    func testFixtureRetirementRejectsHeldWorkerBeforeTeardownAwait() async throws {
        let graph = AudioGraphDouble(holdStart: true)
        let synth = TacticalToneSynthesizer(graphDriver: graph)
        let worker = Task { try await synth.enableOutput() }
        defer { graph.releaseAllGates(); worker.cancel() }
        try await graph.waitForStart()
        await graph.finishRetirement() // Resolves both held gates before touching teardown joins.
        do { try await worker.value; XCTFail("RETIRED_WORKER_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .observationStopped) }
    }

    func testInjectedStartupFailureRejectsObserverWithOriginalError() async throws {
        let graph = AudioGraphDouble(startError: .deviceUnavailable)
        let synth = TacticalToneSynthesizer(graphDriver: graph)
        let worker = Task { try await synth.enableOutput() }
        defer { graph.releaseAllGates(); worker.cancel() }
        do { try await graph.waitForStart(); XCTFail("FAILED_START_OBSERVER_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .deviceUnavailable) }
        do { try await worker.value; XCTFail("FAILED_START_WORKER_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .deviceUnavailable) }
    }

    func testCursorMissingTransitionCancellationAndRetirementDoNotHang() async throws {
        let bridge = SVSBridge()
        let gate = HardwareInterlockGate()
        await bridge.startObserving(gate: gate)
        do { _ = try await bridge.waitForCursor(1, timeout: .milliseconds(30)); XCTFail("MISSING_TRANSITION_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .waitTimedOut) }
        let cancelled = Task { try await bridge.waitForCursor(1) }
        defer { cancelled.cancel() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("CANCELLED_CURSOR_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .operationCancelled) }
        let retired = Task { try await bridge.waitForCursor(2) }
        defer { retired.cancel() }
        await bridge.stopObserving()
        do { _ = try await retired.value; XCTFail("RETIRED_CURSOR_SUCCEEDED") }
        catch { XCTAssertEqual(error as? TacticalAudioError, .observationStopped) }
    }
}
