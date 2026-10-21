import Foundation
import os
import XCTest
@testable import TacticalVirtualization

enum FrameFixtures {
    static let version = Data("RFB 003.008\n".utf8)
    static func serverInit(width: Int = 2, height: Int = 1, trueColor: UInt8 = 255,
                           name: Data = Data("fixture".utf8)) -> Data {
        var data = Data([UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255),
                         32, 24, 0, trueColor, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        data.append(u32(UInt32(name.count))); data.append(name)
        return data
    }
    static func u32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    static func rect(x: Int = 0, y: Int = 0, width: Int = 2, height: Int = 1,
                     encoding: Int32 = 0, pixels: Data = Data([1, 2, 3, 0, 4, 5, 6, 17])) -> Data {
        var data = Data([UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255),
                         UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
        data.append(u32(UInt32(bitPattern: encoding))); data.append(pixels)
        return data
    }
    static func update(_ rectangle: Data = rect()) -> Data { Data([0, 0, 0, 1]) + rectangle }
    static func initializedDecoder() throws -> RFBStreamDecoder {
        var decoder = RFBStreamDecoder()
        _ = try decoder.consume(version + Data([1, 1, 0, 0, 0, 0]) + serverInit())
        return decoder
    }
    static func serverFrame(opcode: UInt8 = 2, final: Bool = true, payload: Data) -> Data {
        var data = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 { data.append(UInt8(payload.count)) }
        else if payload.count < 65_536 {
            data.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        } else {
            data.append(contentsOf: [127, 0, 0, 0, 0]); data.append(u32(UInt32(payload.count)))
        }
        data.append(payload)
        return data
    }
    static func response(nonce: String, status: Int = 101, accept: String? = nil, extra: String = "") -> Data {
        Data(("HTTP/1.1 \(status) Fixture\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" +
              "Sec-WebSocket-Accept: \(accept ?? FrameHTTPUpgrade.accept(for: nonce))\r\n" + extra + "\r\n").utf8)
    }
}

final class FrameTestClock: Sendable {
    private struct Sleeper { let deadline: ContinuousClock.Instant; let promise: FramePromise<Void> }
    private struct State {
        var now = ContinuousClock.now
        var sleepers: [UUID: Sleeper] = [:]
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    var pendingSleeperCount: Int { state.withLock { $0.sleepers.count } }
    var timing: FrameTiming {
        var timing = FrameTiming()
        timing.now = { [self] in now }
        timing.sleep = { [self] in try await sleep(until: $0) }
        return timing
    }
    func advance(_ duration: Duration) {
        let ready = state.withLock { state -> [FramePromise<Void>] in
            guard !state.stopped else { return [] }
            state.now = state.now.advanced(by: duration)
            let ids = state.sleepers.filter { $0.value.deadline <= state.now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0)?.promise }
        }
        for promise in ready { promise.finish(.success(())) }
    }
    /// Teardown breaks sleepers without advancing the logical protocol clock.
    func stop() {
        let sleepers = state.withLock { state -> [FramePromise<Void>] in
            state.stopped = true
            let sleepers = state.sleepers.values.map(\.promise)
            state.sleepers.removeAll()
            return sleepers
        }
        for promise in sleepers { promise.finish(.failure(.cancelled)) }
    }
    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID(), promise = FramePromise<Void>()
        let ready = try state.withLock { state -> Bool in
            guard !state.stopped else { throw FrameError.cancelled }
            if state.now >= deadline { return true }
            state.sleepers[id] = Sleeper(deadline: deadline, promise: promise)
            return false
        }
        if ready { return }
        defer { _ = state.withLock { $0.sleepers.removeValue(forKey: id) } }
        try await withTaskCancellationHandler {
            try await promise.value()
        } onCancel: { promise.finish(.failure(.cancelled)) }
    }
}

/// No socket, process or environment mutation. Handshake replies are driven by
/// observed client messages, so a missing/extra/out-of-order write cannot pass.
final class FrameScriptedTransport: FrameWireTransport, Sendable {
    private struct State {
        var retired = false
        var inbound: [Data] = [FrameFixtures.version]
        var reader: FrameCompletion<Data?>?
        var eof = false
        var sent: [Data] = []
        var phase = 0
        var requests = 0
        var requestWaiters: [UUID: (count: Int, completion: FrameCompletion<Result<Void, FrameError>>)] = [:]
        var terminalError: FrameError?
        var gatesReleased = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let opened = FrameCompletion<Void>()
    let firstSend = FrameCompletion<Void>()
    let closeStarted = FrameCompletion<Void>()
    let requestWaitRegistered = FrameCompletion<Void>()
    let closeGate: FrameCompletion<Void>
    let openGate: FrameCompletion<Void>?
    let timing: FrameTiming
    let openFailure: FrameError?
    let holdSecurity: Bool

