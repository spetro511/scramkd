import Darwin
import Dispatch
import Foundation
import os

/// Continuation resolution only. All mutable fields are inside the allocated
/// lock, no lock crosses await, and no unchecked Sendable conformance is needed.
final class FramePromise<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, FrameError>?
        var continuation: CheckedContinuation<Value, any Error>?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    var isFinished: Bool { lock.withLock { $0.result != nil } }

    func finish(_ result: Result<Value, FrameError>) {
        let continuation = lock.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result.mapError { $0 as any Error })
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { state -> Result<Value, FrameError>? in
                if let result = state.result { return result }
                guard state.continuation == nil else { return .failure(.busy) }
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
        }
    }
}

/// Multi-waiter one-shot, used for connect and worker/FD settlement only.
final class FrameCompletion<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, FrameError>?
        var waiters: [UUID: FramePromise<Value>] = [:]
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func finish(_ result: Result<Value, FrameError>) {
        let waiters = lock.withLock { state -> [FramePromise<Value>] in
            guard state.result == nil else { return [] }
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.finish(result) }
    }

    func value(deadline: ContinuousClock.Instant? = nil, stage: FrameDeadlineStage = .cleanup,
               timing: FrameTiming = FrameTiming()) async throws -> Value {
        let id = UUID(), waiter = FramePromise<Value>()
        let result = lock.withLock { state -> Result<Value, FrameError>? in
            if let result = state.result { return result }
            state.waiters[id] = waiter
            return nil
        }
        if let result { waiter.finish(result) }
        let timer: Task<Void, Never>?
        if let deadline {
            timer = Task {
                do {
                    while timing.now() < deadline {
                        try Task.checkCancellation()
                        try await timing.sleep(deadline)
                    }
                } catch { return }
                guard !Task.isCancelled else { return }
                waiter.finish(.failure(.timedOut(stage)))
            }
        } else { timer = nil }
        defer {
            timer?.cancel()
            _ = lock.withLock { $0.waiters.removeValue(forKey: id) }
        }
        return try await withTaskCancellationHandler {
            if let deadline { try timing.check(deadline, stage: stage) }
            let value = try await waiter.value()
            if let deadline { try timing.check(deadline, stage: stage) }
            return value
        } onCancel: { waiter.finish(.failure(.cancelled)) }
    }
}

/// The production implementation never consults URL/proxy/PAC/environment APIs.
/// Injection is internal and supports socketpair/scripted syscall tests only.
struct FrameSocketSyscalls: Sendable {
    var open: @Sendable () throws -> Int32
    var connect: @Sendable (Int32) throws -> Bool
    var checkConnect: @Sendable (Int32) throws -> Void
    var read: @Sendable (Int32, Int) throws -> Data?
    var write: @Sendable (Int32, Data, Int) throws -> Int?
    var close: @Sendable (Int32) -> Int32?

    static let live = Self(
        open: {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw FrameError.systemCall(code: errno) }
            do {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                      fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw FrameError.systemCall(code: errno)
                }
                var enabled: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw FrameError.systemCall(code: errno)
                }
                return fd
            } catch {
                // Never retry close after EINTR: the descriptor number may be reused.
                _ = Darwin.close(fd)
                throw error
            }
        },
        connect: { fd in
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(7860).bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
            let outcome = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    let result = Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    return (result, errno)
                }
            }
            if outcome.0 == 0 { return true }
            let code = outcome.1
            if code == EINPROGRESS || code == EALREADY || code == EINTR { return false }
            throw FrameError.systemCall(code: code)
        },
        checkConnect: { fd in
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
                throw FrameError.systemCall(code: errno)
            }
            guard error == 0 else { throw FrameError.systemCall(code: error) }
        },
        read: { fd, count in
            var data = Data(count: count)
            let outcome = data.withUnsafeMutableBytes { buffer -> (Int, Int32) in
                let result = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
                return (result, errno)
            }
            if outcome.0 >= 0 { data.count = outcome.0; return data }
            let code = outcome.1
            if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return nil }
            throw FrameError.systemCall(code: code)
        },
        write: { fd, data, offset in
            let count = min(FrameLimits.socketChunk, data.count - offset)
            let outcome = data.withUnsafeBytes { bytes -> (Int, Int32) in
                let result = Darwin.send(fd, bytes.baseAddress?.advanced(by: offset), count, 0)
                return (result, errno)
            }
            if outcome.0 > 0 { return outcome.0 }
            if outcome.0 == 0 { throw FrameError.endOfStream }
            let code = outcome.1
            if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return nil }
            throw FrameError.systemCall(code: code)
        },
        close: { fd in Darwin.close(fd) == 0 ? nil : errno }
    )
}

