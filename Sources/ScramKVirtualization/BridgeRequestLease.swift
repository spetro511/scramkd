import CryptoKit
import Foundation
import ScramKCore
import os

struct BridgeTiming: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    var nanoseconds: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
        try await ContinuousClock().sleep(until: $0)
    }
}

struct BridgeTestHooks: Sendable {
    var beforeWrite: (@Sendable (UUID, Int) async -> Void)?
    var afterWrite: (@Sendable (UUID, Int) async -> Void)?
    var pendingPublished: (@Sendable (PendingIntercept) async -> Void)?
    var beforeApprovalAdmission: (@Sendable (BridgeApprovalKey) async -> Void)?
    var afterApprovalAdmission: (@Sendable (BridgeApprovalReceipt) async -> Void)?
    var beforeRetirementCompletion: (@Sendable (UUID, Bool) async -> Void)?
    var beforeRetirementTimerClaim: (@Sendable (UUID) async -> Void)?
    var detachObserverRegistered: (@Sendable (UUID) async -> Void)?
}

enum BridgeCompletionError: Error, Sendable, Equatable {
    case multipleConsumers
}

/// Exactly one consumer, with completion permitted before the consumer arrives.
/// A second consumer fails explicitly; it can never replace a continuation.
final class BridgeOneShot<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
        var consumerClaimed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onConsumerRegistered: (@Sendable () -> Void)?

    init(onConsumerRegistered: (@Sendable () -> Void)? = nil) {
        self.onConsumerRegistered = onConsumerRegistered
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let action = state.withLock { state -> (Bool, Result<Value, any Error>?) in
                guard !state.consumerClaimed else { return (false, .failure(BridgeCompletionError.multipleConsumers)) }
                state.consumerClaimed = true
                if let result = state.result { return (true, result) }
                state.continuation = continuation
                return (true, nil)
            }
            if action.0 { onConsumerRegistered?() }
            if let result = action.1 { continuation.resume(with: result) }
        }
    }

    @discardableResult
    func finish(_ result: Result<Value, any Error>) -> Bool {
        resolve { result } != nil
    }

    /// Select the first result at its completion linearization point. The selector
    /// must be bounded and synchronous: no await, I/O, logging, or test barriers.
    @discardableResult
    func resolve(using select: @Sendable () -> Result<Value, any Error>) -> Result<Value, any Error>? {
        let action = state.withLock { state -> (Result<Value, any Error>?, CheckedContinuation<Value, any Error>?) in
            guard state.result == nil else { return (nil, nil) }
            let result = select()
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return (result, continuation)
        }
        if let result = action.0 { action.1?.resume(with: result) }
        return action.0
    }
}

/// One owned task is the promise's sole consumer. Arbitrarily many observers may
/// await that task's cached value without overwriting continuations. Cancelling an
/// observer does not cancel this task, the producer, or the independent cleanup.
final class BridgeSharedCompletion<Value: Sendable>: Sendable {
    private let result: BridgeOneShot<Value>
    private let task: Task<Value, any Error>

    init() {
        let result = BridgeOneShot<Value>()
        self.result = result
        self.task = Task { try await result.value() }
    }

    func value() async throws -> Value { try await task.value }

    @discardableResult
    func finish(_ value: Result<Value, any Error>) -> Bool { result.finish(value) }

    @discardableResult
    func resolve(using select: @Sendable () -> Result<Value, any Error>) -> Result<Value, any Error>? {
        result.resolve(using: select)
    }
}

struct BridgeWriteProgress: Sendable {
    var bytes = 0
    var chunks = 0
    var stage: BridgeTransmissionStage = .none
    var admittedCursor: UInt64?
    var admittedPermit: PermissivePermit?
    var writeDeadline: ContinuousClock.Instant?
    var completedAt: ContinuousClock.Instant?
}

/// One lock owns connection admission, request leases, offsets, and write counts.
/// Every physical write acquires this lock before the writer's descriptor lock.
/// It never waits for readiness, parses/hashes, or calls an asynchronous API.
final class BridgeAdmissionFence: Sendable {
    private struct Request: Sendable {
        let frame: Data
        let key: BridgeApprovalKey?
        var approvalDeadline: ContinuousClock.Instant?
        let approval: BridgeOneShot<BridgeApprovalReceipt>?
        let response: BridgeOneShot<Data>?
        var progress = BridgeWriteProgress()
        var revoked: BridgeRevocationReason?
    }
    private struct State: Sendable {
        var generation: UUID?
        var writer: MCPNonblockingWriter?
        var revoked: BridgeRevocationReason?
        var requests: [UUID: Request] = [:]
        var writeOwner: UUID?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(generation: UUID, writer: MCPNonblockingWriter) throws {
        try state.withLock { state in
            guard state.generation == nil else { throw BridgeError.busy }
            state.generation = generation
            state.writer = writer
            state.revoked = nil
        }
    }

