import Foundation
import os

/// Audit record for hardware interlock state transitions.
public struct InterlockTransitionRecord: Sendable, Hashable, Codable {
    public let timestampNanoseconds: UInt64
    public let from: InterlockStatus
    public let to: InterlockStatus
    public let reason: String

    public init(
        timestampNanoseconds: UInt64,
        from: InterlockStatus,
        to: InterlockStatus,
        reason: String
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// Thread-safe wrapper ensuring exactly-once resumption of checked continuations.
final class ContinuationWaiter: Sendable {
    private let lock: OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.lock = OSAllocatedUnfairLock(initialState: continuation)
    }

    @discardableResult
    func resume(returning: ()) -> Bool {
        let continuation = lock.withLock { cont -> CheckedContinuation<Void, any Error>? in
            let extracted = cont
            cont = nil
            return extracted
        }
        guard let continuation else { return false }
        continuation.resume()
        return true
    }

    @discardableResult
    func resume(throwing error: any Error) -> Bool {
        let continuation = lock.withLock { cont -> CheckedContinuation<Void, any Error>? in
            let extracted = cont
            cont = nil
            return extracted
        }
        guard let continuation else { return false }
        continuation.resume(throwing: error)
        return true
    }
}

/// Atomic state tracking cancellation racing against continuation initialization.
enum WaiterCancellationState: Sendable {
    case pending
    case waiting(ContinuationWaiter)
    case cancelled
}

/// Actor enforcing deterministic hardware interlock safety transitions and permissive grant queues.
public actor HardwareInterlockGate {
    private var status: InterlockStatus
    private var history: [InterlockTransitionRecord]
    private var waiters: [UUID: ContinuationWaiter]
    private var subscribers: [UUID: AsyncStream<InterlockTransitionRecord>.Continuation]
    private var observationSubscribers: [UUID: AsyncStream<InterlockObservedTransition>.Continuation] = [:]
    public private(set) var stateVersion: UInt64 = 0
    public private(set) var activePermit: PermissivePermit? = nil

    public init(initialStatus: InterlockStatus = .locked) {
        self.status = initialStatus
        self.history = []
        self.waiters = [:]
        self.subscribers = [:]
    }

    deinit {
        for waiter in waiters.values {
            _ = waiter.resume(throwing: HardwareInterlockError.gateLocked)
        }
        for subscriber in subscribers.values {
            subscriber.finish()
        }
        for subscriber in observationSubscribers.values {
            subscriber.finish()
        }
    }

    /// Current operational status of the gate.
    public var currentStatus: InterlockStatus {
        status
    }

    /// Read-only snapshot of transition audit history.
    public var transitionHistory: [InterlockTransitionRecord] {
        history
    }

    /// Number of callers currently suspended awaiting permissive grant.
    public var pendingWaitersCount: Int {
        waiters.count
    }

    /// Number of active transition stream subscribers.
    public var activeSubscribersCount: Int {
        subscribers.count + observationSubscribers.count
    }

    /// Capture status and a bounded suffix after a caller's last applied cursor.
    /// This method does not suspend or change gate state.
    public func observationSnapshot(
        after cursor: UInt64 = 0,
        historyLimit: Int = 256
    ) -> InterlockObservationSnapshot {
        let boundary = UInt64(history.count)
        let available = boundary - min(cursor, boundary)
        let retained = min(available, UInt64(max(0, historyLimit)))
        let firstIndex = history.count - Int(retained)
        let transitions = history.suffix(Int(retained)).enumerated().map { offset, record in
            InterlockObservedTransition(cursor: UInt64(firstIndex + offset) + 1, record: record)
        }
        return InterlockObservationSnapshot(
            currentStatus: status,
            cursor: boundary,
            transitions: transitions,
            omittedTransitionCount: available - retained
        )
    }

    /// Install the future stream and capture its bootstrap boundary without suspension.
    /// Neither subscription nor reconciliation creates a transition.
    public func observeTransitions(
        after cursor: UInt64 = 0,
        historyLimit: Int = 256,
        bufferingLimit: Int = 128
    ) -> InterlockObservation {
        observeTransitions(
            after: cursor, historyLimit: historyLimit, bufferingLimit: bufferingLimit,
            terminationCleanup: nil
        )
    }

    /// Internal completion handshake for deterministic termination-cleanup tests.
    /// The public API executes this same path without a completion callback.
    func observeTransitions(
        after cursor: UInt64,
        historyLimit: Int,
        bufferingLimit: Int,
        terminationCleanup: (@Sendable () -> Void)?
    ) -> InterlockObservation {
        let id = UUID()
        let pair = AsyncStream<InterlockObservedTransition>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferingLimit))
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.unsubscribeObservation(id: id)
                terminationCleanup?()
            }
        }
        observationSubscribers[id] = pair.continuation
        return InterlockObservation(
            id: id,
            snapshot: observationSnapshot(after: cursor, historyLimit: historyLimit),
            transitions: pair.stream
        )
    }

    /// Release only this observation, including a stream that was never iterated.
    public func unsubscribeObservation(id: UUID) {
        observationSubscribers.removeValue(forKey: id)?.finish()
    }

    /// Arm the gate from locked state.
    public func arm() throws {
        switch status {
        case .locked:
            transition(to: .armed, reason: "ARM_COMMAND_ACCEPTED")
        case .armed:
            activePermit = nil
            return
        case .permissiveGranted:
            throw HardwareInterlockError.invalidTransition(from: status, to: .armed)
        case .emergencyAbort:
            throw HardwareInterlockError.emergencyAbortActive
        }
    }

    /// Grant permissive state to armed gate, resolving all suspended callers.
    public func grantPermissive() throws {
        switch status {
        case .armed:
            transition(to: .permissiveGranted, reason: "PERMISSIVE_GRANTED")
            drainWaiters(returning: ())
        case .permissiveGranted:
            activePermit = nil
            stateVersion &+= 1
            return
        case .locked:
            throw HardwareInterlockError.invalidTransition(from: status, to: .permissiveGranted)
        case .emergencyAbort:
            throw HardwareInterlockError.emergencyAbortActive
        }
    }

    /// Issue a single-use, request-bound monotonic permissive permit.
    public func issuePermissivePermit(
        forRequestID requestID: UUID,
        ttl: Duration = .seconds(5),
        now: ContinuousClock.Instant = ContinuousClock().now
    ) throws -> PermissivePermit {
        if status == .emergencyAbort {
            throw HardwareInterlockError.emergencyAbortActive
        }
        transition(to: .permissiveGranted, reason: "PERMISSIVE_PERMIT_ISSUED")
        drainWaiters(returning: ())
        let permit = PermissivePermit(
            requestID: requestID,
            issuedStateVersion: stateVersion,
            expiresAt: now.advanced(by: ttl)
        )
        activePermit = permit
        return permit
    }

    /// Atomically validate and consume a single-use permissive permit in one synchronous actor turn,
    /// immediately returning the gate to `.locked`.
    public func consumePermissivePermit(
        _ permit: PermissivePermit,
        forRequestID requestID: UUID,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) throws {
        if status == .emergencyAbort {
            throw HardwareInterlockError.emergencyAbortActive
        }
        guard status == .permissiveGranted else {
            throw HardwareInterlockError.gateLocked
        }
        guard
            let current = activePermit,
            current == permit,
            permit.requestID == requestID,
            current.issuedStateVersion == stateVersion
        else {
            throw HardwareInterlockError.gateLocked
        }
        if now >= permit.expiresAt {
            activePermit = nil
            transition(to: .locked, reason: "PERMISSIVE_PERMIT_EXPIRED")
            drainWaiters(throwing: HardwareInterlockError.gateLocked)
            throw HardwareInterlockError.timedOut
        }
        activePermit = nil
        transition(to: .locked, reason: "PERMISSIVE_PERMIT_CONSUMED")
        drainWaiters(throwing: HardwareInterlockError.gateLocked)
    }

    /// Return gate to locked state, rejecting any pending waiters.
    public func lock() throws {
        switch status {
        case .locked:
            activePermit = nil
            return
        case .armed, .permissiveGranted:
            transition(to: .locked, reason: "GATE_LOCKED")
            drainWaiters(throwing: HardwareInterlockError.gateLocked)
        case .emergencyAbort:
            throw HardwareInterlockError.invalidTransition(from: status, to: .locked)
        }
    }

    /// Immediately trip emergency abort, canceling all pending waiters.
    public func tripEmergencyAbort(reason: String = "EMERGENCY_ABORT_TRIGGERED") {
        transition(to: .emergencyAbort, reason: reason)
        drainWaiters(throwing: HardwareInterlockError.emergencyAbortActive)
    }

    /// Reset emergency abort strictly to locked state.
    public func resetEmergencyAbort() throws {
        guard status == .emergencyAbort else {
            throw HardwareInterlockError.invalidTransition(from: status, to: .locked)
        }
        transition(to: .locked, reason: "EMERGENCY_ABORT_RESET")
    }

    /// Request permissive clearance, suspending caller if gate is armed until granted or timed out.
    public func requestPermissive(timeout: Duration? = nil) async throws {
        if Task.isCancelled {
            throw HardwareInterlockError.taskCancelled
        }

        switch status {
        case .permissiveGranted:
            return
        case .locked:
            throw HardwareInterlockError.gateLocked
        case .emergencyAbort:
            throw HardwareInterlockError.emergencyAbortActive
        case .armed:
            break
        }

        if let timeout {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.awaitPermissiveDirect()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw HardwareInterlockError.timedOut
                }

                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } else {
            try await awaitPermissiveDirect()
        }
    }

    private func awaitPermissiveDirect() async throws {
        if Task.isCancelled {
            throw HardwareInterlockError.taskCancelled
        }

        switch status {
        case .permissiveGranted:
            return
        case .locked:
            throw HardwareInterlockError.gateLocked
        case .emergencyAbort:
            throw HardwareInterlockError.emergencyAbortActive
        case .armed:
            break
        }

        let id = UUID()
        let waiterHolder = OSAllocatedUnfairLock<WaiterCancellationState>(initialState: .pending)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = ContinuationWaiter(continuation: continuation)
                let alreadyCancelled = waiterHolder.withLock { state -> Bool in
                    switch state {
                    case .pending:
                        state = .waiting(waiter)
                        return false
                    case .cancelled:
                        return true
                    case .waiting:
                        return false
                    }
                }
                if alreadyCancelled {
                    waiter.resume(throwing: HardwareInterlockError.taskCancelled)
                } else {
                    self.waiters[id] = waiter
                }
            }
        } onCancel: {
            let waiterToResume = waiterHolder.withLock { state -> ContinuationWaiter? in
                switch state {
                case .pending:
                    state = .cancelled
                    return nil
                case .waiting(let waiter):
                    state = .cancelled
                    return waiter
                case .cancelled:
                    return nil
                }
            }
            if let waiterToResume {
                _ = waiterToResume.resume(throwing: HardwareInterlockError.taskCancelled)
            }
            Task {
                await self.removeWaiter(id: id)
            }
        }
    }

    private func removeWaiter(id: UUID) {
        waiters.removeValue(forKey: id)
    }

    private func drainWaiters(returning: ()) {
        let current = Array(waiters.values)
        waiters.removeAll()
        for waiter in current {
            waiter.resume(returning: ())
        }
    }

    private func drainWaiters(throwing error: any Error) {
        let current = Array(waiters.values)
        waiters.removeAll()
        for waiter in current {
            waiter.resume(throwing: error)
        }
    }

    /// Subscribe to real-time gate state transitions via an AsyncStream.
    public func subscribeTransitions() -> AsyncStream<InterlockTransitionRecord> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.unsubscribe(id: id)
                }
            }
            self.subscribers[id] = continuation
        }
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func transition(to target: InterlockStatus, reason: String) {
        let record = InterlockTransitionRecord(
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            from: status,
            to: target,
            reason: reason
        )
        status = target
        stateVersion &+= 1
        activePermit = nil
        history.append(record)
        let observation = InterlockObservedTransition(cursor: UInt64(history.count), record: record)
        var terminatedObservations: [UUID] = []
        for (id, subscriber) in observationSubscribers {
            if case .terminated = subscriber.yield(observation) {
                terminatedObservations.append(id)
            }
        }
        for id in terminatedObservations {
            observationSubscribers.removeValue(forKey: id)
        }
        var terminatedIDs: [UUID] = []
        for (id, subscriber) in subscribers {
            let result = subscriber.yield(record)
            if case .terminated = result {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            subscribers.removeValue(forKey: id)
        }
    }
}

/// Convenience alias maintaining module naming symmetry.
public typealias InterlockEngine = HardwareInterlockGate