    init(timing: FrameTiming = FrameTiming(), holdClose: Bool = false,
         openGate: FrameCompletion<Void>? = nil, openFailure: FrameError? = nil,
         holdSecurity: Bool = false) {
        self.timing = timing; self.openGate = openGate; self.openFailure = openFailure
        self.holdSecurity = holdSecurity
        closeGate = FrameCompletion<Void>()
        if !holdClose { closeGate.finish(.success(())) }
    }
    var sent: [Data] { state.withLock { $0.sent } }
    var requestCount: Int { state.withLock { $0.requests } }
    var pendingRequestWaiterCount: Int { state.withLock { $0.requestWaiters.count } }
    var gatesReleased: Bool { state.withLock { $0.gatesReleased } }
    func open(deadline: ContinuousClock.Instant) async throws {
        opened.finish(.success(()))
        do {
            if let openFailure { throw openFailure }
            if let openGate { try await openGate.value(deadline: deadline, stage: .handshake, timing: timing) }
        } catch { stop(error: frameError(error)); throw error }
    }
    func sendBinary(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        do { try scriptedSend(data, deadline: deadline) }
        catch { stop(error: frameError(error)); throw error }
    }
    private func scriptedSend(_ data: Data, deadline: ContinuousClock.Instant) throws {
        try timing.check(deadline, stage: .write)
        let result = try state.withLock { state -> (Data?, [FrameCompletion<Result<Void, FrameError>>]) in
            guard !state.retired else { throw state.terminalError ?? FrameError.cancelled }
            state.sent.append(data)
            let response: Data?
            switch state.phase {
            case 0:
                guard data == FrameFixtures.version else { throw FrameError.protocolViolation(.rfbVersion) }
                response = holdSecurity ? nil : Data([1, 1])
            case 1:
                guard data == Data([1]) else { throw FrameError.securityRejected }
                response = Data([0, 0, 0, 0])
            case 2:
                guard data == Data([1]) else { throw FrameError.securityRejected }
                response = FrameFixtures.serverInit()
            case 3:
                guard data == RFBStreamDecoder.pixelFormatAndEncodings else {
                    throw FrameError.protocolViolation(.pixelFormat)
                }
                response = nil
            default:
                guard data == Data([3, 0, 0, 0, 0, 0, 0, 2, 0, 1]) else {
                    throw FrameError.protocolViolation(.serverMessage)
                }
                state.requests += 1; response = nil
            }
            state.phase += 1
            let ids = state.requestWaiters.filter { $0.value.count <= state.requests }.map(\.key)
            let ready = ids.compactMap { state.requestWaiters.removeValue(forKey: $0)?.completion }
            return (response, ready)
        }
        if let data = result.0 { push(data) }
        firstSend.finish(.success(()))
        for waiter in result.1 { waiter.finish(.success(.success(()))) }
    }
    func receiveBinary(deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) async throws -> Data? {
        let promise = FrameCompletion<Data?>()
        let result = try state.withLock { state -> Data? in
            guard !state.retired else { throw state.terminalError ?? FrameError.cancelled }
            if !state.inbound.isEmpty { return state.inbound.removeFirst() }
            if state.eof { promise.finish(.success(nil)); return nil }
            guard state.reader == nil else { throw FrameError.busy }
            state.reader = promise
            return nil
        }
        if let result { return result }
        defer {
            state.withLock { state in
                if state.reader === promise { state.reader = nil }
            }
        }
        do { return try await promise.value(deadline: deadline, stage: stage, timing: timing) }
        catch { stop(error: frameError(error)); throw error }
    }
    func push(_ data: Data) {
        let reader = state.withLock { state -> FrameCompletion<Data?>? in
            if let reader = state.reader { state.reader = nil; return reader }
            state.inbound.append(data); return nil
        }
        reader?.finish(.success(data))
    }
    func end() {
        let reader = state.withLock { state -> FrameCompletion<Data?>? in
            state.eof = true
            let reader = state.reader; state.reader = nil; return reader
        }
        reader?.finish(.success(nil))
    }
    func waitForRequests(_ count: Int) async throws {
        let id = UUID(), waiter = FrameCompletion<Result<Void, FrameError>>()
        let ready = try state.withLock { state -> Bool in
            if state.requests >= count { return true }
            guard !state.retired else { throw state.terminalError ?? FrameError.cancelled }
            state.requestWaiters[id] = (count, waiter)
            return false
        }
        if ready { return }
        requestWaitRegistered.finish(.success(()))
        defer { _ = state.withLock { $0.requestWaiters.removeValue(forKey: id) } }
        // Watchdog is a REAL clock. A frozen test clock must not freeze failure.
        // Wrapping the transport result preserves a real worker timeout/error;
        // it cannot be confused with the harness watchdog's own timeout.
        let result = try await frameTestRealValue(waiter, label: "request count \(count)")
        try result.get()
    }
    private func stop(error: FrameError) {
        let pending = state.withLock { state -> (FrameCompletion<Data?>?, [FrameCompletion<Result<Void, FrameError>>], FrameError) in
            state.retired = true
            if state.terminalError == nil { state.terminalError = error }
            let reason = state.terminalError ?? error
            let reader = state.reader; state.reader = nil
            let requests = state.requestWaiters.values.map { $0.completion }
            state.requestWaiters.removeAll()
            return (reader, requests, reason)
        }
        pending.0?.finish(.failure(pending.2))
        for waiter in pending.1 { waiter.finish(.success(.failure(pending.2))) }
        opened.finish(.failure(pending.2))
        firstSend.finish(.failure(pending.2))
        openGate?.finish(.failure(pending.2))
    }
    func retire() { stop(error: .cancelled) }
    /// Registered at session-closure entry; called synchronously on every exit
    /// before the harness awaits any actor/task cleanup. Idempotent one-shots.
    func releaseHeldGates() {
        state.withLock { $0.gatesReleased = true }
        closeGate.finish(.success(()))
        openGate?.finish(.failure(.cancelled))
    }
    func close(deadline: ContinuousClock.Instant) async throws {
        retire()
        closeStarted.finish(.success(()))
        try await closeGate.value(deadline: deadline, timing: timing)
    }
}

enum FrameTestFailure: Error, Sendable, Equatable {
    case watchdog(String), unsettled(String), ended(String), readerBusy, stopping
}

enum FrameTestInjectedFailure: Error, Sendable, Equatable { case body, cleanup }

/// Failure deadlines only. Never used to order protocol actions. The default
/// FrameTiming here is deliberately unrelated to FrameTestClock.
func frameTestRealValue<Value: Sendable>(
    _ completion: FrameCompletion<Value>, label: String,
    deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(5))
) async throws -> Value {
    do { return try await completion.value(deadline: deadline, timing: FrameTiming()) }
    catch FrameError.timedOut(.cleanup) { throw FrameTestFailure.watchdog(label) }
}

private protocol FrameTestOwnedTask: Sendable {
    var id: UUID { get }
    func cancel()
    func settle(deadline: ContinuousClock.Instant) async throws -> (any Error)?
}

/// Failure-only quarantine: arbitrary noncooperative work cannot be killed by
/// Swift cancellation. Keep its handle rather than orphaning it, report the
/// missing ack, and let QA reject the run. No group join or hidden success.
private enum FrameTestUnsettledTasks {
    private static let tasks = OSAllocatedUnfairLock(initialState: [UUID: any FrameTestOwnedTask]())
    static func retain(_ task: any FrameTestOwnedTask) { tasks.withLock { $0[task.id] = task } }
}

/// An unstructured task with explicit result + settlement acknowledgements. No
/// task-group timeout: an operation ignoring cancellation cannot hold a group's
/// scope open. A missing acknowledgement is reported, never silently "joined".
final class FrameTestTask<Value: Sendable>: FrameTestOwnedTask, Sendable {
    let id = UUID()
    private let label: String
    private let result: FrameCompletion<Result<Value, any Error>>
    private let settled: FrameCompletion<Void>
    private let observed = OSAllocatedUnfairLock(initialState: false)
    private let task: Task<Void, Never>

