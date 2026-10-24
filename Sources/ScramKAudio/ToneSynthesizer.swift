import CScramKAudioRealtime
import Foundation
import ScramKCore

/// Audio waveform types for supervisor annunciator synthesis.
public enum WaveformType: String, Sendable, Hashable, Codable {
    case sine = "SINE"
    case saw = "SAW"
    case square = "SQUARE"
}

/// Standard supervisor auditory alerts and annunciator tones.
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
        // Preserve invalid inputs for typed boundary validation, rather than hiding NaN.
        self.amplitude = amplitude.isFinite ? max(0.0, min(1.0, amplitude)) : amplitude
        self.waveform = waveform
    }
}

/// Audio errors encountered during tone generation or hardware bridging.
public enum ScramKAudioError: Error, Sendable, Equatable {
    case engineInitializationFailed
    case invalidFrequency(Double)
    case synthesisPipelineOffline
    case invalidDuration
    case invalidAmplitude
    case invalidMasterGain
    case unsupportedFormat
    case unsupportedFrequencyForFormat
    case atomicsNotLockFree
    case generationExhausted
    case staleGeneration
    case operationInProgress
    case operationCancelled
    case deviceUnavailable
    case deviceChanged
    case cleanupIncomplete
    case graphStartFailed(String)
    case offlineRenderingFailed(String)
    case renderingFailed
    case observationGap
    case observationStopped
    case waitTimedOut
}

