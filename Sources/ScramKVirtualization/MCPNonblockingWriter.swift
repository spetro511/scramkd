import Darwin
import Dispatch
import Foundation
import os

enum MCPTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidWriteRange
    case notStarted
    case stopped
    case posix(operation: String, code: Int32)
    case interrupted
    case noWriteProgress
    case deadlineExceeded
    case tooManyWaiters
    case outputOverflow
    case consumerClosed
    case launchFailed(domain: String, code: Int)
    case stopTimedOut
}

enum MCPTransportWriteResult: Equatable, Sendable {
    case written(Int)
    case wouldBlock
}

/// An exactly-once callback bridge. Timeout tasks are bounded by the owning waiter's limit.
final class MCPIOWaiter<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
        var timeout: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let deadline: ContinuousClock.Instant

    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    var isResolved: Bool { state.withLock { $0.result != nil } }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { state -> Result<Value, any Error>? in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        let resolution = state.withLock { state -> (Bool, CheckedContinuation<Value, any Error>?, Task<Void, Never>?) in
            guard state.result == nil else { return (false, nil, nil) }
            state.result = result
            let continuation = state.continuation
            let timeout = state.timeout
            state.continuation = nil
            state.timeout = nil
            return (true, continuation, timeout)
        }
        resolution.2?.cancel()
        resolution.1?.resume(with: result)
        return resolution.0
    }

    func armTimeout(deadline: ContinuousClock.Instant, expired: @escaping @Sendable () -> Void) {
        guard !isResolved else { return }
        let timeout = Task {
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                // This task owns only a clock sleep; cancellation is its teardown path.
                return
            }
            expired()
        }
        let resolved = state.withLock { state in
            guard state.result == nil else { return true }
            state.timeout = timeout
            return false
        }
        if resolved { timeout.cancel() }
    }
}

/// Reusable observation of a single completion, including completion before subscription.
/// Pending waiters are judged at the recorded completion instant, independently of timer-task
/// scheduling. A new observer of an already resolved completion receives that stored result
/// immediately, even if its supplied deadline has passed; it is no longer waiting for an event.
final class MCPIOCompletion<Value: Sendable>: Sendable {
    private struct Completion: Sendable {
        let result: Result<Value, any Error>
        let instant: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var completion: Completion?
        var waiters: [UUID: MCPIOWaiter<Value>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> ContinuousClock.Instant
    private let scheduleTimeout: (@Sendable (ContinuousClock.Instant, @escaping @Sendable () -> Void) -> Void)?

    // Internal clock/timer seams are synchronous and nonblocking. Production always uses the
    // monotonic ContinuousClock and the owned, cancellable waiter timeout task.
    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        scheduleTimeout: (@Sendable (ContinuousClock.Instant, @escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.now = now
        self.scheduleTimeout = scheduleTimeout
    }

    func finish(_ result: Result<Value, any Error>) {
        let resolution = state.withLock { state -> (Completion, [MCPIOWaiter<Value>])? in
            guard state.completion == nil else { return nil }
            let completion = Completion(result: result, instant: now())
            state.completion = completion
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return (completion, waiters)
        }
        guard let (completion, waiters) = resolution else { return }
        for waiter in waiters {
            if completion.instant >= waiter.deadline {
                waiter.resolve(.failure(MCPTransportError.deadlineExceeded))
            } else {
                waiter.resolve(completion.result)
            }
        }
    }

    func wait(deadline: ContinuousClock.Instant) async throws -> Value {
        let id = UUID()
        let waiter = MCPIOWaiter<Value>(deadline: deadline)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let immediate = state.withLock { state -> Result<Value, any Error>? in
                if let completion = state.completion { return completion.result }
                if waiter.isResolved { return nil }
                if now() >= deadline { return .failure(MCPTransportError.deadlineExceeded) }
                guard state.waiters.count < 16 else { return .failure(MCPTransportError.tooManyWaiters) }
                state.waiters[id] = waiter
                return nil
            }
            if let immediate { waiter.resolve(immediate) }
            let expire: @Sendable () -> Void = { [weak self] in self?.expire(id) }
            if !waiter.isResolved, let scheduleTimeout {
                scheduleTimeout(deadline, expire)
            } else {
                waiter.armTimeout(deadline: deadline, expired: expire)
            }
            defer { remove(id) }
            return try await waiter.value()
        } onCancel: { [self, waiter] in
            waiter.resolve(.failure(CancellationError()))
            remove(id)
        }
    }

    var pendingWaiterCount: Int { state.withLock { $0.waiters.count } }

    private func expire(_ id: UUID) {
        // Completion and timeout compete under the same lock. Once finish has claimed a
        // waiter, a delayed timer cannot override an on-time completion before its resume.
        let waiter = state.withLock { state -> MCPIOWaiter<Value>? in
            guard let waiter = state.waiters[id], now() >= waiter.deadline else { return nil }
            return state.waiters.removeValue(forKey: id)
        }
        waiter?.resolve(.failure(MCPTransportError.deadlineExceeded))
    }

    private func remove(_ id: UUID) { _ = state.withLock { $0.waiters.removeValue(forKey: id) } }
}

/// Owns one stdin descriptor for one process generation. It never grants authorization.
///
/// The lock fences the descriptor lifetime against each bounded, nonblocking write. A revoked
/// descriptor is removed from admission immediately, but closed only in its dispatch source's
/// cancellation handler, after all source callbacks have quiesced. No integer-fd equality check
/// substitutes for ownership. Readiness is advisory: the caller must retry writeChunk outside
/// any await, under its own authoritative authorization fence.
final class MCPNonblockingWriter: Sendable {
    private struct State {
        var descriptor: Int32?
        var source: (any DispatchSourceWrite)?
        var resumed = false
        var revoked = false
        var installed = false
        var waiters: [UUID: MCPIOWaiter<Void>] = [:]
    }

