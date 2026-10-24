import Foundation
import ScramKCore

/// Future-event annunciator. Gate events acknowledge transitions, not sustained conditions.
public actor SVSBridge {
    private let synthesizer: ScramKToneSynthesizer
    private var observationTask: Task<Void, Never>?
    private var observationGate: HardwareInterlockGate?
    private var observationID: UUID?
    private var binding = UUID()
    private var cursor: UInt64 = 0
    private var bindingRequested = false
    private var health: [SubsystemIdentifier: (sequence: UInt64, health: SubsystemHealth)] = [:]
    private var telemetryGateState: InterlockStatus?
    private var cursorWaiters: [UUID: (cursor: UInt64, signal: AudioWaitSignal)] = [:]
    private var observationFailure: (cursor: UInt64, error: ScramKAudioError)?
    public private(set) var lastError: ScramKAudioError?

    public init(synthesizer: ScramKToneSynthesizer = ScramKToneSynthesizer()) {
        self.synthesizer = synthesizer
    }

    deinit {
        observationTask?.cancel()
        for waiter in cursorWaiters.values { waiter.signal.fail(.observationStopped) }
    }

    public var activeSynthesizer: ScramKToneSynthesizer { synthesizer }
    public var isObserving: Bool { observationTask != nil }

    public func startObserving(gate: HardwareInterlockGate) async {
        let requestedBinding = UUID()
        binding = requestedBinding
        bindingRequested = true
        let previous = takeObservation()
        await settle(previous)
        guard binding == requestedBinding else { return }
        let observation = await gate.observeTransitions(historyLimit: 0)
        guard binding == requestedBinding else {
            await gate.unsubscribeObservation(id: observation.id)
            return
        }
        cursor = observation.snapshot.cursor
        health.removeAll(keepingCapacity: true)
        telemetryGateState = nil
        lastError = nil
        observationFailure = nil
        observationGate = gate
        observationID = observation.id
        observationTask = Task { [weak self] in
            for await transition in observation.transitions {
                guard !Task.isCancelled else { break }
                await self?.consume(transition, binding: requestedBinding, gate: gate)
            }
            // Also handles deinit cancellation; never holds self while awaiting the stream.
            await gate.unsubscribeObservation(id: observation.id)
            await self?.observationFinished(binding: requestedBinding)
        }
    }

    public func stopObserving() async {
        binding = UUID()
        bindingRequested = false
        let previous = takeObservation()
        await settle(previous)
    }

    private typealias PreviousObservation = (Task<Void, Never>?, HardwareInterlockGate?, UUID?)

    private func takeObservation() -> PreviousObservation {
        let previous = (observationTask, observationGate, observationID)
        observationTask?.cancel()
        observationTask = nil
        observationGate = nil
        observationID = nil
        rejectCursorWaiters(.observationStopped)
        return previous
    }

    private func settle(_ previous: PreviousObservation) async {
        if let gate = previous.1, let id = previous.2 { await gate.unsubscribeObservation(id: id) }
        await previous.0?.value
    }

    private func consume(_ transition: InterlockObservedTransition, binding expected: UUID,
                         gate: HardwareInterlockGate) async {
        guard binding == expected, !Task.isCancelled, transition.cursor > cursor else { return }
        if transition.cursor - cursor != 1 {
            lastError = .observationGap
            let snapshot = await gate.observationSnapshot(historyLimit: 0)
            guard binding == expected, !Task.isCancelled else { return }
            cursor = snapshot.cursor
            observationFailure = (transition.cursor, .observationGap)
            rejectCursorWaiters(.observationGap)
            return // Reconciliation is silent. Old pulses are never replayed.
        }
        do { try await handleTransition(from: transition.record.from, to: transition.record.to) }
        catch {
            guard binding == expected else { return }
            lastError = (error as? ScramKAudioError) ?? .synthesisPipelineOffline
            observationFailure = (transition.cursor, lastError ?? .synthesisPipelineOffline)
            rejectCursorWaiters(lastError ?? .synthesisPipelineOffline)
        }
        guard binding == expected else { return }
        cursor = transition.cursor
        resolveCursorWaiters()
    }

    public func handleTransition(from: InterlockStatus, to: InterlockStatus) async throws {
        guard from != to else { return }
        let cue: ToneCue
        switch to {
        case .armed: cue = .armedPulse
        case .permissiveGranted: cue = .permissivePulse
        case .emergencyAbort: cue = .emergencyAbortTrip
        case .locked:
            // One-shot broker relock must not cancel the accepted permissive acknowledgment.
            return
        }
        do { _ = try await synthesizer.enqueueCue(cue) }
        catch {
            lastError = (error as? ScramKAudioError) ?? .synthesisPipelineOffline
            rejectCursorWaiters(lastError ?? .synthesisPipelineOffline)
            throw error
        }
    }

    public func ingestTelemetry(_ frame: TelemetryFrame) async throws {
        if let previous = health[frame.subsystem], frame.sequenceNumber <= previous.sequence { return }
        let previousHealth = health[frame.subsystem]?.health
        health[frame.subsystem] = (frame.sequenceNumber, frame.health)
        do {
            if previousHealth != frame.health {
                switch frame.health {
                case .critical: _ = try await synthesizer.enqueueCue(.masterWarning)
                case .degraded: _ = try await synthesizer.enqueueCue(.masterCaution)
                case .nominal, .offline: break
                }
            }
            // Compatibility for unbound offline telemetry. While binding/bound, only
            // authoritative cursor events may request a gate cue.
            if !bindingRequested, telemetryGateState != frame.interlockState {
                let previous = telemetryGateState ?? .locked
                telemetryGateState = frame.interlockState
                try await handleTransition(from: previous, to: frame.interlockState)
            }
        } catch {
            lastError = (error as? ScramKAudioError) ?? .synthesisPipelineOffline
            rejectCursorWaiters(lastError ?? .synthesisPipelineOffline)
            throw error
        }
    }

    public func silence() async { await synthesizer.stop() }

    private func resolveCursorWaiters() {
        let completed = cursorWaiters.filter { $0.value.cursor <= cursor }
        for (id, waiter) in completed {
            cursorWaiters.removeValue(forKey: id)
            waiter.signal.succeed()
        }
    }

    private func rejectCursorWaiters(_ error: ScramKAudioError) {
        let pending = cursorWaiters.values.map { $0.signal }
        cursorWaiters.removeAll()
        for signal in pending { signal.fail(error) }
    }

    private func observationFinished(binding expected: UUID) {
        guard binding == expected else { return }
        observationTask = nil
        observationGate = nil
        observationID = nil
        bindingRequested = false
        rejectCursorWaiters(.observationStopped)
    }

    /// Deterministic test handshake; production never waits for audio completion.
    func waitForCursor(_ requested: UInt64, timeout: Duration = .seconds(2)) async throws -> Bool {
        if let failure = observationFailure, requested <= failure.cursor { throw failure.error }
        if cursor >= requested { return true }
        guard isObserving else { throw ScramKAudioError.observationStopped }
        let id = UUID()
        let signal = AudioWaitSignal()
        cursorWaiters[id] = (requested, signal)
        defer { cursorWaiters.removeValue(forKey: id) }
        try await signal.wait(timeout: timeout)
        return true
    }

    func injectObservationForTesting(_ transition: InterlockObservedTransition) async {
        guard let observationGate else { return }
        await consume(transition, binding: binding, gate: observationGate)
    }
}