/// Synchronous critical sections contain ONLY bounded nonblocking syscalls and
/// source bookkeeping. This lock does not replace session/codec actor isolation.
/// FD access is under the same lock as revocation/close. Each readiness source
/// and timer contributes a cancellation acknowledgement; only the final ack may
/// close the FD. Thus no callback or pending syscall can observe a reused FD.
final class FrameSocketIO: Sendable {
    private struct Wait {
        let promise: FramePromise<Void>
        let source: any DispatchSourceProtocol
        let timer: any DispatchSourceTimer
        let deadline: ContinuousClock.Instant
        let stage: FrameDeadlineStage
    }
    private struct State {
        var fd: Int32?
        var started = false
        var closing = false
        var closed = false
        var writing = false
        var reading = false
        var sourceCount = 0
        var waits: [UUID: Wait] = [:]
    }
    // Dispatch source protocol existentials are not Sendable in the macOS 14
    // SDK. Their handles NEVER leave this lock; only Sendable promises/values
    // escape. Creation, handler installation, cancellation and counts all use
    // this same lock. This is the sole uncheckedState initializer in D2.
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())
    private let queue = DispatchQueue(label: "tactical.frame.socket")
    private let calls: FrameSocketSyscalls
    private let timing: FrameTiming
    private let closed = FrameCompletion<Void>()

    init(calls: FrameSocketSyscalls = .live, timing: FrameTiming = FrameTiming()) {
        self.calls = calls
        self.timing = timing
    }

    deinit {
        // Live sources retain this object until their cancellation handlers run.
        // Therefore deinit cannot race a live source. Normally explicit close has
        // already consumed fd; this is only the no-pending-source fallback.
        lock.withLock { state in
            if let fd = state.fd { _ = calls.close(fd); state.fd = nil }
        }
    }

    var isRetired: Bool { lock.withLock { $0.closing } }

    func connect(deadline: ContinuousClock.Instant) async throws {
        try timing.check(deadline, stage: .connect)
        let connected = try lock.withLock { state -> Bool in
            try timing.check(deadline, stage: .connect)
            guard !state.closing else { throw FrameError.cancelled }
            guard !state.started else { throw FrameError.busy }
            state.started = true
            let fd = try calls.open()
            state.fd = fd
            try timing.check(deadline, stage: .connect)
            return try calls.connect(fd)
        }
        if !connected { try await ready(write: true, deadline: deadline, stage: .connect) }
        try timing.check(deadline, stage: .connect)
        try lock.withLock { state in
            try timing.check(deadline, stage: .connect)
            try calls.checkConnect(try admittedFD(state))
        }
        try timing.check(deadline, stage: .connect)
    }

    func read(deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) async throws -> Data {
        try lock.withLock { state in
            guard !state.reading else { throw FrameError.busy }
            state.reading = true
        }
        defer { lock.withLock { $0.reading = false } }
        while true {
            try timing.check(deadline, stage: stage)
            let data = try lock.withLock { state in
                try timing.check(deadline, stage: stage)
                return try calls.read(try admittedFD(state), FrameLimits.socketChunk)
            }
            if let data {
                try timing.check(deadline, stage: stage)
                guard data.count <= FrameLimits.socketChunk else { throw FrameError.limitExceeded(.bufferBytes) }
                return data
            }
            try await ready(write: false, deadline: deadline, stage: stage)
        }
    }

    func writeAll(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        try lock.withLock { state in
            guard !state.writing else { throw FrameError.busy }
            state.writing = true
        }
        defer { lock.withLock { $0.writing = false } }
        var offset = 0
        while offset < data.count {
            try timing.check(deadline, stage: .write)
            let currentOffset = offset
            let written = try lock.withLock { state in
                try timing.check(deadline, stage: .write)
                return try calls.write(try admittedFD(state), data, currentOffset)
            }
            if let written {
                guard written > 0, written <= min(FrameLimits.socketChunk, data.count - offset) else {
                    throw FrameError.protocolViolation(.webSocketFrame)
                }
                offset += written
            } else { try await ready(write: true, deadline: deadline, stage: .write) }
        }
        try timing.check(deadline, stage: .write)
    }

    func beginClose() {
        let promises = lock.withLock { state -> [FramePromise<Void>] in
            state.closing = true
            let promises = state.waits.values.map(\.promise)
            for wait in state.waits.values { wait.source.cancel(); wait.timer.cancel() }
            state.waits.removeAll()
            return promises
        }
        for promise in promises { promise.finish(.failure(.cancelled)) }
        closeIfQuiescent()
    }

    func close(deadline: ContinuousClock.Instant) async throws {
        beginClose()
        try await closed.value(deadline: deadline, timing: timing)
    }

    private func admittedFD(_ state: State) throws -> Int32 {
        guard !state.closing, let fd = state.fd else { throw FrameError.cancelled }
        return fd
    }

    private func ready(write: Bool, deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) async throws {
        let id: UUID = UUID()
        let promise: FramePromise<Void> = FramePromise<Void>()
        let operation: @Sendable () async throws -> Void = { [self] in
            try timing.check(deadline, stage: stage)
            try installWait(id: id, promise: promise, write: write, deadline: deadline, stage: stage)
            try await promise.value()
            try timing.check(deadline, stage: stage)
        }
        let onCancellation: @Sendable () -> Void = { [self] in
            promise.finish(.failure(.cancelled))
            cancelWait(id)
        }
        return try await withTaskCancellationHandler(operation: operation, onCancel: onCancellation)
    }

    private func installWait(id: UUID, promise: FramePromise<Void>, write: Bool,
                             deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) throws {
        try lock.withLock { (state: inout State) throws -> Void in
            guard !promise.isFinished else { throw FrameError.cancelled }
            guard state.sourceCount < 64 else { throw FrameError.limitExceeded(.controls) }
            let fd: Int32 = try admittedFD(state)
            let source: any DispatchSourceProtocol
            if write {
                source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            } else {
                source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            }
            let timer: any DispatchSourceTimer = DispatchSource.makeTimerSource(queue: queue)
            state.sourceCount += 2
            state.waits[id] = Wait(promise: promise, source: source, timer: timer,
                                   deadline: deadline, stage: stage)
            source.setEventHandler(qos: .unspecified, flags: [], handler: { [self] in resolve(id, timeout: false) })
            timer.setEventHandler(qos: .unspecified, flags: [], handler: { [self] in resolve(id, timeout: true) })
            source.setCancelHandler(qos: .unspecified, flags: [], handler: { [self] in sourceEnded() })
            timer.setCancelHandler(qos: .unspecified, flags: [], handler: { [self] in sourceEnded() })
            let components = timing.now().duration(to: deadline).components
            let interval: Double = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
            let dispatchDeadline: DispatchTime = DispatchTime.now() + interval
            timer.schedule(deadline: dispatchDeadline)
            source.resume(); timer.resume()
        }
    }

    private func resolve(_ id: UUID, timeout: Bool) {
        let completion = lock.withLock { state -> (FramePromise<Void>, ContinuousClock.Instant, FrameDeadlineStage)? in
            guard let wait = state.waits.removeValue(forKey: id) else { return nil }
            wait.source.cancel(); wait.timer.cancel()
            return (wait.promise, wait.deadline, wait.stage)
        }
        guard let (promise, deadline, stage) = completion else { return }
        if timing.now() >= deadline { promise.finish(.failure(.timedOut(stage))) }
        else if timeout {
            // Dispatch timers may fire early. Never manufacture an expiry.
            promise.finish(.success(()))
        } else { promise.finish(.success(())) }
    }

    private func cancelWait(_ id: UUID) {
        let promise = lock.withLock { state -> FramePromise<Void>? in
            guard let wait = state.waits.removeValue(forKey: id) else { return nil }
            wait.source.cancel(); wait.timer.cancel()
            return wait.promise
        }
        promise?.finish(.failure(.cancelled))
    }

    private func sourceEnded() {
        lock.withLock { $0.sourceCount -= 1 }
        closeIfQuiescent()
    }

    private func closeIfQuiescent() {
        let result = lock.withLock { state -> Result<Void, FrameError>? in
            guard state.closing, !state.closed, state.sourceCount == 0 else { return nil }
            state.closed = true
            let fd = state.fd
            state.fd = nil
            if let fd, let code = calls.close(fd) { return .failure(.systemCall(code: code)) }
            return .success(())
        }
        if let result { closed.finish(result) }
    }
}
