import CScramKAudioRealtime
import Foundation

public enum AudioOutputPhase: Sendable, Equatable {
    case disabled, enabling, enabled, disabling, unavailable
}

public enum AudioCueDisposition: Sendable, Equatable {
    case queued(sequence: UInt32)
    case coalesced
    case suppressedDisabled
    case suppressedMuted
    case suppressedPriority
    case queueFull
}

public struct AudioOutputStatus: Sendable, Equatable {
    public let phase: AudioOutputPhase
    public let isMuted: Bool
    public let masterGainDecibels: Double
    /// Render-observed catalog cue. Nil also covers custom tones and unavailable output.
    public let renderingCue: ToneCue?
    public let lastDisposition: AudioCueDisposition?
    public let lastError: ScramKAudioError?
    public let cleanupError: ScramKAudioError?
}

/// Fixed internal source format. Downstream device conversion is AVAudioEngine-owned.
struct AudioRenderConfiguration: Sendable {
    let sampleRate: Double
    let channels: UInt32
    let maximumFrames: UInt32

    static let output = AudioRenderConfiguration(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
}

struct ToneProgram: Sendable {
    let cue: ToneCue?
    let first: ToneParameters
    let secondFrequency: Double
    let segments: UInt32

    static func make(cue: ToneCue) -> ToneProgram {
        func program(_ frequency: Double, _ seconds: Double, _ peak: Float,
                     _ waveform: WaveformType = .sine, second: Double? = nil,
                     segments: UInt32 = 1) -> ToneProgram {
            ToneProgram(cue: cue, first: ToneParameters(frequencyHz: frequency,
                durationSeconds: seconds, amplitude: peak, waveform: waveform),
                secondFrequency: second ?? frequency, segments: segments)
        }
        switch cue {
        case .armedPulse: return program(440, 0.15, 0.501187234)
        case .permissivePulse: return program(880, 0.20, 0.630957344)
        case .emergencyAbortTrip: return program(1200, 0.50, 0.891250938, .saw)
        case .masterCaution: return program(660, 0.25, 0.501187234, second: 880, segments: 2)
        case .masterWarning: return program(880, 0.125, 0.630957344, second: 660, segments: 8)
        case .altitudeAlert: return program(500, 0.30, 0.6)
        case .terrainProximity: return program(1000, 0.80, 0.9, .saw)
        case .ping: return program(880, 0.10, 0.4)
        }
    }

    static func custom(_ parameters: ToneParameters) -> ToneProgram {
        ToneProgram(cue: nil, first: parameters, secondFrequency: parameters.frequencyHz, segments: 1)
    }

    func command(configuration: AudioRenderConfiguration, epoch: UInt32, sequence: UInt32) throws -> TARTCommand {
        let rate = configuration.sampleRate
        guard rate.isFinite, rate >= 8000, rate <= 192_000,
              configuration.channels == 1 || configuration.channels == 2,
              configuration.maximumFrames > 0, configuration.maximumFrames <= 16_384 else {
            throw ScramKAudioError.unsupportedFormat
        }
        for frequency in [first.frequencyHz, secondFrequency] {
            guard frequency.isFinite, frequency > 20, frequency < 20_000 else {
                throw ScramKAudioError.invalidFrequency(frequency)
            }
            guard frequency < rate / 2 else { throw ScramKAudioError.unsupportedFrequencyForFormat }
        }
        guard first.durationSeconds.isFinite, first.durationSeconds >= 0.010,
              first.durationSeconds * Double(segments) <= 10 else { throw ScramKAudioError.invalidDuration }
        guard first.amplitude.isFinite, first.amplitude >= 0, first.amplitude <= 1 else {
            throw ScramKAudioError.invalidAmplitude
        }
        guard epoch > 0, sequence > 0 else { throw ScramKAudioError.generationExhausted }
        let segmentFrames = UInt32((first.durationSeconds * rate).rounded())
        let fadeFrames = UInt32((0.005 * rate).rounded())
        guard segmentFrames >= 2 * fadeFrames else { throw ScramKAudioError.invalidDuration }
        var command = TARTCommand()
        command.epoch = epoch
        command.sequence = sequence
        command.cue_id = cue?.audioID ?? 9
        command.frequency_a = first.frequencyHz
        command.frequency_b = secondFrequency
        command.segment_frames = segmentFrames
        command.segment_count = segments
        command.peak = first.amplitude
        switch first.waveform {
        case .sine: command.waveform = UInt32(TART_SINE)
        case .saw: command.waveform = UInt32(TART_SAW)
        case .square: command.waveform = UInt32(TART_SQUARE)
        }
        command.attack_frames = fadeFrames
        command.release_frames = fadeFrames
        command.total_frames = segmentFrames * segments
        return command
    }
}

extension ToneCue {
    var audioPriority: UInt32 {
        switch self {
        case .emergencyAbortTrip: 4
        case .masterWarning: 3
        case .masterCaution: 2
        default: 1
        }
    }

    var audioID: UInt32 {
        switch self {
        case .armedPulse: 1
        case .permissivePulse: 2
        case .emergencyAbortTrip: 3
        case .masterCaution: 4
        case .masterWarning: 5
        case .altitudeAlert: 6
        case .terrainProximity: 7
        case .ping: 8
        }
    }

    static func fromAudioID(_ id: UInt32) -> ToneCue? {
        switch id {
        case 1: .armedPulse
        case 2: .permissivePulse
        case 3: .emergencyAbortTrip
        case 4: .masterCaution
        case 5: .masterWarning
        case 6: .altitudeAlert
        case 7: .terrainProximity
        case 8: .ping
        default: nil
        }
    }
}
