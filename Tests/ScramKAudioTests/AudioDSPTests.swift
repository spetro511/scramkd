import CScramKAudioRealtime
import Foundation
@testable import ScramKAudio
import XCTest

final class AudioDSPTests: XCTestCase {
    func testApprovedCatalogAndLayouts() throws {
        XCTAssertEqual(MemoryLayout<TARTConfig>.size, 16)
        XCTAssertEqual(MemoryLayout<TARTCommand>.size, 64)
        XCTAssertEqual(MemoryLayout<TARTPlane>.size, 16)
        let config = AudioRenderConfiguration.output
        let cases: [(ToneCue, Double, Double, UInt32, UInt32, Float)] = [
            (.armedPulse, 440, 440, 7200, 1, 0.501187234),
            (.permissivePulse, 880, 880, 9600, 1, 0.630957344),
            (.emergencyAbortTrip, 1200, 1200, 24000, 1, 0.891250938),
            (.masterCaution, 660, 880, 12000, 2, 0.501187234),
            (.masterWarning, 880, 660, 6000, 8, 0.630957344)
        ]
        for (cue, a, b, frames, segments, peak) in cases {
            let command = try ToneProgram.make(cue: cue).command(configuration: config, epoch: 1, sequence: 1)
            XCTAssertEqual(command.frequency_a, a)
            XCTAssertEqual(command.frequency_b, b)
            XCTAssertEqual(command.segment_frames, frames)
            XCTAssertEqual(command.segment_count, segments)
            XCTAssertEqual(command.total_frames, frames * segments)
            XCTAssertEqual(command.peak, peak, accuracy: 0.0000001)
            XCTAssertEqual(command.attack_frames, 240)
            XCTAssertEqual(command.release_frames, 240)
        }
    }

