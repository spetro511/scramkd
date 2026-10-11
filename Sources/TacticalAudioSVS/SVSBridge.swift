import Foundation
import TacticalCore

/// Synthetic Vision System (SVS) audio annunciator bridge.
public actor SVSBridge {
    private let synthesizer: TacticalToneSynthesizer
    private var lastProcessedSequence: UInt64

    public init(synthesizer: TacticalToneSynthesizer = TacticalToneSynthesizer()) {
        self.synthesizer = synthesizer
        self.lastProcessedSequence = 0
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
            try await synthesizer.playCue(.masterWarning)
        case .locked, .armed, .permissiveGranted:
            break
        }
    }

    /// Silence SVS auditory output.
    public func silence() async {
        await synthesizer.stop()
    }
}
