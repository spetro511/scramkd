import Foundation
import TacticalCore
@testable import TacticalAudioSVS
import XCTest

final class SVSBridgeTests: XCTestCase {
    func testArmedTransitionEmits440Hz() async throws {
        let synthesizer = TacticalToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synthesizer)

        try await bridge.handleTransition(from: .locked, to: .armed)

        let cue = await synthesizer.currentActiveCue
        let params = await synthesizer.lastSynthesizedParameters

        XCTAssertEqual(cue, .armedPulse)
        XCTAssertEqual(params?.frequencyHz, 440.0)
        XCTAssertEqual(params?.waveform, .sine)
    }

    func testPermissiveTransitionEmits880Hz() async throws {
        let synthesizer = TacticalToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synthesizer)

        try await bridge.handleTransition(from: .armed, to: .permissiveGranted)

        let cue = await synthesizer.currentActiveCue
        let params = await synthesizer.lastSynthesizedParameters

        XCTAssertEqual(cue, .permissivePulse)
        XCTAssertEqual(params?.frequencyHz, 880.0)
        XCTAssertEqual(params?.waveform, .sine)
    }

    func testEmergencyAbortTransitionEmits1200HzSawPulse() async throws {
        let synthesizer = TacticalToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synthesizer)

        try await bridge.handleTransition(from: .armed, to: .emergencyAbort)

        let cue = await synthesizer.currentActiveCue
        let params = await synthesizer.lastSynthesizedParameters

        XCTAssertEqual(cue, .emergencyAbortTrip)
        XCTAssertEqual(params?.frequencyHz, 1200.0)
        XCTAssertEqual(params?.waveform, .saw)
    }

    func testEndToEndGateObservationStreaming() async throws {
        let gate = HardwareInterlockGate()
        let synthesizer = TacticalToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synthesizer)

        await bridge.startObserving(gate: gate)
        let isObserving = await bridge.isObserving
        XCTAssertTrue(isObserving)

        // 1. Arm gate -> 440Hz armed pulse
        try await gate.arm()
        for _ in 0..<50 {
            if await synthesizer.currentActiveCue == .armedPulse { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let armedCue = await synthesizer.currentActiveCue
        let armedParams = await synthesizer.lastSynthesizedParameters
        XCTAssertEqual(armedCue, .armedPulse)
        XCTAssertEqual(armedParams?.frequencyHz, 440.0)

        // 2. Grant permissive -> 880Hz permissive pulse
        try await gate.grantPermissive()
        for _ in 0..<50 {
            if await synthesizer.currentActiveCue == .permissivePulse { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let permissiveCue = await synthesizer.currentActiveCue
        let permissiveParams = await synthesizer.lastSynthesizedParameters
        XCTAssertEqual(permissiveCue, .permissivePulse)
        XCTAssertEqual(permissiveParams?.frequencyHz, 880.0)

        // 3. Trip emergency abort -> 1200Hz saw pulse
        await gate.tripEmergencyAbort(reason: "AVIONICS_FAULT")
        for _ in 0..<50 {
            if await synthesizer.currentActiveCue == .emergencyAbortTrip { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let abortCue = await synthesizer.currentActiveCue
        let abortParams = await synthesizer.lastSynthesizedParameters
        XCTAssertEqual(abortCue, .emergencyAbortTrip)
        XCTAssertEqual(abortParams?.frequencyHz, 1200.0)
        XCTAssertEqual(abortParams?.waveform, .saw)

        await bridge.stopObserving()
        let isObservingAfterStop = await bridge.isObserving
        XCTAssertFalse(isObservingAfterStop)
    }

    func testTelemetryIngestionAlerts() async throws {
        let synthesizer = TacticalToneSynthesizer()
        let bridge = SVSBridge(synthesizer: synthesizer)

        let criticalFrame = TelemetryFrame(
            timestampNanoseconds: 1000,
            sequenceNumber: 1,
            subsystem: .interlock,
            health: .critical,
            interlockState: .emergencyAbort,
            payloadSize: 64
        )

        try await bridge.ingestTelemetry(criticalFrame)
        let cue = await synthesizer.currentActiveCue
        XCTAssertEqual(cue, .emergencyAbortTrip)

        let permissiveFrame = TelemetryFrame(
            timestampNanoseconds: 2000,
            sequenceNumber: 2,
            subsystem: .interlock,
            health: .nominal,
            interlockState: .permissiveGranted,
            payloadSize: 64
        )

        try await bridge.ingestTelemetry(permissiveFrame)
        let permissiveCue = await synthesizer.currentActiveCue
        XCTAssertEqual(permissiveCue, .permissivePulse)
    }
}