    // SDK confinement exception: DispatchSourceWrite is non-Sendable. It never leaves this
    // lock, whose synchronous operations serialize its suspend/resume/cancel balance.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let queue = DispatchQueue(label: "scramk.mcp.stdin-ready", qos: .utility)
    private let closed = MCPIOCompletion<Void>()
    private let onReadinessWaiterRegistered: (@Sendable () -> Void)?

    init(onReadinessWaiterRegistered: (@Sendable () -> Void)? = nil) {
        self.onReadinessWaiterRegistered = onReadinessWaiterRegistered
    }

    deinit { revoke() }

    /// Takes ownership on success only. The supplied descriptor must be a private pipe end.
    func install(descriptor: Int32) throws {
        try MCPDescriptorConfiguration.nonblocking(descriptor)
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw MCPTransportError.posix(operation: "stdin-nosigpipe", code: errno)
        }
        try MCPDescriptorConfiguration.closeOnExec(descriptor)
        try state.withLock { state in
            guard !state.revoked else { throw MCPTransportError.stopped }
            guard !state.installed else { throw MCPTransportError.stopped }
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.becameWritable() }
            let closed = self.closed
            source.setCancelHandler {
                let result = Darwin.close(descriptor)
                if result == 0 {
                    closed.finish(.success(()))
                } else {
                    closed.finish(.failure(MCPTransportError.posix(operation: "stdin-close", code: errno)))
                }
            }
            state.descriptor = descriptor
            state.source = source
            state.installed = true
            // Sources begin suspended. Only an actual readiness waiter resumes this source.
        }
    }