/// Serial command producer. No engine construction or slow graph call runs on this actor.
public actor ScramKToneSynthesizer {
    private let graph: any AudioGraphDriving
    private let reclamation: AudioReclamationControl
    private let configuration = AudioRenderConfiguration.output
    private var storage: AudioRealtimeStorage?
    private var retiringStorage: AudioRealtimeStorage?
    private var phase: AudioOutputPhase = .disabled
    private var isMuted = false
    private var masterGainDecibels: Double = -24
    private var activeCue: ToneCue?
    private var epoch: UInt32 = 1
    private var sequence: UInt32 = 0
    private var generation: UInt64 = 0
    private var graphGeneration: UInt64 = 0
    private var disableTask: Task<Void, Never>?
    private var pendingAbort: UInt64?
    private var renderedCount: UInt64 = 0
    private var lastDisposition: AudioCueDisposition?
    private var lastError: ScramKAudioError?
    private var lastCleanupError: ScramKAudioError?
    /// Legacy projection of the last validated request's first segment; not playback evidence.
    public private(set) var lastSynthesizedParameters: ToneParameters?
    public private(set) var totalToneRequests: UInt64 = 0

    /// Actual render-start count, not a count of selected or queued requests.
    public var totalTonesSynthesized: UInt64 {
        let current = storage.map { tart_load_started_count($0.pointer) } ?? 0
        let retiring = retiringStorage.map { tart_load_started_count($0.pointer) } ?? 0
        return saturatedAdd(saturatedAdd(renderedCount, current), retiring)
    }

    public init() {
        self.graph = AudioGraphOwner()
        self.reclamation = .output
    }

    init(graphDriver: any AudioGraphDriving) {
        self.graph = graphDriver
        self.reclamation = AudioReclamationControl()
    }

    deinit {
        let contexts = [storage, retiringStorage].compactMap { $0 }
        if !contexts.isEmpty {
            for context in contexts {
                context.control(epoch: 0, enabled: false, muted: true)
                tart_mark_producer_detached(context.pointer)
            }
            // Control ownership outlives the fallback. No callback owns a context;
            // the reclamation actor keeps any unconfirmed allocation quarantined.
            let owner = graph
            let stoppedGeneration = graphGeneration
            Task {
                _ = await owner.stop(generation: stoppedGeneration)
                withExtendedLifetime(contexts) {}
            }
        }
    }

    /// Caller must confirm the current local output and safe listening level first.
    /// This method does not alter the OS volume, route, input graph, or gate state.
    public func enableOutput() async throws {
        guard !Task.isCancelled else { throw ScramKAudioError.operationCancelled }
        guard phase != .enabling, phase != .disabling else { throw ScramKAudioError.operationInProgress }
        if retiringStorage != nil {
            await disableOutput() // Retry only retirement of the existing bounded slot.
            guard retiringStorage == nil else { throw ScramKAudioError.cleanupIncomplete }
            guard phase != .enabling, phase != .disabling else { throw ScramKAudioError.operationInProgress }
        }
        if phase == .enabled {
            if let failure = storage?.faultError { throw failure }
            return
        }
        guard storage == nil else { throw ScramKAudioError.cleanupIncomplete }
        guard generation < .max else { throw ScramKAudioError.generationExhausted }
        generation += 1
        let requestGeneration = generation
        graphGeneration = requestGeneration
        phase = .enabling
        lastError = nil
        lastCleanupError = nil
        let context: AudioRealtimeStorage
        do { context = try await reclamation.allocate(configuration: configuration) }
        catch {
            guard generation == requestGeneration else { throw ScramKAudioError.staleGeneration }
            phase = .unavailable
            let failure = (error as? ScramKAudioError) ?? .engineInitializationFailed
            lastError = failure
            throw failure
        }
        guard generation == requestGeneration, phase == .enabling else {
            // No graph/block was installed for this returned allocation.
            tart_mark_callback_retired(context.pointer)
            throw ScramKAudioError.staleGeneration
        }
        storage = context
        epoch = 1
        sequence = 0
        pendingAbort = nil
        phase = .enabling
        lastError = nil
        tart_mark_producer_attached(context.pointer)
        tart_publish_gain(context.pointer, Float(pow(10, masterGainDecibels / 20)))
        context.control(epoch: epoch, enabled: false, muted: isMuted)
        do {
            try await graph.start(storage: context, generation: requestGeneration) { [weak self] changed in
                await self?.deviceChanged(generation: changed)
            }
            guard !Task.isCancelled else { throw ScramKAudioError.operationCancelled }
            guard generation == requestGeneration, phase == .enabling, storage === context else {
                throw ScramKAudioError.staleGeneration
            }
            if let failure = context.faultError { throw failure }
            phase = .enabled
            context.control(epoch: epoch, enabled: true, muted: isMuted)
        } catch {
            context.control(epoch: 0, enabled: false, muted: true)
            tart_mark_producer_detached(context.pointer)
            let cleanupError = await graph.stop(generation: requestGeneration)
            guard generation == requestGeneration else { throw ScramKAudioError.staleGeneration }
            if storage === context {
                retiringStorage = context
                storage = nil
            }
            foldRetiringIfQuiescent()
            phase = .unavailable
            let failure = (error as? ScramKAudioError) ?? .graphStartFailed(String(describing: error))
            lastCleanupError = cleanupError
            lastError = failure
            throw failure // Cleanup failure must not replace the original start/cancel error.
        }
    }

    public func disableOutput() async {
        if let disableTask {
            await disableTask.value
            return
        }
        let stoppedGeneration = graphGeneration
        if generation < .max { generation += 1 }
        let completionGeneration = generation
        let context = storage ?? retiringStorage
        phase = .disabling
        context?.control(epoch: 0, enabled: false, muted: true)
        if let context { tart_mark_producer_detached(context.pointer) }
        if let storage { retiringStorage = storage }
        storage = nil // Count remains represented by retiringStorage throughout the await.
        activeCue = nil
        pendingAbort = nil
        let task = Task { [weak self, graph] in
            let cleanupError = await graph.stop(generation: stoppedGeneration)
            await self?.finishDisable(generation: completionGeneration, cleanupError: cleanupError)
            return
        }
        disableTask = task
        await task.value // Shared task includes actor finalization, not just backend stop.
    }

    private func finishDisable(generation expected: UInt64, cleanupError: ScramKAudioError?) {
        guard generation == expected else { return }
        foldRetiringIfQuiescent()
        let failure = cleanupError ?? (retiringStorage == nil ? nil : .cleanupIncomplete)
        phase = failure == nil ? .disabled : .unavailable
        lastCleanupError = failure
        lastError = failure
        disableTask = nil
    }

    private func foldRetiringIfQuiescent() {
        guard let retiringStorage, tart_is_quiescent(retiringStorage.pointer) else { return }
        // Retirement is monotonic: no later callback or producer can add starts.
        renderedCount = saturatedAdd(renderedCount, tart_load_started_count(retiringStorage.pointer))
        self.retiringStorage = nil
    }

    private func saturatedAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let sum = a.addingReportingOverflow(b)
        return sum.overflow ? .max : sum.partialValue
    }

    private func deviceChanged(generation changed: UInt64) async {
        guard graphGeneration == changed, let context = storage else { return }
        let expectedCompletion = generation == .max ? generation : generation + 1
        context.control(epoch: 0, enabled: false, muted: true)
        await disableOutput()
        guard generation == expectedCompletion, graphGeneration == changed else { return }
        phase = .unavailable
        if lastError == nil { lastError = .deviceChanged }
    }

    public func setMasterGain(decibels: Double) throws {
        guard decibels.isFinite, decibels <= 0 else { throw ScramKAudioError.invalidMasterGain }
        masterGainDecibels = decibels
        if let storage { tart_publish_gain(storage.pointer, Float(pow(10, decibels / 20))) }
    }

    public func outputStatus() -> AudioOutputStatus {
        let fault = storage?.faultError
        return AudioOutputStatus(phase: fault == nil ? phase : .unavailable, isMuted: isMuted,
            masterGainDecibels: masterGainDecibels,
            renderingCue: phase == .enabled && !isMuted ? storage?.observedCue(epoch: epoch) : nil,
            lastDisposition: lastDisposition, lastError: fault ?? lastError, cleanupError: lastCleanupError)
    }

    /// Last selected catalog request. This legacy property is not render or hearing evidence.
    public var currentActiveCue: ToneCue? {
        activeCue
    }

    /// Configure mute state.
    public func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        self.isMuted = muted
        if muted { invalidatePending() }
        else { storage?.control(epoch: epoch, enabled: phase == .enabled, muted: false) }
    }

    /// Trigger discrete supervisor tone cue.
    public func playCue(_ cue: ToneCue) throws {
        _ = try enqueueCue(cue)
    }

    public func enqueueCue(_ cue: ToneCue) throws -> AudioCueDisposition {
        try submit(.make(cue: cue))
    }

    /// Halt all active auditory cues.
    public func stop() {
        self.activeCue = nil
        invalidatePending()
    }

    /// Validate and submit a custom program; output may be explicitly suppressed.
    public func synthesizeTone(parameters: ToneParameters) throws {
        _ = try submit(.custom(parameters))
    }

    private func submit(_ program: ToneProgram) throws -> AudioCueDisposition {
        // Validate even when output is disabled. Selection does not imply PCM generation.
        _ = try program.command(configuration: configuration, epoch: 1, sequence: 1)
        activeCue = program.cue
        lastSynthesizedParameters = program.first
        if totalToneRequests < .max { totalToneRequests += 1 }
        let disposition: AudioCueDisposition
        if isMuted { disposition = .suppressedMuted }
        else if phase != .enabled || storage == nil { disposition = .suppressedDisabled }
        else if let storage {
            if let failure = storage.faultError {
                lastError = failure
                lastDisposition = .suppressedDisabled
                throw failure
            }
            if let rendering = storage.observedCue(epoch: epoch),
               (program.cue?.audioPriority ?? 1) < rendering.audioPriority {
                lastDisposition = .suppressedPriority
                return .suppressedPriority
            }
            if program.cue == .emergencyAbortTrip {
                if let pendingAbort, tart_load_abort_ack(storage.pointer) != pendingAbort {
                    lastDisposition = .coalesced
                    return .coalesced
                }
                if storage.observedCue(epoch: epoch) == .emergencyAbortTrip {
                    lastDisposition = .coalesced
                    return .coalesced
                }
                invalidatePending()
                guard phase == .enabled else { throw ScramKAudioError.generationExhausted }
            }
            guard sequence < .max else {
                exhaustGeneration()
                throw ScramKAudioError.generationExhausted
            }
            sequence += 1
            if program.cue == .emergencyAbortTrip {
                let key = (UInt64(epoch) << 32) | UInt64(sequence)
                pendingAbort = key
                tart_publish_abort(storage.pointer, epoch, sequence)
                disposition = .queued(sequence: sequence)
            } else {
                var command = try program.command(configuration: configuration, epoch: epoch, sequence: sequence)
                let result = tart_try_enqueue(storage.pointer, &command)
                if result == UInt32(TART_FULL) { disposition = .queueFull }
                else if result == UInt32(TART_OK) { disposition = .queued(sequence: sequence) }
                else { throw ScramKAudioError.staleGeneration }
            }
        } else { disposition = .suppressedDisabled }
        lastDisposition = disposition
        return disposition
    }

    private func invalidatePending() {
        pendingAbort = nil
        guard storage != nil else { return }
        guard epoch < .max else { exhaustGeneration(); return }
        epoch += 1
        storage?.control(epoch: epoch, enabled: phase == .enabled, muted: isMuted)
    }

    private func exhaustGeneration() {
        phase = .unavailable
        lastError = .generationExhausted
        storage?.control(epoch: 0, enabled: false, muted: true)
    }

    // Deterministic exhaustion seam; no device graph is constructed by this method.
    func setEpochForTesting(_ value: UInt32) {
        guard phase == .enabled else { return }
        epoch = value
        storage?.control(epoch: epoch, enabled: true, muted: isMuted)
    }

    func realtimeStorageForTesting() -> AudioRealtimeStorage? { storage }
}