    init(label: String, operation: @escaping @Sendable () async throws -> Value) {
        self.label = label
        let result = FrameCompletion<Result<Value, any Error>>()
        let settled = FrameCompletion<Void>()
        self.result = result; self.settled = settled
        task = Task {
            let outcome: Result<Value, any Error>
            do { outcome = .success(try await operation()) }
            catch { outcome = .failure(error) }
            result.finish(.success(outcome))
            settled.finish(.success(())) // Last action: no await/work after ack.
        }
    }

    func cancel() { task.cancel() }
    func value(deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(5))) async throws -> Value {
        observed.withLock { $0 = true }
        let outcome: Result<Value, any Error>
        do {
            outcome = try await withTaskCancellationHandler {
                try await frameTestRealValue(result, label: label, deadline: deadline)
            } onCancel: { [self] in cancel() }
        } catch { cancel(); throw error }
        return try outcome.get()
    }
    fileprivate func settle(deadline: ContinuousClock.Instant) async throws -> (any Error)? {
        do { _ = try await frameTestRealValue(settled, label: label, deadline: deadline) }
        catch { throw FrameTestFailure.unsettled(label) }
        await task.value // Ack proved that no cancellable operation remains.
        let outcome = try await frameTestRealValue(result, label: label, deadline: deadline)
        if !observed.withLock({ $0 }), case .failure(let error) = outcome,
           !(error is CancellationError), error as? FrameError != .cancelled { return error }
        return nil
    }
}

