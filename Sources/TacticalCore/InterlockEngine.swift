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
private final class ContinuationWaiter: Sendable {
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

/// Actor enforcing deterministic hardware interlock safety transitions and permissive grant queues.
public actor HardwareInterlockGate {
    private var status: InterlockStatus
    private var history: [InterlockTransitionRecord]
    private var waiters: [UUID: ContinuationWaiter]

    public init(initialStatus: InterlockStatus = .locked) {
        self.status = initialStatus
        self.history = []
        self.waiters = [:]
    }

    deinit {
        for waiter in waiters.values {
            _ = waiter.resume(throwing: HardwareInterlockError.gateLocked)
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

    /// Arm the gate from locked state.
    public func arm() throws {
        switch status {
        case .locked:
            transition(to: .armed, reason: "ARM_COMMAND_ACCEPTED")
        case .armed:
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
            return
        case .locked:
            throw HardwareInterlockError.invalidTransition(from: status, to: .permissiveGranted)
        case .emergencyAbort:
            throw HardwareInterlockError.emergencyAbortActive
        }
    }

    /// Return gate to locked state, rejecting any pending waiters.
    public func lock() throws {
        switch status {
        case .locked:
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
        let waiterHolder = OSAllocatedUnfairLock<ContinuationWaiter?>(initialState: nil)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = ContinuationWaiter(continuation: continuation)
                waiterHolder.withLock { $0 = waiter }
                self.waiters[id] = waiter
            }
        } onCancel: {
            let waiter = waiterHolder.withLock { $0 }
            if let waiter {
                _ = waiter.resume(throwing: HardwareInterlockError.taskCancelled)
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

    private func transition(to target: InterlockStatus, reason: String) {
        let record = InterlockTransitionRecord(
            timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
            from: status,
            to: target,
            reason: reason
        )
        status = target
        history.append(record)
    }
}

/// Convenience alias maintaining module naming symmetry.
public typealias InterlockEngine = HardwareInterlockGate
