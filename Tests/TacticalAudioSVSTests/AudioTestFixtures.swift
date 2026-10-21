import CTacticalAudioRealtime
import Foundation
@testable import TacticalAudioSVS

/// Weak ownership observation without a mutable local or newer weak-let syntax.
final class AudioWeakStorageProbe {
    weak var value: AudioRealtimeStorage?
    init(_ value: AudioRealtimeStorage?) { self.value = value }
}

/// CPU-only fixture. Never constructs an AVAudioEngine or queries a device.
final class AudioCPUFixture {
    let storage: AudioRealtimeStorage
    let configuration: AudioRenderConfiguration

    init(rate: Double = 48_000, channels: UInt32 = 2, gainDecibels: Double = 0) throws {
        configuration = AudioRenderConfiguration(sampleRate: rate, channels: channels, maximumFrames: 4096)
        storage = try AudioRealtimeStorage.cpuForTesting(configuration: configuration)
        tart_prepare_waveforms(storage.pointer)
        tart_mark_producer_attached(storage.pointer)
        control(epoch: 1)
        tart_publish_gain(storage.pointer, Float(pow(10, gainDecibels / 20)))
        _ = try render(frames: Int((rate * 0.005).rounded())) // Settle only the master ramp.
    }

    deinit {
        tart_mark_producer_detached(storage.pointer)
        tart_mark_callback_retired(storage.pointer) // This fixture never installs a callback.
    }

    func control(epoch: UInt32, muted: Bool = false, enabled: Bool = true) {
        storage.control(epoch: epoch, enabled: enabled, muted: muted)
    }

    func enqueue(_ cue: ToneCue, epoch: UInt32 = 1, sequence: UInt32 = 1) throws -> UInt32 {
        var command = try ToneProgram.make(cue: cue).command(configuration: configuration,
                                                            epoch: epoch, sequence: sequence)
        return tart_try_enqueue(storage.pointer, &command)
    }

    func render(frames: Int) throws -> [[Float]] {
        try Self.render(storage: storage, frames: frames)
    }

    static func render(storage: AudioRealtimeStorage, frames: Int, snapshot: TARTInputSnapshot? = nil) throws -> [[Float]] {
        guard frames >= 0, frames <= Int(storage.configuration.maximumFrames) else {
            throw TacticalAudioError.unsupportedFormat
        }
        var left = [Float](repeating: .nan, count: max(1, frames))
        var right = left
        let count = storage.configuration.channels
        let result = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var planes = (
                    TARTPlane(samples: l.baseAddress, capacity_samples: UInt32(l.count), stride: 1),
                    TARTPlane(samples: r.baseAddress, capacity_samples: UInt32(r.count), stride: 1)
                )
                return withUnsafePointer(to: &planes) {
                    $0.withMemoryRebound(to: TARTPlane.self, capacity: 2) {
                        if let snapshot {
                            return tart_render_snapshot_for_testing(storage.pointer, UInt32(frames), $0, count, snapshot)
                        }
                        return tart_render(storage.pointer, UInt32(frames), $0, count)
                    }
                }
            }
        }
        guard result == UInt32(TART_OK) else { throw TacticalAudioError.unsupportedFormat }
        return count == 1 ? [Array(left.prefix(frames))]
            : [Array(left.prefix(frames)), Array(right.prefix(frames))]
    }

    func renderAll(frames: Int, chunk: Int = 256) throws -> [Float] {
        guard frames >= 0, chunk > 0, chunk <= Int(configuration.maximumFrames) else {
            throw TacticalAudioError.unsupportedFormat
        }
        var samples: [Float] = []
        var remaining = frames
        while remaining > 0 {
            let count = min(chunk, remaining)
            samples.append(contentsOf: try render(frames: count)[0])
            remaining -= count
        }
        return samples
    }
}