private final class FrameTestReadControl<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var stopped = false
        var pending: FrameCompletion<Element?>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func prepare() throws -> FrameCompletion<Element?> {
        try state.withLock { state in
            guard !state.stopped else { throw FrameTestFailure.stopping }
            guard state.pending == nil else { throw FrameTestFailure.readerBusy }
            let request = FrameCompletion<Element?>()
            state.pending = request
            return request
        }
    }
    func resolve(_ request: FrameCompletion<Element?>, value: Element?) {
        let deliver = state.withLock { state -> Bool in
            guard state.pending === request else { return false }
            state.pending = nil // Admit next read BEFORE waking its caller.
            return !state.stopped
        }
        if deliver { request.finish(.success(value)) }
        else { request.finish(.failure(.cancelled)) }
    }
    func stop() {
        let request = state.withLock { state -> FrameCompletion<Element?>? in
            state.stopped = true
            let request = state.pending; state.pending = nil
            return request
        }
        request?.finish(.failure(.cancelled))
    }
}

/// On-demand reads, NOT an eager collector: leaving the reader idle preserves
/// the production newest-one queue and its actual replacement/drop counters.
final class FrameTestStream<Element: Sendable>: Sendable {
    private let control: FrameTestReadControl<Element>
    private let commands: AsyncStream<FrameCompletion<Element?>>.Continuation
    private let reader: FrameTestTask<Void>
    private let label: String

