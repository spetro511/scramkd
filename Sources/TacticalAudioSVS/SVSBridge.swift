import Foundation
import TacticalCore

/// Synthetic Vision System (SVS) audio annunciator bridge subscribing to interlock state deltas.
public actor SVSBridge {
    private let synthesizer: TacticalToneSynthesizer
    private var lastProcessedSequence: UInt64
    private var observationTask: Task<Void, Never>?

    public init(synthesizer: TacticalToneSynthesizer = TacticalToneSynthesizer()) {
        self.synthesizer = synthesizer
        self.lastProcessedSequence = 0
        self.observationTask = nil
    }

    deinit {
        observationTask?.cancel()
    }

    /// Access underlying tone synthesizer.
    public var activeSynthesizer: TacticalToneSynthesizer {
        synthesizer
    }

    /// Whether an active gate observation task is running.
    public var isObserving: Bool {
        observationTask != nil
    }

    /// Subscribe to state deltas from a HardwareInterlockGate and emit CoreAudio frequency alert tones.
    public func startObserving(gate: HardwareInterlockGate) async {
        observationTask?.cancel()
        let stream = await gate.subscribeTransitions()
        self.observationTask = Task { [weak self] in
            for await record in stream {
                guard !Task.isCancelled, let self else { break }
                try? await self.handleTransition(from: record.from, to: record.to)
            }
        }
    }

    /// Halt gate transition observation.
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Route gate state transition to corresponding frequency alert tone.
    public func handleTransition(from: InterlockStatus, to: InterlockStatus) async throws {
        switch to {
        case .armed:
            try await synthesizer.playCue(.armedPulse)
        case .permissiveGranted:
            try await synthesizer.playCue(.permissivePulse)
        case .emergencyAbort:
            try await synthesizer.playCue(.emergencyAbortTrip)
        case .locked:
            break
        }
    }

    /// Ingest telemetry frame and trigger appropriate auditory alerts.
    public func ingestTelemetry(_ frame: TelemetryFrame) async throws {
        guard frame.sequenceNumber > lastProcessedSequence else { return }
        self.lastProcessedSequence = frame.sequenceNumber

        switch frame.health {
        case .critical:
            try await synthesizer.playCue(.masterWarning)
        case .degraded:
            try await synthesizer.playCue(.masterCaution)
        case .nominal, .offline:
            break
        }

        switch frame.interlockState {
        case .emergencyAbort:
            try await synthesizer.playCue(.emergencyAbortTrip)
        case .armed:
            try await synthesizer.playCue(.armedPulse)
        case .permissiveGranted:
            try await synthesizer.playCue(.permissivePulse)
        case .locked:
            break
        }
    }

    /// Silence SVS auditory output.
    public func silence() async {
        await synthesizer.stop()
    }
}