    func writeChunk(_ data: Data, offset: Int, maximumCount: Int = 16_384) throws -> MCPTransportWriteResult {
        guard offset >= 0, offset <= data.count, maximumCount > 0 else {
            throw MCPTransportError.invalidWriteRange
        }
        // Subtraction precedes addition; even Int.max maximumCount cannot overflow.
        let count = min(data.count - offset, min(maximumCount, 16_384))
        return try state.withLock { state in
            guard !state.revoked else { throw MCPTransportError.stopped }
            guard let descriptor = state.descriptor else { throw MCPTransportError.notStarted }
            if count == 0 { return .written(0) }
            return try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { throw MCPTransportError.invalidWriteRange }
                // No allocation, await, readiness wait, or blocking descriptor operation here.
                for _ in 0..<4 {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), count)
                    if written > 0 { return .written(written) }
                    if written == 0 { throw MCPTransportError.noWriteProgress }
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK { return .wouldBlock }
                    if code != EINTR { throw MCPTransportError.posix(operation: "stdin-write", code: code) }
                }
                throw MCPTransportError.interrupted
            }
        }
    }

    func waitUntilWritable(deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        let waiter = MCPIOWaiter<Void>(deadline: deadline)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let immediate = state.withLock { state -> MCPTransportError? in
                if state.revoked { return .stopped }
                guard state.installed, let source = state.source else { return .notStarted }
                if waiter.isResolved { return nil }
                if ContinuousClock.now >= deadline { return .deadlineExceeded }
                guard state.waiters.count < 16 else { return .tooManyWaiters }
                state.waiters[id] = waiter
                if !state.resumed {
                    state.resumed = true
                    source.resume()
                }
                return nil
            }
            if let immediate { waiter.resolve(.failure(immediate)) }
            else { onReadinessWaiterRegistered?() }
            waiter.armTimeout(deadline: deadline) { [weak self, waiter] in
                waiter.resolve(.failure(MCPTransportError.deadlineExceeded))
                self?.removeWaiter(id)
            }
            defer { removeWaiter(id) }
            try await waiter.value()
        } onCancel: { [self, waiter] in
            waiter.resolve(.failure(CancellationError()))
            removeWaiter(id)
        }
    }

    /// Synchronous admission revocation. Actual close completes asynchronously after source quiescence.
    func revoke() {
        let result = state.withLock { state -> ([MCPIOWaiter<Void>], Bool) in
            guard !state.revoked else { return ([], false) }
            state.revoked = true
            state.descriptor = nil
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            guard let source = state.source else { return (waiters, true) }
            // A cancelled suspended source does not deliver its cancellation handler until resumed.
            source.cancel()
            if !state.resumed {
                state.resumed = true
                source.resume()
            }
            state.source = nil
            return (waiters, false)
        }
        for waiter in result.0 { waiter.resolve(.failure(MCPTransportError.stopped)) }
        if result.1 { closed.finish(.success(())) }
    }

    func waitForClose(deadline: ContinuousClock.Instant) async throws { try await closed.wait(deadline: deadline) }

    // Bounded internal observability for deterministic cancellation/descriptor-lifetime tests.
    var pendingReadinessWaiterCount: Int { state.withLock { $0.waiters.count } }

    private func becameWritable() {
        let waiters = state.withLock { state -> [MCPIOWaiter<Void>] in
            guard !state.revoked, let source = state.source else { return [] }
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            if state.resumed {
                state.resumed = false
                source.suspend()
            }
            return waiters
        }
        for waiter in waiters {
            if ContinuousClock.now >= waiter.deadline { waiter.resolve(.failure(MCPTransportError.deadlineExceeded)) }
            else { waiter.resolve(.success(())) }
        }
    }

    private func removeWaiter(_ id: UUID) {
        state.withLock { state in
            state.waiters.removeValue(forKey: id)
            if state.waiters.isEmpty, state.resumed, !state.revoked, let source = state.source {
                state.resumed = false
                source.suspend()
            }
        }
    }
}

enum MCPDescriptorConfiguration {
    static func nonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw MCPTransportError.posix(operation: "pipe-nonblocking", code: errno)
        }
    }

    static func closeOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1 else {
            throw MCPTransportError.posix(operation: "pipe-cloexec", code: errno)
        }
    }
}