    func register(
        id: UUID, generation: UUID, frame: Data, key: BridgeApprovalKey?,
        deadline: ContinuousClock.Instant?, approval: BridgeOneShot<BridgeApprovalReceipt>?, response: BridgeOneShot<Data>?
    ) throws {
        if let key {
            guard key.requestID == id, key.connectionGeneration == generation else { throw BridgeError.staleGeneration }
            guard constantTimeHexEquals(key.sha256, Self.key(requestID: id, generation: generation, frame: frame).sha256) else {
                throw BridgeError.wrongHash
            }
        }
        try state.withLock { state in
            try Self.checkConnection(state, generation: generation)
            guard state.requests.count < BridgeLimits.pendingRequests else { throw BridgeError.busy }
            guard state.requests[id] == nil else { throw BridgeError.busy }
            if key != nil, state.requests.values.contains(where: { $0.key != nil }) { throw BridgeError.busy }
            state.requests[id] = Request(frame: frame, key: key, approvalDeadline: deadline, approval: approval, response: response)
        }
    }

    @discardableResult
    func updateApprovalDeadline(id: UUID, generation: UUID, deadline: ContinuousClock.Instant) -> Bool {
        state.withLock { state in
            guard state.generation == generation,
                  state.revoked == nil,
                  var request = state.requests[id],
                  request.key != nil,
                  request.revoked == nil,
                  request.progress.admittedCursor == nil
            else {
                return false
            }
            request.approvalDeadline = deadline
            state.requests[id] = request
            return true
        }
    }

    func beginWrite(id: UUID, generation: UUID) throws {
        try state.withLock { state in
            try Self.checkConnection(state, generation: generation)
            guard state.writeOwner == nil, state.requests[id] != nil else { throw BridgeError.busy }
            state.writeOwner = id
        }
    }

    func finishWrite(id: UUID, generation: UUID) {
        state.withLock { state in
            guard state.generation == generation, state.writeOwner == id else { return }
            state.writeOwner = nil
        }
    }

    func approve(
        on gate: isolated HardwareInterlockGate, key: BridgeApprovalKey,
        now: ContinuousClock.Instant, nanoseconds: UInt64,
        clock: (@Sendable () -> ContinuousClock.Instant)? = nil,
        counter: (@Sendable () -> UInt64)? = nil
    ) throws -> BridgeApprovalReceipt {
        let result = try state.withLockUnchecked { state -> (BridgeApprovalReceipt, BridgeOneShot<BridgeApprovalReceipt>?) in
            try Self.checkConnection(state, generation: key.connectionGeneration)
            guard var request = state.requests[key.requestID], let expected = request.key else { throw BridgeError.staleApproval }
            try Self.checkKey(key, expected: expected)
            let admittedNow = clock?() ?? now
            guard let deadline = request.approvalDeadline, admittedNow < deadline else { throw BridgeError.expired }
            if let revoked = request.revoked { throw BridgeError.revoked(revoked, receipt: nil) }
            guard request.progress.admittedCursor == nil else { throw BridgeError.staleApproval }
            guard gate.currentStatus == .armed else {
                let error: HardwareInterlockError = gate.currentStatus == .emergencyAbort ? .emergencyAbortActive : .gateLocked
                throw BridgeError.gateRejected(error, receipt: nil)
            }
            // The API caller's task is still the task executing this isolated
            // actor operation. Cancellation before this point prevents the grant;
            // cancellation after it must not relabel an accepted Core transition.
            try Task.checkCancellation()
            let permit = try gate.issuePermissivePermit(forRequestID: key.requestID, ttl: .seconds(5), now: admittedNow)
            let cursor = gate.observationSnapshot(historyLimit: 0).cursor
            request.progress.admittedCursor = cursor
            request.progress.admittedPermit = permit
            request.progress.writeDeadline = permit.expiresAt
            state.requests[key.requestID] = request
            return (BridgeApprovalReceipt(key: key, admittedGateCursor: cursor,
                                           admittedAtNanoseconds: counter?() ?? nanoseconds), request.approval)
        }
        result.1?.finish(.success(result.0))
        return result.0
    }

