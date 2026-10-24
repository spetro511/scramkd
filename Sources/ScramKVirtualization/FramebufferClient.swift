import Foundation
import os

private final class FrameSession: Sendable {
    let generation = UUID()
    let handshakeDeadline: ContinuousClock.Instant
    let transport: any FrameWireTransport
    let ready = FrameCompletion<UUID>()
    let settled = FrameCompletion<Void>()
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(transport: any FrameWireTransport, handshakeDeadline: ContinuousClock.Instant) {
        self.transport = transport
        self.handshakeDeadline = handshakeDeadline
    }
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() {
        cancelled.withLock { $0 = true }
        transport.retire() // Synchronous admission fence; never waits behind receive.
        ready.finish(.failure(.cancelled))
    }
}

/// Read-only framebuffer client. init is offline; explicit app attach owns its
/// start/stop policy. None security does not authenticate the local service.
/// No dependency on MCP processes, authorization leases, UI, Metal or audio.
public actor FramebufferClient {
    private let timing: FrameTiming
    private let makeTransport: @Sendable () -> any FrameWireTransport
    private var session: FrameSession?
    private var worker: Task<Void, Never>?
    private var cleanup: Task<Void, any Error>?
    private var retiring = false
    private var state: FrameConnectionState = .detached
    private var revision: UInt64 = 0
    private var deliveryRevision: UInt64 = 0
    private var latest = FrameDelivery(revision: 0, generation: nil, frame: nil)
    private var frameObserver: (UUID, AsyncStream<FrameDelivery>.Continuation)?
    private var stateObservers: [UUID: AsyncStream<FrameSnapshot>.Continuation] = [:]
    private var width: Int?
    private var height: Int?
    private var lastTrafficAt: ContinuousClock.Instant?
    private var lastFrameAt: ContinuousClock.Instant?
    private var lastStateEmission: ContinuousClock.Instant?
    private var statistics = FrameStatistics()
    private var failure: FrameError?

    public init() {
        timing = FrameTiming()
        makeTransport = { FrameWebSocketTransport() }
    }

    init(timing: FrameTiming, makeTransport: @escaping @Sendable () -> any FrameWireTransport) {
        self.timing = timing
        self.makeTransport = makeTransport
    }

    deinit {
        session?.cancel()
        worker?.cancel()
        // Cleanup, if installed, retains its own session/transport and is not cancelled.
        frameObserver?.1.finish()
        for observer in stateObservers.values { observer.finish() }
    }

    /// Returns after RFB initialization/configuration; a frame is not guaranteed.
    public func connect() async throws -> UUID {
        guard session == nil, !retiring else { throw FrameError.busy }
        guard deliveryRevision < UInt64.max - 2, revision < UInt64.max - 2 else {
            throw FrameError.limitExceeded(.counter)
        }
        try Task.checkCancellation()
        let current = FrameSession(transport: makeTransport(),
                                   handshakeDeadline: timing.now().advanced(by: timing.connectBudget))
        session = current
        state = .connecting
        failure = nil
        width = nil; height = nil; lastTrafficAt = nil; lastFrameAt = nil
        statistics = FrameStatistics()
        statistics.startedAt = timing.now()
        clear(generation: current.generation)
        emitState(force: true)
        let clock = timing
        worker = Task { [weak self, current, clock] in
            let outcome: FrameError?
            do {
                try await Self.run(current, timing: clock,
                    negotiating: { [weak self] in
                        guard let self else { throw FrameError.cancelled }
                        try await self.didBeginNegotiation(current.generation)
                    },
                    initialized: { [weak self] width, height, deadline in
                        guard let self else { throw FrameError.cancelled }
                        try await self.didInitialize(current.generation, width: width, height: height, deadline: deadline)
                    },
                    activity: { [weak self] stats, traffic in
                        guard let self else { throw FrameError.cancelled }
                        try await self.didReceive(current.generation, statistics: stats, traffic: traffic)
                    },
                    frame: { [weak self] frame, stats, deadline in
                        guard let self else { throw FrameError.cancelled }
                        try await self.didDecode(frame, statistics: stats, deadline: deadline)
                    })
                outcome = nil
            } catch { outcome = frameError(error) }
            if let outcome { current.ready.finish(.failure(outcome)) }
            current.settled.finish(.success(()))
            await self?.sessionEnded(current.generation, failure: outcome)
        }
        do {
            let generation = try await withTaskCancellationHandler {
                try await current.ready.value(deadline: current.handshakeDeadline, stage: .handshake, timing: timing)
            } onCancel: { current.cancel() }
            try Task.checkCancellation()
            try timing.check(current.handshakeDeadline, stage: .handshake)
            try requireActive(generation)
            return generation
        } catch {
            let error = frameError(error)
            beginRetirement(current.generation, failure: error == .cancelled ? nil : error)
            throw error
        }
    }

    /// nil captures only the current session at actor admission. Cleanup is owned
    /// independently of caller cancellation; timeout retains ownership and busy.
    public func disconnect(generation: UUID? = nil) async throws {
        guard let current = session else {
            if generation != nil { throw FrameError.staleGeneration }
            return
        }
        guard generation == nil || generation == current.generation else { throw FrameError.staleGeneration }
        beginRetirement(current.generation, failure: nil)
        if cleanup == nil { startCleanup(current) } // Retry a timed-out settlement, never reopen admission.
        guard let cleanup else { throw FrameError.busy }
        try await cleanup.value
        try Task.checkCancellation()
    }

    public func snapshot() -> FrameSnapshot {
        FrameSnapshot(revision: revision, generation: session?.generation, state: state,
                      width: width, height: height, lastTrafficAt: lastTrafficAt,
                      lastFrameAt: lastFrameAt, statistics: statistics, failure: failure)
    }

    public func observeFrames() throws -> FrameObservation {
        guard frameObserver == nil else { throw FrameError.limitExceeded(.observers) }
        let id = UUID()
        let pair = AsyncStream<FrameDelivery>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id: id) } }
        frameObserver = (id, pair.continuation)
        // Registration + bootstrap are one actor turn; current is not replayed in updates.
        return FrameObservation(id: id, current: latest, updates: pair.stream)
    }

    public func observeState() throws -> FrameStateObservation {
        guard stateObservers.count < FrameLimits.stateObservers else { throw FrameError.limitExceeded(.observers) }
        let id = UUID()
        let pair = AsyncStream<FrameSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id: id) } }
        stateObservers[id] = pair.continuation
        return FrameStateObservation(id: id, snapshot: snapshot(), updates: pair.stream)
    }

    public func unsubscribe(id: UUID) {
        if frameObserver?.0 == id {
            let continuation = frameObserver?.1
            frameObserver = nil
            continuation?.finish()
        }
        stateObservers.removeValue(forKey: id)?.finish()
    }

    private func requireActive(_ generation: UUID) throws {
        guard let session, session.generation == generation, !retiring, !session.isCancelled else {
            throw FrameError.staleGeneration
        }
    }

    private func didBeginNegotiation(_ generation: UUID) throws {
        try requireActive(generation)
        state = .negotiating
        emitState(force: true)
    }

    private func didInitialize(_ generation: UUID, width: Int, height: Int,
                               deadline: ContinuousClock.Instant) throws {
        try requireActive(generation)
        try timing.check(deadline, stage: .handshake)
        self.width = width; self.height = height
        state = .connected
        emitState(force: true)
    }

    private func didReceive(_ generation: UUID, statistics: FrameStatistics,
                            traffic: ContinuousClock.Instant) throws {
        try requireActive(generation)
        let replaced = self.statistics.replacedFrameDeliveries
        self.statistics = statistics
        self.statistics.replacedFrameDeliveries = replaced
        lastTrafficAt = traffic
        emitState(force: false)
    }

    private func didDecode(_ frame: RGBAFrame, statistics: FrameStatistics,
                           deadline: ContinuousClock.Instant) throws {
        try requireActive(frame.generation)
        try timing.check(deadline, stage: .update)
        guard deliveryRevision < UInt64.max - 1 else { throw FrameError.limitExceeded(.counter) }
        let replaced = self.statistics.replacedFrameDeliveries
        self.statistics = statistics
        self.statistics.replacedFrameDeliveries = replaced
        let firstFrame = lastFrameAt == nil
        lastFrameAt = frame.receivedAt
        deliveryRevision += 1
        latest = FrameDelivery(revision: deliveryRevision, generation: frame.generation, frame: frame)
        if let observer = frameObserver {
            switch observer.1.yield(latest) {
            case .dropped(let delivery) where delivery.frame != nil:
                try Self.increment(&self.statistics.replacedFrameDeliveries)
            case .terminated: frameObserver = nil
            default: break
            }
        }
        emitState(force: firstFrame)
    }

    private func sessionEnded(_ generation: UUID, failure: FrameError?) {
        guard let current = session, current.generation == generation, !retiring else { return }
        let cancelled = current.isCancelled && (failure == .cancelled || failure == .staleGeneration)
        beginRetirement(generation, failure: cancelled ? nil : (failure ?? .endOfStream))
    }

    private func beginRetirement(_ generation: UUID, failure: FrameError?) {
        guard let current = session, current.generation == generation, !retiring else { return }
        retiring = true
        self.failure = failure
        state = failure == nil ? .disconnecting : .failed
        // Clear CPU image before any cleanup await, including failed/EOF paths.
        clear(generation: generation)
        width = nil; height = nil; lastFrameAt = nil
        current.cancel()
        worker?.cancel()
        emitState(force: true)
        startCleanup(current)
    }

    private func startCleanup(_ current: FrameSession) {
        guard cleanup == nil else { return }
        let clock = timing
        let deadline = clock.now().advanced(by: clock.cleanupBudget)
        cleanup = Task { [weak self, current, clock] in
            do {
                // Settled worker owns no further decoding/writes. Socket close waits
                // for BOTH readiness-source and timer cancellation acknowledgements.
                try await current.settled.value(deadline: deadline, timing: clock)
                try await current.transport.close(deadline: deadline)
                await self?.cleanupFinished(current.generation, error: nil)
            } catch {
                let error = frameError(error)
                await self?.cleanupFinished(current.generation, error: error)
                throw error
            }
        }
    }

    private func cleanupFinished(_ generation: UUID, error: FrameError?) {
        guard session?.generation == generation, retiring else { return }
        cleanup = nil
        if let error {
            failure = error
            state = .failed
            // Keep session/worker ownership; explicit disconnect may retry settlement.
        } else {
            session = nil
            worker = nil
            retiring = false
            state = failure == nil ? .detached : .failed
        }
        emitState(force: true)
    }

    private func clear(generation: UUID?) {
        // Active publication reserves the final revision for a fail-closed clear.
        if deliveryRevision < .max { deliveryRevision += 1 }
        latest = FrameDelivery(revision: deliveryRevision, generation: generation, frame: nil)
        if let observer = frameObserver {
            switch observer.1.yield(latest) {
            case .dropped(let delivery) where delivery.frame != nil:
                if statistics.replacedFrameDeliveries < .max { statistics.replacedFrameDeliveries += 1 }
            case .terminated: frameObserver = nil
            default: break
            }
        }
    }

    private func emitState(force: Bool) {
        let now = timing.now()
        guard force || lastStateEmission.map({ $0.duration(to: now) >= .milliseconds(500) }) != false else { return }
        if revision < .max { revision += 1 }
        else { failure = .limitExceeded(.counter); session?.cancel() }
        lastStateEmission = now
        statistics.sampledAt = now
        let value = snapshot()
        for continuation in stateObservers.values { continuation.yield(value) }
    }

    private static func increment(_ value: inout UInt64, by amount: UInt64 = 1) throws {
        let (next, overflow) = value.addingReportingOverflow(amount)
        guard !overflow else { throw FrameError.limitExceeded(.counter) }
        value = next
    }

    private static func run(
        _ session: FrameSession, timing: FrameTiming,
        negotiating: @Sendable () async throws -> Void,
        initialized: @Sendable (Int, Int, ContinuousClock.Instant) async throws -> Void,
        activity: @Sendable (FrameStatistics, ContinuousClock.Instant) async throws -> Void,
        frame: @Sendable (RGBAFrame, FrameStatistics, ContinuousClock.Instant) async throws -> Void
    ) async throws {
        let transport = session.transport
        let handshakeDeadline = session.handshakeDeadline
        var decoder = RFBStreamDecoder()
        var stats = FrameStatistics()
        stats.startedAt = timing.now()
        func check(_ deadline: ContinuousClock.Instant, _ stage: FrameDeadlineStage) throws {
            guard !session.isCancelled else { throw FrameError.cancelled }
            try timing.check(deadline, stage: stage)
        }
        try check(handshakeDeadline, .connect)
        try await transport.open(deadline: handshakeDeadline)
        try check(handshakeDeadline, .handshake)
        try await negotiating()
        var handshakeBytes = 0
        var handshakeMessages = 0
        while !decoder.initialized {
            try check(handshakeDeadline, .handshake)
            guard let data = try await transport.receiveBinary(deadline: handshakeDeadline, stage: .handshake) else {
                try decoder.endOfStream()
                throw FrameError.endOfStream
            }
            try check(handshakeDeadline, .handshake)
            guard data.count <= FrameLimits.httpHeaders - handshakeBytes, handshakeMessages < 4096 else {
                throw FrameError.limitExceeded(.bufferBytes)
            }
            handshakeBytes += data.count; handshakeMessages += 1
            try increment(&stats.receivedBinaryPayloadBytes, by: UInt64(data.count))
            try increment(&stats.receivedBinaryMessages)
            let receivedAt = timing.now()
            try await activity(stats, receivedAt)
            let events = try decoder.consume(data) { try check(handshakeDeadline, .handshake) }
            for event in events {
                try check(handshakeDeadline, .handshake)
                switch event {
                case .send(let data): try await transport.sendBinary(data, deadline: handshakeDeadline)
                case .initialized(let width, let height): try await initialized(width, height, handshakeDeadline)
                case .update: throw FrameError.protocolViolation(.unsolicitedUpdate)
                }
            }
        }
        try check(handshakeDeadline, .handshake)
        session.ready.finish(.success(session.generation))
        var nextRequest = timing.now()
        let interval = max(timing.requestInterval, .milliseconds(34))
        while true {
            if timing.now() < nextRequest { try await timing.sleep(nextRequest) }
            // A fake/early clock wake cannot advance admission or exceed the rate cap.
            while timing.now() < nextRequest {
                try Task.checkCancellation()
                guard !session.isCancelled else { throw FrameError.cancelled }
                try await timing.sleep(nextRequest)
            }
            let deadline = timing.now().advanced(by: timing.updateBudget)
            try check(deadline, .update)
            nextRequest = timing.now().advanced(by: interval)
            let request = try decoder.requestFullUpdate()
            try await transport.sendBinary(request, deadline: deadline)
            var updateBytes = 0
            var updateMessages = 0
            while decoder.outstandingUpdate {
                try check(deadline, .update)
                guard let data = try await transport.receiveBinary(deadline: deadline, stage: .update) else {
                    try decoder.endOfStream()
                    throw FrameError.endOfStream
                }
                try check(deadline, .update)
                guard data.count <= FrameLimits.bytes - updateBytes, updateMessages < 4096 else {
                    throw FrameError.limitExceeded(.updateBytes)
                }
                updateBytes += data.count; updateMessages += 1
                try increment(&stats.receivedBinaryPayloadBytes, by: UInt64(data.count))
                try increment(&stats.receivedBinaryMessages)
                let receivedAt = timing.now()
                try await activity(stats, receivedAt)
                let events = try decoder.consume(data) { try check(deadline, .update) }
                for event in events {
                    try check(deadline, .update)
                    switch event {
                    case .update(let pixels):
                        try increment(&stats.completedUpdates)
                        if let pixels {
                            try increment(&stats.publishedFrames)
                            let decoded = try RGBAFrame(generation: session.generation,
                                sequence: stats.publishedFrames, width: decoder.width, height: decoder.height,
                                bytesPerRow: decoder.width * 4, pixels: pixels, receivedAt: timing.now())
                            try check(deadline, .update)
                            try await frame(decoded, stats, deadline)
                        } else {
                            try increment(&stats.noChangeUpdates)
                            try await activity(stats, receivedAt)
                        }
                    case .send, .initialized: throw FrameError.protocolViolation(.serverMessage)
                    }
                }
            }
        }
    }
}
