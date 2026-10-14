import AVFoundation
import CoreAudio
import Foundation
import TacticalCore

/// Audio waveform types for tactical synthesis.
public enum WaveformType: String, Sendable, Hashable, Codable {
    case sine = "SINE"
    case saw = "SAW"
    case square = "SQUARE"
}

/// Standard tactical auditory alerts and annunciator tones.
public enum ToneCue: String, Sendable, Hashable, Codable {
    case armedPulse = "ARMED_PULSE"
    case permissivePulse = "PERMISSIVE_PULSE"
    case emergencyAbortTrip = "EMERGENCY_ABORT_TRIP"
    case masterCaution = "CAUTION"
    case masterWarning = "WARNING"
    case altitudeAlert = "ALTITUDE_ALERT"
    case terrainProximity = "TERRAIN"
    case ping = "PING"
}

/// Parameters for synthetic audio tone generation.
public struct ToneParameters: Sendable, Hashable, Codable {
    public let frequencyHz: Double
    public let durationSeconds: Double
    public let amplitude: Float
    public let waveform: WaveformType

    public init(
        frequencyHz: Double,
        durationSeconds: Double,
        amplitude: Float,
        waveform: WaveformType = .sine
    ) {
        self.frequencyHz = frequencyHz
        self.durationSeconds = durationSeconds
        self.amplitude = max(0.0, min(1.0, amplitude))
        self.waveform = waveform
    }
}

/// Audio errors encountered during tone generation or hardware bridging.
public enum TacticalAudioError: Error, Sendable, Equatable {
    case engineInitializationFailed
    case invalidFrequency(Double)
    case synthesisPipelineOffline
}

/// Actor managing real-time tone generation and CoreAudio routing.
public actor TacticalToneSynthesizer {
    private var isMuted: Bool
    private var activeCue: ToneCue?
    public private(set) var lastSynthesizedParameters: ToneParameters?
    public private(set) var totalTonesSynthesized: UInt64

    public init() {
        self.isMuted = false
        self.activeCue = nil
        self.lastSynthesizedParameters = nil
        self.totalTonesSynthesized = 0
    }

    /// Current active annunciator tone cue.
    public var currentActiveCue: ToneCue? {
        activeCue
    }

    /// Configure mute state.
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }

    /// Trigger discrete tactical tone cue.
    public func playCue(_ cue: ToneCue) throws {
        guard !isMuted else { return }
        self.activeCue = cue

        let params = parameters(for: cue)
        try synthesizeTone(parameters: params)
    }

    /// Halt all active auditory cues.
    public func stop() {
        self.activeCue = nil
    }

    /// Synthesize deterministic tone with specified parameters.
    public func synthesizeTone(parameters: ToneParameters) throws {
        guard parameters.frequencyHz > 20.0 && parameters.frequencyHz < 20_000.0 else {
            throw TacticalAudioError.invalidFrequency(parameters.frequencyHz)
        }
        self.lastSynthesizedParameters = parameters
        self.totalTonesSynthesized += 1
    }

    private func parameters(for cue: ToneCue) -> ToneParameters {
        switch cue {
        case .armedPulse:
            return ToneParameters(frequencyHz: 440.0, durationSeconds: 0.15, amplitude: 0.7, waveform: .sine)
        case .permissivePulse:
            return ToneParameters(frequencyHz: 880.0, durationSeconds: 0.20, amplitude: 0.8, waveform: .sine)
        case .emergencyAbortTrip:
            return ToneParameters(frequencyHz: 1200.0, durationSeconds: 0.50, amplitude: 1.0, waveform: .saw)
        case .masterCaution:
            return ToneParameters(frequencyHz: 750.0, durationSeconds: 0.50, amplitude: 0.8, waveform: .sine)
        case .masterWarning:
            return ToneParameters(frequencyHz: 1200.0, durationSeconds: 1.00, amplitude: 1.0, waveform: .saw)
        case .altitudeAlert:
            return ToneParameters(frequencyHz: 500.0, durationSeconds: 0.30, amplitude: 0.6, waveform: .sine)
        case .terrainProximity:
            return ToneParameters(frequencyHz: 1000.0, durationSeconds: 0.80, amplitude: 0.9, waveform: .saw)
        case .ping:
            return ToneParameters(frequencyHz: 880.0, durationSeconds: 0.10, amplitude: 0.4, waveform: .sine)
        }
    }
}