    func writePrivileged(
        on gate: isolated HardwareInterlockGate, id: UUID, generation: UUID,
        offset: Int, now: ContinuousClock.Instant, deadline: ContinuousClock.Instant, maximumCount: Int = 16_384,
        clock: (@Sendable () -> ContinuousClock.Instant)? = nil
    ) throws -> MCPTransportWriteResult {
        // Actor state cannot change between this snapshot and the synchronous
        // lock/write/relock region. No async observer supplies authorization.
        let snapshot = gate.observationSnapshot(historyLimit: 0)
        return try state.withLockUnchecked { state in
            try Self.checkConnection(state, generation: generation)
            guard var request = state.requests[id], request.key != nil else { throw BridgeError.staleApproval }
            let writeNow = clock?() ?? now
            try Self.checkWrite(request, owner: state.writeOwner, id: id, offset: offset, now: writeNow, deadline: deadline)
            guard snapshot.currentStatus == .permissiveGranted,
                  request.progress.admittedCursor == snapshot.cursor,
                  let permit = request.progress.admittedPermit,
                  gate.activePermit == permit,
                  gate.stateVersion == permit.issuedStateVersion else {
                if request.progress.bytes > 0 { state.revoked = .gateChanged; state.writer?.revoke() }
                throw BridgeError.gateRejected(
                    snapshot.currentStatus == .emergencyAbort ? .emergencyAbortActive : .gateLocked, receipt: nil
                )
            }
            guard let writer = state.writer else { throw BridgeError.detached }
            let result = try writer.writeChunk(request.frame, offset: offset, maximumCount: maximumCount)
            if case .written(let count) = result {
                try Self.record(count, request: &request)
                if request.progress.stage == .complete { request.progress.completedAt = clock?() ?? now }
                state.requests[id] = request
                if request.progress.stage == .complete {
                    // Same actor turn and same session fence as the final byte.
                    // Atomically consume the single-use permit and return gate to locked.
                    try gate.consumePermissivePermit(permit, forRequestID: id, now: writeNow)
                }
            }
            return result
        }
    }

    func writeMetadata(id: UUID, generation: UUID, offset: Int, now: ContinuousClock.Instant,
                       deadline: ContinuousClock.Instant,
                       clock: (@Sendable () -> ContinuousClock.Instant)? = nil) throws -> MCPTransportWriteResult {
        try state.withLock { state in
            try Self.checkConnection(state, generation: generation)
            guard var request = state.requests[id], request.key == nil else { throw BridgeError.staleApproval }
            try Self.checkWrite(request, owner: state.writeOwner, id: id, offset: offset, now: clock?() ?? now, deadline: deadline)
            guard let writer = state.writer else { throw BridgeError.detached }
            let result = try writer.writeChunk(request.frame, offset: offset)
            if case .written(let count) = result {
                try Self.record(count, request: &request)
                if request.progress.stage == .complete { request.progress.completedAt = clock?() ?? now }
                state.requests[id] = request
            }
            return result
        }
    }

    /// Revocation is synchronous even while the bridge actor awaits a gate or I/O.
    /// Only connection/current-generation identities installed at this call are
    /// captured. No state or policy is carried into a later install.
    @discardableResult
    func revoke(_ scope: RevocationScope, reason: BridgeRevocationReason) -> UUID? {
        let actions = state.withLock { state -> ([Request], MCPNonblockingWriter?, UUID?) in
            guard let generation = state.generation else { return ([], nil, nil) }
            let ids: [UUID]
            var retire = false
            switch scope {
            case .request(let key):
                guard key.connectionGeneration == generation, state.requests[key.requestID]?.key == key else { return ([], nil, nil) }
                ids = [key.requestID]
            case .privileged(let requested):
                guard requested == generation else { return ([], nil, nil) }
                ids = state.requests.filter { $0.value.key != nil }.map(\.key)
            case .connection(let requested):
                guard requested == generation else { return ([], nil, nil) }
                ids = Array(state.requests.keys)
                retire = true
            case .currentConnection:
                ids = Array(state.requests.keys)
                retire = true
            }
            var requests: [Request] = []
            for id in ids {
                guard var request = state.requests[id] else { continue }
                request.revoked = request.revoked ?? reason
                if request.progress.bytes > 0 { retire = true }
                state.requests[id] = request
                requests.append(request)
            }
            if retire {
                state.revoked = state.revoked ?? reason
                // Retirement fences *all* frames; a partial line can never be
                // followed by a different JSON request on this connection.
                requests = state.requests.values.map { $0 }
            }
            return (requests, retire ? state.writer : nil, generation)
        }
        actions.1?.revoke()
        for request in actions.0 {
            request.approval?.finish(.failure(BridgeError.revoked(reason, receipt: nil)))
            request.response?.finish(.failure(BridgeError.revoked(reason, receipt: nil)))
        }
        return actions.2
    }