    func testSineFrequencyEnvelopeDurationAndStereoParity() throws {
        let fixture = try AudioCPUFixture()
        XCTAssertTrue(tart_atomics_are_lock_free(fixture.storage.pointer))
        XCTAssertEqual(try fixture.enqueue(.armedPulse), UInt32(TART_OK))
        let first = try fixture.render(frames: 1024)
        XCTAssertEqual(first[0], first[1]) // Phase advances once per frame, not channel.
        let rest = try fixture.renderAll(frames: 7200 - 1024 + 256)
        let samples = first[0] + rest
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[7199], 0)
        XCTAssertTrue(samples[7200...].allSatisfy { $0 == 0 })
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, 0.5011873)
        let steady = Array(samples[240..<5040])
        XCTAssertEqual(magnitude(steady, frequency: 440), 0.501187234, accuracy: 0.00001)
        XCTAssertLessThan(magnitude(steady, frequency: 880), 0.00001)
        XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 1)
        XCTAssertEqual(UInt32(truncatingIfNeeded: tart_load_progress(fixture.storage.pointer)), 0)
    }

    func testChunkIndependentPhaseAndGainRamp() throws {
        let a = try AudioCPUFixture(gainDecibels: -24)
        let b = try AudioCPUFixture(gainDecibels: -24)
        XCTAssertEqual(try a.enqueue(.permissivePulse), UInt32(TART_OK))
        XCTAssertEqual(try b.enqueue(.permissivePulse), UInt32(TART_OK))
        tart_publish_gain(a.storage.pointer, 1)
        tart_publish_gain(b.storage.pointer, 1)
        XCTAssertEqual(try a.renderAll(frames: 10000, chunk: 31),
                       try b.renderAll(frames: 10000, chunk: 1024))
    }

    func testDefaultMasterAttenuationDoesNotChangeOscillatorProfile() throws {
        let fixture = try AudioCPUFixture(gainDecibels: -24)
        _ = try fixture.enqueue(.armedPulse)
        let samples = try fixture.renderAll(frames: 6000)
        XCTAssertEqual(magnitude(Array(samples[240..<5040]), frequency: 440), pow(10, -30.0 / 20),
                       accuracy: 0.000001)
    }

    func testCautionAndWarningSegmentEndpointsAndFrequencies() throws {
        for cue in [ToneCue.masterCaution, .masterWarning] {
            let fixture = try AudioCPUFixture()
            let program = ToneProgram.make(cue: cue)
            let command = try program.command(configuration: fixture.configuration, epoch: 1, sequence: 1)
            XCTAssertEqual(try fixture.enqueue(cue), UInt32(TART_OK))
            let samples = try fixture.renderAll(frames: Int(command.total_frames) + 256)
            for segment in 0..<Int(command.segment_count) {
                let start = segment * Int(command.segment_frames)
                let end = start + Int(command.segment_frames)
                XCTAssertEqual(samples[start], 0)
                XCTAssertEqual(samples[end - 1], 0)
                let frequency = segment.isMultiple(of: 2) ? command.frequency_a : command.frequency_b
                // Direct model checks phase continuity and the selected segment frequency.
                let i = start + 300
                var cycles = 0.0
                for prior in 0..<segment {
                    let f = prior.isMultiple(of: 2) ? command.frequency_a : command.frequency_b
                    cycles += f * Double(command.segment_frames) / 48000
                }
                cycles += frequency * 300 / 48000
                XCTAssertEqual(Double(samples[i]), sin(2 * .pi * cycles) * Double(command.peak), accuracy: 0.00001)
            }
            XCTAssertTrue(samples[Int(command.total_frames)...].allSatisfy { $0 == 0 })
        }
    }

    func testBandLimitedSawAndSquarePeakAndHarmonics() throws {
        for waveform in [WaveformType.saw, .square] {
            let fixture = try AudioCPUFixture()
            let program = ToneProgram.custom(ToneParameters(frequencyHz: 1200, durationSeconds: 0.5,
                                                            amplitude: 0.891250938, waveform: waveform))
            var command = try program.command(configuration: fixture.configuration, epoch: 1, sequence: 1)
            XCTAssertEqual(tart_try_enqueue(fixture.storage.pointer, &command), UInt32(TART_OK))
            let samples = try fixture.renderAll(frames: 6000)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.891251 })
            let steady = Array(samples[480..<5280])
            let fundamental = magnitude(steady, frequency: 1200)
            XCTAssertGreaterThan(fundamental, 0.1)
            if waveform == .square {
                XCTAssertLessThan(magnitude(steady, frequency: 2400), 0.00001)
            } else {
                XCTAssertEqual(magnitude(steady, frequency: 2400) / fundamental, (0.9 / 2) / 0.95,
                               accuracy: 0.00001)
            }
            XCTAssertLessThan(magnitude(steady, frequency: 600), 0.00001)
        }
    }

    func testSaturationUrgentAbortAndDuplicateDoNotRestartClock() throws {
        let fixture = try AudioCPUFixture()
        for sequence in 1...16 {
            XCTAssertEqual(try fixture.enqueue(.armedPulse, sequence: UInt32(sequence)), UInt32(TART_OK))
        }
        XCTAssertEqual(try fixture.enqueue(.ping, sequence: 17), UInt32(TART_FULL))
        fixture.control(epoch: 2)
        tart_publish_abort(fixture.storage.pointer, 2, 18)
        _ = try fixture.render(frames: 512)
        XCTAssertEqual(fixture.storage.observedCue(epoch: 2), .emergencyAbortTrip)
        fixture.control(epoch: 3)
        tart_publish_abort(fixture.storage.pointer, 3, 19)
        _ = try fixture.render(frames: 512)
        XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 1)
        _ = try fixture.renderAll(frames: 24000 - 1024)
        XCTAssertNil(fixture.storage.observedCue(epoch: 3))
        XCTAssertTrue(try fixture.render(frames: 256)[0].allSatisfy { $0 == 0 })
    }

    func testPriorityNewestRoutineAndComplementaryPreemptionAreBounded() throws {
        let fixture = try AudioCPUFixture()
        _ = try fixture.enqueue(.armedPulse)
        _ = try fixture.enqueue(.permissivePulse, sequence: 2)
        _ = try fixture.render(frames: 512)
        XCTAssertEqual(fixture.storage.observedCue(epoch: 1), .permissivePulse)
        _ = try fixture.enqueue(.masterWarning, sequence: 3)
        let transition = try fixture.render(frames: 512)[0]
        XCTAssertTrue(transition.allSatisfy { abs($0) <= 0.630958 })
        _ = try fixture.enqueue(.ping, sequence: 4)
        _ = try fixture.render(frames: 512)
        XCTAssertEqual(fixture.storage.observedCue(epoch: 1), .masterWarning)
        XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 2)
    }

    func testMuteStopAndTerminalDeviceFaultFlushWithoutReplay() throws {
        let fixture = try AudioCPUFixture()
        _ = try fixture.enqueue(.terrainProximity)
        _ = try fixture.render(frames: 512)
        fixture.control(epoch: 2, muted: true)
        XCTAssertTrue(try fixture.render(frames: 256)[0].allSatisfy { $0 == 0 })
        fixture.control(epoch: 2)
        XCTAssertTrue(try fixture.render(frames: 256)[0].allSatisfy { $0 == 0 })
        _ = try fixture.enqueue(.ping, epoch: 2, sequence: 2)
        fixture.control(epoch: 3) // stop, not a gate relock
        XCTAssertTrue(try fixture.render(frames: 256)[0].allSatisfy { $0 == 0 })
        _ = try fixture.enqueue(.ping, epoch: 3, sequence: 3)
        tart_mark_device_changed(fixture.storage.pointer)
        XCTAssertTrue(try fixture.render(frames: 256)[0].allSatisfy { $0 == 0 })
        fixture.control(epoch: 4)
        XCTAssertTrue(try fixture.render(frames: 256)[0].allSatisfy { $0 == 0 })
    }

    func testInvalidBufferIsRejectedWithoutWriteAndZeroFramesDoNotStartCue() throws {
        let fixture = try AudioCPUFixture(channels: 1)
        _ = try fixture.enqueue(.ping)
        XCTAssertEqual(try fixture.render(frames: 0), [[]])
        XCTAssertEqual(tart_load_started_count(fixture.storage.pointer), 0)
        var values = [Float](repeating: 123, count: 8)
        let result = values.withUnsafeMutableBufferPointer { buffer in
            var plane = TARTPlane(samples: buffer.baseAddress, capacity_samples: 8, stride: 1)
            return tart_render(fixture.storage.pointer, 9, &plane, 1)
        }
        XCTAssertEqual(result, UInt32(TART_INVALID))
        XCTAssertEqual(values, [Float](repeating: 123, count: 8))
    }

    func testRateDurationAndNonfiniteValidation() throws {
        for rate in [44100.0, 48000, 96000] {
            let config = AudioRenderConfiguration(sampleRate: rate, channels: 1, maximumFrames: 4096)
            let command = try ToneProgram.make(cue: .armedPulse).command(configuration: config, epoch: 1, sequence: 1)
            XCTAssertEqual(command.total_frames, UInt32((rate * 0.15).rounded()))
        }
        let bad: [ToneParameters] = [
            .init(frequencyHz: .nan, durationSeconds: 0.2, amplitude: 0.5),
            .init(frequencyHz: 440, durationSeconds: .infinity, amplitude: 0.5),
            .init(frequencyHz: 440, durationSeconds: 0.001, amplitude: 0.5),
            .init(frequencyHz: 440, durationSeconds: 0.2, amplitude: .nan)
        ]
        for parameters in bad {
            XCTAssertThrowsError(try ToneProgram.custom(parameters).command(configuration: .output, epoch: 1, sequence: 1))
        }
        let lowRate = AudioRenderConfiguration(sampleRate: 8000, channels: 1, maximumFrames: 256)
        XCTAssertThrowsError(try ToneProgram.custom(.init(frequencyHz: 5000, durationSeconds: 0.2, amplitude: 1))
            .command(configuration: lowRate, epoch: 1, sequence: 1))
    }

    func testCallbackRetirementAndProducerDetachAreBothRequired() throws {
        let storage = try AudioRealtimeStorage.cpuForTesting(configuration: .output)
        tart_mark_producer_attached(storage.pointer)
        var lease: NSObject? = tart_create_retirement_marker_for_testing(storage.pointer)
        XCTAssertNotNil(lease)
        XCTAssertFalse(tart_is_quiescent(storage.pointer))
        lease = nil
        XCTAssertTrue(tart_callback_is_retired(storage.pointer))
        XCTAssertFalse(tart_is_quiescent(storage.pointer))
        tart_mark_producer_detached(storage.pointer)
        XCTAssertTrue(tart_is_quiescent(storage.pointer)) // Control actor frees after all handles release.
    }

    private func magnitude(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48000
            real += Double(sample) * cos(phase)
            imaginary -= Double(sample) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(samples.count)
    }
}