    init(_ stream: AsyncStream<Element>, label: String, owner: FrameTestSession) throws {
        self.label = label
        let control = FrameTestReadControl<Element>()
        let pair = AsyncStream<FrameCompletion<Element?>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        self.control = control; commands = pair.continuation
        reader = try owner.spawn(label: label + " reader") {
            defer { control.stop(); pair.continuation.finish() }
            var iterator = stream.makeAsyncIterator()
            for await request in pair.stream {
                guard !Task.isCancelled else { break }
                let value = await iterator.next()
                control.resolve(request, value: value)
                if case .none = value { break }
            }
        }
    }
    func next(deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(5))) async throws -> Element {
        let request = try control.prepare()
        switch commands.yield(request) {
        case .terminated, .dropped: request.finish(.failure(.cancelled))
        default: break
        }
        do {
            guard let value = try await frameTestRealValue(request, label: label, deadline: deadline) else {
                throw FrameTestFailure.ended(label)
            }
            return value
        } catch { finish(); throw error }
    }
    func first(where predicate: @Sendable (Element) -> Bool) async throws -> Element {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let value = try await next(deadline: deadline)
            if predicate(value) { return value }
        }
    }
    func finish() { control.stop(); commands.finish(); reader.cancel() }
}

struct FrameTestFrameObservation: Sendable {
    let id: UUID
    let current: FrameDelivery
    let updates: FrameTestStream<FrameDelivery>
}
struct FrameTestStateObservation: Sendable {
    let id: UUID
    let snapshot: FrameSnapshot
    let updates: FrameTestStream<FrameSnapshot>
}

/// One owner for body/connect/detach/read/stream tasks and observations. Every
/// task is cancelled and acknowledged, or explicitly reported as unsettled.
/// No cleanup await occurs while a fixture gate remains intentionally held.
final class FrameTestSession: Sendable {
    private struct State: Sendable {
        var stopping = false
        var tasks: [UUID: any FrameTestOwnedTask] = [:]
        var observations: Set<UUID> = []
        var stopStreams: [UUID: @Sendable () -> Void] = [:]
        var clientDisconnected = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let client: FramebufferClient?
    private let wires: [FrameScriptedTransport]
    private let clock: FrameTestClock?
    private let release: @Sendable () -> Void
    private let additionalCleanup: @Sendable () async throws -> Void
    private let reportSecondary: @Sendable (any Error) -> Void

    init(client: FramebufferClient? = nil, wires: [FrameScriptedTransport] = [],
         clock: FrameTestClock? = nil, release: @escaping @Sendable () -> Void = {},
         cleanup: @escaping @Sendable () async throws -> Void = {},
         file: StaticString = #filePath, line: UInt = #line,
         reportSecondary: (@Sendable (any Error) -> Void)? = nil) {
        self.client = client; self.wires = wires; self.clock = clock
        self.release = release; additionalCleanup = cleanup
        self.reportSecondary = reportSecondary ?? { XCTFail("Frame fixture cleanup: \($0)", file: file, line: line) }
    }
    var ownedTaskCount: Int { state.withLock { $0.tasks.count } }
    var observationCount: Int { state.withLock { $0.observations.count } }
    var clientDisconnected: Bool { state.withLock { $0.clientDisconnected } }

    func spawn<Value: Sendable>(label: String, operation: @escaping @Sendable () async throws -> Value) throws -> FrameTestTask<Value> {
        try state.withLock { state in
            guard !state.stopping else { throw FrameTestFailure.stopping }
            let task = FrameTestTask(label: label, operation: operation)
            state.tasks[task.id] = task
            return task
        }
    }
    func wait<Value: Sendable>(_ completion: FrameCompletion<Value>, label: String) async throws -> Value {
        try await frameTestRealValue(completion, label: label)
    }
    func observeFrames() async throws -> FrameTestFrameObservation {
        guard let client else { throw FrameTestFailure.stopping }
        let observation = try await client.observeFrames()
        try await register(observation.id, client: client)
        let stream = try FrameTestStream(observation.updates, label: "frame delivery", owner: self)
        registerStop(observation.id) { stream.finish() }
        return FrameTestFrameObservation(id: observation.id, current: observation.current, updates: stream)
    }
    func observeState() async throws -> FrameTestStateObservation {
        guard let client else { throw FrameTestFailure.stopping }
        let observation = try await client.observeState()
        try await register(observation.id, client: client)
        let stream = try FrameTestStream(observation.updates, label: "state milestone", owner: self)
        registerStop(observation.id) { stream.finish() }
        return FrameTestStateObservation(id: observation.id, snapshot: observation.snapshot, updates: stream)
    }
    func unsubscribe(id: UUID) async {
        let stop = state.withLock { $0.stopStreams.removeValue(forKey: id) }
        stop?()
        await client?.unsubscribe(id: id)
        _ = state.withLock { $0.observations.remove(id) }
    }

