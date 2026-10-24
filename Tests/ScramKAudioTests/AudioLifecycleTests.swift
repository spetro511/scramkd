import CScramKAudioRealtime
import Foundation
import ScramKCore
@testable import ScramKAudio
import XCTest

final class AudioLifecycleTests: XCTestCase {
    func testDefaultInitializationAndSuppressedMetadataDoNotConstructGraph() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        let disposition = try await synth.enqueueCue(.armedPulse)
        let status = await synth.outputStatus()
        let starts = await graph.startCount
        let requests = await synth.totalToneRequests
        let renders = await synth.totalTonesSynthesized
        XCTAssertEqual(disposition, .suppressedDisabled)
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertEqual(status.masterGainDecibels, -24)
        XCTAssertNil(status.renderingCue)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(renders, 0)
        await synth.setMuted(true)
        let muted = try await synth.enqueueCue(.ping)
        XCTAssertEqual(muted, .suppressedMuted)
    }

    func testEnableMuteStopDisableAndFreshContextNoReplay() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        let oldID: UUID
        do {
            let pendingContext = await synth.realtimeStorageForTesting()
            let context = try XCTUnwrap(pendingContext)
            oldID = context.allocationID
            _ = try await synth.enqueueCue(.permissivePulse)
            _ = try AudioCPUFixture.render(storage: context, frames: 512)
            let rendering = await synth.outputStatus()
            XCTAssertEqual(rendering.renderingCue, .permissivePulse)
            await synth.setMuted(true)
            XCTAssertTrue(try AudioCPUFixture.render(storage: context, frames: 256)[0].allSatisfy { $0 == 0 })
            await synth.setMuted(false)
            XCTAssertTrue(try AudioCPUFixture.render(storage: context, frames: 256)[0].allSatisfy { $0 == 0 })
            _ = try await synth.enqueueCue(.ping)
            await synth.stop()
            XCTAssertTrue(try AudioCPUFixture.render(storage: context, frames: 256)[0].allSatisfy { $0 == 0 })
            await synth.disableOutput()
            XCTAssertTrue(tart_is_quiescent(context.pointer))
        } // Drop all old access handles before requesting the bounded replacement slot.
        let disabled = await synth.outputStatus()
        XCTAssertEqual(disabled.phase, .disabled)
        try await synth.enableOutput()
        let pendingReplacement = await synth.realtimeStorageForTesting()
        let replacement = try XCTUnwrap(pendingReplacement)
        XCTAssertNotEqual(oldID, replacement.allocationID)
        XCTAssertTrue(try AudioCPUFixture.render(storage: replacement, frames: 256)[0].allSatisfy { $0 == 0 })
        await synth.disableOutput()
    }

    func testSlowStartDoesNotBlockCueProducerAndDisableFencesCompletion() async throws {
        let graph = AudioGraphDouble(holdStart: true)
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        let enabling = Task { try await synth.enableOutput() }
        defer { graph.releaseAllGates(); enabling.cancel() }
        try await graph.waitForStart()
        let disposition = try await synth.enqueueCue(.emergencyAbortTrip)
        XCTAssertEqual(disposition, .suppressedDisabled)
        await synth.disableOutput() // The double settles the blocked start deterministically.
        do { try await enabling.value; XCTFail("STALE_ENABLE_ACCEPTED") }
        catch { XCTAssertEqual(error as? ScramKAudioError, .staleGeneration) }
        let status = await synth.outputStatus()
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertNil(status.renderingCue)
    }

    func testStartFailureAndIncompleteRetirementRemainVisible() async throws {
        let failing = AudioGraphDouble(startError: .deviceUnavailable)
        let synth = ScramKToneSynthesizer(graphDriver: failing)
        do { try await synth.enableOutput(); XCTFail("FAILED_GRAPH_ACCEPTED") }
        catch { XCTAssertEqual(error as? ScramKAudioError, .deviceUnavailable) }
        let failure = await synth.outputStatus()
        XCTAssertEqual(failure.phase, .unavailable)
        XCTAssertEqual(failure.lastError, .deviceUnavailable)

        let held = AudioGraphDouble(retireOnStop: false)
        let heldSynth = ScramKToneSynthesizer(graphDriver: held)
        try await heldSynth.enableOutput()
        await heldSynth.disableOutput()
        let incomplete = await heldSynth.outputStatus()
        XCTAssertEqual(incomplete.lastError, .cleanupIncomplete)
        do { try await heldSynth.enableOutput(); XCTFail("UNRETIRED_GRAPH_REENABLED") }
        catch { XCTAssertEqual(error as? ScramKAudioError, .cleanupIncomplete) }
        await held.finishRetirement()
        await heldSynth.disableOutput()
    }

    func testCancelledEnableCleansGraphAndNeverAdmitsCues() async throws {
        let graph = AudioGraphDouble(holdStart: true)
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        let enabling = Task { try await synth.enableOutput() }
        defer { graph.releaseAllGates(); enabling.cancel() }
        try await graph.waitForStart()
        enabling.cancel()
        graph.releaseStart()
        do { try await enabling.value; XCTFail("CANCELLED_ENABLE_ACCEPTED") }
        catch { XCTAssertEqual(error as? ScramKAudioError, .operationCancelled) }
        let status = await synth.outputStatus()
        XCTAssertEqual(status.phase, .unavailable)
        XCTAssertEqual(status.lastError, .operationCancelled)
        let disposition = try await synth.enqueueCue(.ping)
        XCTAssertEqual(disposition, .suppressedDisabled)
    }

    func testConcurrentDisableJoinsOneSettledCleanup() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await synth.disableOutput() }
            group.addTask { await synth.disableOutput() }
            await group.waitForAll()
        }
        let status = await synth.outputStatus()
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertNil(status.lastError)
    }

    func testProducerDeinitFencesOutputAndRequestsGraphCleanup() async throws {
        let graph = AudioGraphDouble()
        var synth: ScramKToneSynthesizer? = ScramKToneSynthesizer(graphDriver: graph)
        try await synth?.enableOutput()
        let pending = await synth?.realtimeStorageForTesting()
        let context = try XCTUnwrap(pending)
        synth = nil
        try await graph.waitForStop()
        XCTAssertTrue(tart_is_quiescent(context.pointer))
    }

    func testDeviceChangeDisablesWithoutAutomaticResume() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        _ = try await synth.enqueueCue(.ping)
        await graph.triggerDeviceChange()
        let status = await synth.outputStatus()
        let starts = await graph.startCount
        XCTAssertEqual(status.phase, .unavailable)
        XCTAssertEqual(status.lastError, .deviceChanged)
        XCTAssertNil(status.renderingCue)
        XCTAssertEqual(starts, 1)
        let suppressed = try await synth.enqueueCue(.ping)
        XCTAssertEqual(suppressed, .suppressedDisabled)
    }

    func testFacadeQueueSaturationAndAbortCoalescenceAreExplicit() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        try await synth.enableOutput()
        for _ in 0..<16 { _ = try await synth.enqueueCue(.ping) }
        let full = try await synth.enqueueCue(.armedPulse)
        XCTAssertEqual(full, .queueFull)
        let urgent = try await synth.enqueueCue(.emergencyAbortTrip)
        guard case .queued = urgent else { return XCTFail("ABORT_REJECTED_WHEN_FULL") }
        let duplicate = try await synth.enqueueCue(.emergencyAbortTrip)
        XCTAssertEqual(duplicate, .coalesced)
        let pending = await synth.realtimeStorageForTesting()
        let context = try XCTUnwrap(pending)
        _ = try AudioCPUFixture.render(storage: context, frames: 512)
        let activeDuplicate = try await synth.enqueueCue(.emergencyAbortTrip)
        XCTAssertEqual(activeDuplicate, .coalesced)
        XCTAssertEqual(tart_load_started_count(context.pointer), 1)
        await synth.disableOutput()
    }

    func testEpochExhaustionFailsClosedAndGainRejectsBoostOrNonfinite() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        for gain in [Double.nan, .infinity, 0.1] {
            do { try await synth.setMasterGain(decibels: gain); XCTFail("INVALID_GAIN_ACCEPTED") }
            catch { XCTAssertEqual(error as? ScramKAudioError, .invalidMasterGain) }
        }
        try await synth.enableOutput()
        let pendingContext = await synth.realtimeStorageForTesting()
        let context = try XCTUnwrap(pendingContext)
        _ = try await synth.enqueueCue(.armedPulse)
        await synth.setEpochForTesting(.max)
        await synth.stop()
        let status = await synth.outputStatus()
        XCTAssertEqual(status.phase, .unavailable)
        XCTAssertEqual(status.lastError, .generationExhausted)
        XCTAssertTrue(try AudioCPUFixture.render(storage: context, frames: 256)[0].allSatisfy { $0 == 0 })
        await synth.disableOutput()
    }

    func testSPSCIndicesCrossUInt32WrapOnlyUnderQuiescentFixtureSetup() throws {
        let fixture = try AudioCPUFixture()
        XCTAssertFalse(tart_seed_quiescent_indices_for_testing(fixture.storage.pointer, .max - 7))
        tart_mark_producer_detached(fixture.storage.pointer)
        tart_mark_callback_retired(fixture.storage.pointer)
        XCTAssertTrue(tart_seed_quiescent_indices_for_testing(fixture.storage.pointer, .max - 7))
        tart_mark_producer_attached(fixture.storage.pointer)
        for sequence in 1...16 {
            XCTAssertEqual(try fixture.enqueue(.ping, sequence: UInt32(sequence)), UInt32(TART_OK))
        }
        XCTAssertEqual(try fixture.enqueue(.ping, sequence: 17), UInt32(TART_FULL))
        _ = try fixture.render(frames: 256)
        XCTAssertEqual(try fixture.enqueue(.armedPulse, sequence: 18), UInt32(TART_OK))
    }

    func testPermissiveEventSurvivesImmediateBrokerStyleRelock() async throws {
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        let bridge = SVSBridge(synthesizer: synth)
        let gate = HardwareInterlockGate()
        try await synth.enableOutput()
        await bridge.startObserving(gate: gate)
        try await gate.arm()
        try await gate.grantPermissive()
        try await gate.lock()
        let observed = try await bridge.waitForCursor(3)
        XCTAssertTrue(observed)
        let pendingContext = await synth.realtimeStorageForTesting()
        let context = try XCTUnwrap(pendingContext)
        var samples: [Float] = []
        for _ in 0..<37 { samples += try AudioCPUFixture.render(storage: context, frames: 256)[0] }
        samples += try AudioCPUFixture.render(storage: context, frames: 128)[0]
        XCTAssertEqual(samples.count, 9600)
        XCTAssertTrue(samples[480..<9000].contains { abs($0) > 0.001 })
        XCTAssertEqual(samples.last, 0)
        let selected = await synth.currentActiveCue
        let status = await gate.currentStatus
        XCTAssertEqual(selected, .permissivePulse)
        XCTAssertEqual(status, .locked)
        await bridge.stopObserving()
        await synth.disableOutput()
    }

    func testAtomicBootstrapNoHistoryAndHealthOnlyWhenBound() async throws {
        let gate = HardwareInterlockGate()
        try await gate.arm()
        let synth = ScramKToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synth)
        await bridge.startObserving(gate: gate)
        let initialRequests = await synth.totalToneRequests
        XCTAssertEqual(initialRequests, 0)
        for sequence in 1...2 {
            try await bridge.ingestTelemetry(TelemetryFrame(timestampNanoseconds: 1,
                sequenceNumber: UInt64(sequence), subsystem: .core, health: .critical,
                interlockState: .emergencyAbort, payloadSize: 0))
        }
        let requests = await synth.totalToneRequests
        let selected = await synth.currentActiveCue
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(selected, .masterWarning)
        await bridge.stopObserving()
        let subscribers = await gate.activeSubscribersCount
        XCTAssertEqual(subscribers, 0)
    }

    func testObservationGapIsReportedAndReconciledSilently() async throws {
        let gate = HardwareInterlockGate()
        let synth = ScramKToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synth)
        await bridge.startObserving(gate: gate)
        await bridge.injectObservationForTesting(InterlockObservedTransition(cursor: 2,
            record: InterlockTransitionRecord(timestampNanoseconds: 0, from: .locked, to: .armed, reason: "GAP_TEST")))
        let error = await bridge.lastError
        let requests = await synth.totalToneRequests
        XCTAssertEqual(error, .observationGap)
        XCTAssertEqual(requests, 0)
        await bridge.stopObserving()
    }

    func testRebindUnsubscribesOldGateAndCapturesAudioErrors() async throws {
        let old = HardwareInterlockGate()
        let replacement = HardwareInterlockGate()
        let graph = AudioGraphDouble()
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        let bridge = SVSBridge(synthesizer: synth)
        await bridge.startObserving(gate: old)
        await bridge.startObserving(gate: replacement)
        try await old.arm()
        let oldSubscribers = await old.activeSubscribersCount
        let noOldRequests = await synth.totalToneRequests
        XCTAssertEqual(oldSubscribers, 0)
        XCTAssertEqual(noOldRequests, 0)
        try await synth.enableOutput()
        await synth.setEpochForTesting(.max)
        await replacement.tripEmergencyAbort(reason: "AUDIO_ERROR_TEST")
        do {
            _ = try await bridge.waitForCursor(1)
            XCTFail("FAILED_TRANSITION_REPORTED_AS_OBSERVED_SUCCESS")
        } catch { XCTAssertEqual(error as? ScramKAudioError, .generationExhausted) }
        let error = await bridge.lastError
        XCTAssertEqual(error, .generationExhausted)
        await bridge.stopObserving()
        await synth.disableOutput()
    }

    func testOfflineManualGraphUsesProductionSourceNodeWithoutHardwareFallback() async throws {
        let graph = AudioGraphOwner(mode: .offline)
        let synth = ScramKToneSynthesizer(graphDriver: graph)
        do {
            try await synth.enableOutput()
            _ = try await synth.enqueueCue(.armedPulse)
            let samples = try await graph.renderOffline(frames: 1024)
            XCTAssertEqual(samples.count, 2)
            XCTAssertEqual(samples[0], samples[1])
            XCTAssertTrue(samples[0].contains { abs($0) > 0.001 })
            let status = await synth.outputStatus()
            XCTAssertEqual(status.renderingCue, .armedPulse)
            await synth.disableOutput()
            let stopped = await synth.outputStatus()
            XCTAssertEqual(stopped.phase, .disabled)
            XCTAssertNil(stopped.lastError)
        } catch {
            await synth.disableOutput()
            throw error // Infrastructure/render errors are failures, not silent skips.
        }
    }
}