/// Actor lifecycle double with the production C storage/lease; no graph or devices.
actor AudioGraphDouble: AudioGraphDriving {
    private var storage: AudioRealtimeStorage?
    private var lease: NSObject?
    private var invalidated: (@Sendable (UInt64) async -> Void)?
    private var generation: UInt64 = 0
    private var fencedThrough: UInt64 = 0
    private enum Event: Hashable { case start, stopEntered, stopFinished }
    private var events: Set<Event> = []
    private var waiters: [Event: [UUID: AudioWaitSignal]] = [:]
    private let startRelease = AudioWaitSignal()
    private let stopRelease = AudioWaitSignal()
    private var startupFailure: TacticalAudioError?
    private var stopFailure: TacticalAudioError?
    private let holdStart: Bool
    private let holdStop: Bool
    private let retireOnStop: Bool
    private let startError: TacticalAudioError?
    private let stopError: TacticalAudioError?
    private let watchdog: Duration
    private(set) var startCount = 0

    init(holdStart: Bool = false, holdStop: Bool = false, retireOnStop: Bool = true,
         startError: TacticalAudioError? = nil, stopError: TacticalAudioError? = nil,
         watchdog: Duration = .seconds(2)) {
        self.holdStart = holdStart
        self.holdStop = holdStop
        self.retireOnStop = retireOnStop
        self.startError = startError
        self.stopError = stopError
        self.watchdog = watchdog
    }

    func start(storage: AudioRealtimeStorage, generation: UInt64,
               invalidated: @escaping @Sendable (UInt64) async -> Void) async throws {
        startCount += 1
        if let startError {
            tart_mark_callback_retired(storage.pointer)
            startupFailure = startError
            reject(.start, error: startError)
            throw startError
        }
        guard lease == nil, generation > fencedThrough else {
            tart_mark_callback_retired(storage.pointer)
            throw TacticalAudioError.cleanupIncomplete
        }
        tart_prepare_waveforms(storage.pointer)
        self.storage = storage
        self.generation = generation
        self.invalidated = invalidated
        lease = tart_create_retirement_marker_for_testing(storage.pointer)
        guard lease != nil else { throw TacticalAudioError.engineInitializationFailed }
        emit(.start)
        if holdStart {
            do { try await startRelease.wait(timeout: watchdog) }
            catch {
                let failure = (error as? TacticalAudioError) ?? .operationCancelled
                startupFailure = failure
                lease = nil
                rejectAll(failure)
                throw failure
            }
        }
        guard generation > fencedThrough else { throw TacticalAudioError.staleGeneration }
    }

    func waitForStart(timeout: Duration = .seconds(2)) async throws { try await wait(.start, timeout: timeout) }
    func waitForStopEntered(timeout: Duration = .seconds(2)) async throws { try await wait(.stopEntered, timeout: timeout) }
    func waitForStop(timeout: Duration = .seconds(2)) async throws { try await wait(.stopFinished, timeout: timeout) }

    nonisolated func releaseStart() { startRelease.succeed() }
    nonisolated func releaseStop() { stopRelease.succeed() }
    // Safe in synchronous test defer: release held workers BEFORE any teardown await.
    nonisolated func releaseAllGates() { startRelease.succeed(); stopRelease.succeed() }

    func stop(generation: UInt64) async -> TacticalAudioError? {
        releaseStart()
        fencedThrough = max(fencedThrough, generation)
        emit(.stopEntered)
        if holdStop, lease != nil {
            do { try await stopRelease.wait(timeout: watchdog) }
            catch {
                releaseAllGates()
                let failure = stopError ?? (error as? TacticalAudioError) ?? .operationCancelled
                stopFailure = failure
                rejectAll(failure)
                return failure
            }
        }
        if retireOnStop {
            lease = nil
            storage = nil
            invalidated = nil
            stopFailure = stopError
            if let stopError { rejectAll(stopError) }
            emit(.stopFinished)
            return stopError
        }
        let failure: TacticalAudioError? = lease == nil ? nil : .cleanupIncomplete
        stopFailure = failure
        if let failure { rejectAll(failure) }
        emit(.stopFinished)
        return failure
    }

    func finishRetirement() {
        fencedThrough = max(fencedThrough, generation)
        startRelease.fail(.observationStopped)
        stopRelease.fail(.observationStopped)
        releaseAllGates()
        lease = nil
        storage = nil
        invalidated = nil
        rejectAll(.observationStopped)
        stopFailure = nil
        emit(.stopFinished)
    }

    private func emit(_ event: Event) {
        events.insert(event)
        let signals = waiters.removeValue(forKey: event) ?? [:]
        for signal in signals.values { signal.succeed() }
    }

    private func reject(_ event: Event, error: TacticalAudioError) {
        let signals = waiters.removeValue(forKey: event) ?? [:]
        for signal in signals.values { signal.fail(error) }
    }

    private func rejectAll(_ error: TacticalAudioError) {
        let pending = waiters
        waiters.removeAll()
        for signals in pending.values { for signal in signals.values { signal.fail(error) } }
    }

    private func wait(_ event: Event, timeout: Duration) async throws {
        if event == .start, let startupFailure { throw startupFailure }
        if event != .start, let stopFailure { throw stopFailure }
        if events.contains(event) { return }
        let id = UUID()
        let signal = AudioWaitSignal()
        waiters[event, default: [:]][id] = signal
        defer { waiters[event]?.removeValue(forKey: id) }
        try await signal.wait(timeout: timeout)
    }

    func triggerDeviceChange() async {
        guard let storage, let invalidated else { return }
        tart_mark_device_changed(storage.pointer)
        await invalidated(generation)
    }
}