    func relockAbandoned(on gate: isolated HardwareInterlockGate, id: UUID, generation: UUID) throws {
        let snapshot = gate.observationSnapshot(historyLimit: 0)
        try state.withLockUnchecked { state in
            guard state.generation == generation, let request = state.requests[id],
                  let cursor = request.progress.admittedCursor,
                  snapshot.currentStatus == .permissiveGranted, snapshot.cursor == cursor else { return }
            try gate.lock()
        }
    }

    func fail(generation: UUID, error: BridgeError) {
        let actions = state.withLock { state -> ([Request], MCPNonblockingWriter?) in
            guard state.generation == generation else { return ([], nil) }
            state.revoked = state.revoked ?? .transportFailure
            return (Array(state.requests.values), state.writer)
        }
        actions.1?.revoke()
        for request in actions.0 {
            request.approval?.finish(.failure(error))
            request.response?.finish(.failure(error))
        }
    }

    func progress(id: UUID, generation: UUID) -> BridgeWriteProgress? {
        state.withLock { $0.generation == generation ? $0.requests[id]?.progress : nil }
    }

    func revocation(id: UUID, generation: UUID) -> BridgeRevocationReason? {
        state.withLock { state in
            guard state.generation == generation else { return nil }
            return state.requests[id]?.revoked ?? state.revoked
        }
    }

    func check(generation: UUID) throws { try state.withLock { try Self.checkConnection($0, generation: generation) } }

    func remove(id: UUID, generation: UUID) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.requests.removeValue(forKey: id)
            if state.writeOwner == id { state.writeOwner = nil }
        }
    }

    func clear(generation: UUID) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state = State()
        }
    }

    private static func checkConnection(_ state: State, generation: UUID) throws {
        guard state.generation == generation else { throw BridgeError.staleGeneration }
        if let revoked = state.revoked { throw BridgeError.revoked(revoked, receipt: nil) }
    }

    private static func checkKey(_ key: BridgeApprovalKey, expected: BridgeApprovalKey) throws {
        guard key.connectionGeneration == expected.connectionGeneration else { throw BridgeError.staleGeneration }
        guard key.requestID == expected.requestID else { throw BridgeError.staleApproval }
        guard constantTimeHexEquals(key.sha256, expected.sha256) else { throw BridgeError.wrongHash }
    }

    private static func checkWrite(_ request: Request, owner: UUID?, id: UUID, offset: Int,
                                   now: ContinuousClock.Instant, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        if let revoked = request.revoked { throw BridgeError.revoked(revoked, receipt: nil) }
        guard now < deadline else { throw BridgeError.timedOut(.write, receipt: nil) }
        if let writeDeadline = request.progress.writeDeadline, now >= writeDeadline {
            throw BridgeError.timedOut(.write, receipt: nil)
        }
        guard owner == id, offset == request.progress.bytes, offset < request.frame.count else { throw BridgeError.staleApproval }
    }

    private static func record(_ count: Int, request: inout Request) throws {
        guard count > 0, count <= request.frame.count - request.progress.bytes else { throw MCPTransportError.noWriteProgress }
        request.progress.bytes += count
        request.progress.chunks += 1
        request.progress.stage = request.progress.bytes == request.frame.count ? .complete : .partial
    }
}

extension BridgeAdmissionFence {
    static func key(requestID: UUID, generation: UUID, frame: Data) -> BridgeApprovalKey {
        let digest = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
        return BridgeApprovalKey(requestID: requestID, sha256: digest, connectionGeneration: generation)
    }
}