    private func register(_ id: UUID, client: FramebufferClient) async throws {
        let installed = state.withLock { state -> Bool in
            guard !state.stopping else { return false }
            state.observations.insert(id); return true
        }
        if !installed { await client.unsubscribe(id: id); throw FrameTestFailure.stopping }
    }
    private func registerStop(_ id: UUID, stop: @escaping @Sendable () -> Void) {
        let installed = state.withLock { state -> Bool in
            guard !state.stopping else { return false }
            state.stopStreams[id] = stop; return true
        }
        if !installed { stop() }
    }
    private func releaseGates() {
        for wire in wires { wire.releaseHeldGates() }
        release()
    }

    func run<Value: Sendable>(_ body: @escaping @Sendable (FrameTestSession) async throws -> Value) async throws -> Value {
        let bodyTask = try spawn(label: "test body") { [self] in
            // FIRST action at session-closure entry, before any await/throw:
            // install unconditional synchronous gate release on every exit.
            defer { releaseGates() }
            return try await body(self)
        }
        let primary: Result<Value, any Error>
        do { primary = .success(try await bodyTask.value(deadline: ContinuousClock.now.advanced(by: .seconds(15)))) }
        catch { primary = .failure(error) }
        releaseGates() // Also breaks gates if the body hit its REAL watchdog.
        // Unstructured, owned cleanup is not born cancelled with its caller.
        // Its INTERNAL joins are all real-deadlined; no task-group scope wait.
        let cleanupTask = Task { [self] in await finish() }
        let secondary = await cleanupTask.value
        for error in secondary { reportSecondary(error) }
        switch primary {
        case .failure(let original): throw original // Cleanup never masks it.
        case .success(let value):
            if let error = secondary.first { throw error }
            return value
        }
    }

    private func finish() async -> [any Error] {
        releaseGates() // Synchronous and unconditional, before ANY cleanup await.
        let owned = state.withLock { state -> ([any FrameTestOwnedTask], [UUID], [@Sendable () -> Void]) in
            state.stopping = true
            return (Array(state.tasks.values), Array(state.observations), Array(state.stopStreams.values))
        }
        for wire in wires { wire.retire() }
        clock?.stop()
        for stop in owned.2 { stop() }
        for task in owned.0 { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let cleanup = FrameTestTask<Void>(label: "disconnect/unsubscribe") { [self] in
            for id in owned.1 { await unsubscribe(id: id) }
            if let client {
                try await client.disconnect()
                state.withLock { $0.clientDisconnected = true }
            }
            try await additionalCleanup()
        }
        state.withLock { $0.tasks[cleanup.id] = cleanup }
        var failures: [any Error] = []
        do { try await cleanup.value(deadline: deadline) }
        catch { failures.append(error); cleanup.cancel() }
        for task in owned.0 + [cleanup] {
            do {
                if let error = try await task.settle(deadline: deadline) { failures.append(error) }
                _ = state.withLock { $0.tasks.removeValue(forKey: task.id) }
            } catch {
                failures.append(error)
                FrameTestUnsettledTasks.retain(task)
                // Also retain the session registry entry: never falsely claim
                // settlement or block indefinitely joining an uncooperative task.
            }
        }
        return failures
    }
}

final class FrameTestDiagnostics: Sendable {
    private let errors = OSAllocatedUnfairLock(initialState: [any Error]())
    func record(_ error: any Error) { errors.withLock { $0.append(error) } }
    var failures: [any Error] { errors.withLock { $0 } }
}
