import Foundation
import ScramKCore
import os

/// Explicitly attached, app-owned MCP stdio client. All tools/call requests use a
/// one-shot approval of frozen bytes; metadata exemption is schema-defined here.
/// External clients talking directly to Docker do not pass through this actor.
public actor ContainerSocketBridge {
    private struct RPC: Sendable {
        let id: UUID
        let generation: UUID
        let frame: Data
        let key: BridgeApprovalKey?
        let approval: BridgeOneShot<BridgeApprovalReceipt>?
        let response: BridgeOneShot<Data>
        let createdAt: ContinuousClock.Instant
        let startNanoseconds: UInt64
        let baselineReadBytes: Int
        let baselineReadChunks: Int
        let overallDeadline: ContinuousClock.Instant?
        var readBytes = 0
        var readChunks = 0
        var correlated = false
        var timer: Task<Void, Never>?
        var timerID: UUID?
        var deadline: ContinuousClock.Instant?
        var deadlineKind: BridgeDeadlineKind?
    }
    private struct WriteWaiter: Sendable {
        let id: UUID
        let generation: UUID
        let ready: BridgeOneShot<Void>
    }
    private struct Retirement: Sendable {
        let id: UUID
        let generation: UUID
        let completion: BridgeSharedCompletion<BridgeDetachReceipt>
        let started: UInt64
        let deadline: ContinuousClock.Instant
        let processIdentifier: Int32?
        var requested: Bool
        let settledCount: Int
        var stopSucceeded: Bool?
    }

    private let interlockGate: HardwareInterlockGate
    private let configuration: MCPProcessConfiguration
    private let timing: BridgeTiming
    private let hooks: BridgeTestHooks
    public let activeHoldPolicy: ActiveHoldPolicy
    public private(set) var isAuthorizationHoldActive: Bool = false
    private nonisolated let admission = BridgeAdmissionFence()
    private var connectionState: BridgeConnectionState = .detached
    private var generation: UUID?
    private var transport: MCPProcessTransport?
    private var localProcessIdentifier: Int32?
    private var observedExitStatus: Int32?
    private var serverInfo: ServerInfo?
    private var attachGateCursor: UInt64?
    private var serverAdvertisesTools = false
    private var pendingIntercept: PendingIntercept?
    private var latestTransfer: BridgeTransferReceipt?
    private var pending: [UUID: RPC] = [:]
    private var writeOwner: UUID?
    private var writeWaiters: [WriteWaiter] = []
    private var recentReceipts: [BridgeApprovalKey: BridgeTransferReceipt] = [:]
    private var recentKeys: [BridgeApprovalKey] = []
    private var framer = MCPLineFramer()
    private var readBytes = 0
    private var readChunks = 0
    private var stderrBytes = 0
    private var cursor: UInt64 = 0
    private var history: [BridgeEvent] = []
    private var subscribers: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]
    private var readerTask: Task<Void, Never>?
    private var attachWorker: Task<Void, Never>?
    private var attachTimer: Task<Void, Never>?
    private var attachCompletion: BridgeOneShot<ServerInfo>?
    private var retirement: Retirement?
    private var stopWorker: Task<Void, Never>?
    private var stopTimer: Task<Void, Never>?

    public init(
        containerName: String = "screenenv_container",
        interlockGate: HardwareInterlockGate,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [String]? = nil,
        activeHoldPolicy: ActiveHoldPolicy = ActiveHoldPolicy()
    ) {
        self.interlockGate = interlockGate
        self.timing = BridgeTiming()
        self.hooks = BridgeTestHooks()
        self.activeHoldPolicy = activeHoldPolicy
        if let arguments {
            self.configuration = MCPProcessConfiguration(executableURL: executableURL, arguments: arguments)
        } else {
            let candidates = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
            let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/run/docker.sock").path
            let environment = DefaultSubprocessEnvironmentScrubber.scrub(ProcessInfo.processInfo.environment)
            self.configuration = MCPProcessConfiguration(
                executableURL: URL(fileURLWithPath: path),
                arguments: ["--host", "unix://" + socket, "exec", "-i", containerName, "python", "-m", "screenenv.mcp_server"],
                environment: environment
            )
        }
    }

    init(
        interlockGate: HardwareInterlockGate,
        configuration: MCPProcessConfiguration,
        timing: BridgeTiming = BridgeTiming(),
        hooks: BridgeTestHooks = BridgeTestHooks(),
        activeHoldPolicy: ActiveHoldPolicy = ActiveHoldPolicy()
    ) {
        self.interlockGate = interlockGate
        self.configuration = configuration
        self.timing = timing
        self.hooks = hooks
        self.activeHoldPolicy = activeHoldPolicy
    }

    deinit {
        admission.revoke(.currentConnection, reason: .detached)
        readerTask?.cancel()
        attachWorker?.cancel()
        attachTimer?.cancel()
        stopTimer?.cancel()
        retirement?.completion.finish(.failure(BridgeError.detached))
        for request in pending.values { request.timer?.cancel() }
        for subscriber in subscribers.values { subscriber.finish() }
        if let transport {
            Task {
                do { try await transport.stop() }
                catch { Logger(subsystem: "com.scramk.virtualization", category: "lifecycle").error("Bridge deinit cleanup incomplete") }
            }
        }
    }

    public var isBridgeActive: Bool {
        guard connectionState == .attached, let generation else { return false }
        do { try admission.check(generation: generation); return true }
        catch { return false }
    }

    public nonisolated var configuredEnvironment: [String: String] {
        configuration.environment ?? [:]
    }

    public nonisolated func validateContainerCreationPayload(
        _ payload: Data,
        profile: ContainerSecurityProfile = .strictAirgap
    ) throws {
        try ContainerCreationPolicy.inspectContainerCreatePayload(payload, profile: profile)
    }

    var advertisesTools: Bool { serverAdvertisesTools }

    public func snapshot(after requestedCursor: UInt64 = 0) -> BridgeSnapshot {
        let events = history.filter { $0.cursor > requestedCursor }
        let available = cursor - min(cursor, requestedCursor)
        return BridgeSnapshot(
            cursor: cursor, connectionState: connectionState, generation: generation, serverInfo: serverInfo,
            pendingIntercept: pendingIntercept, latestTransfer: latestTransfer, events: events,
            omittedEventCount: available - min(available, UInt64(events.count))
        )
    }

    public func observe(after requestedCursor: UInt64 = 0) -> BridgeObservation {
        let id = UUID()
        let pair = AsyncStream<BridgeEvent>.makeStream(bufferingPolicy: .bufferingNewest(BridgeLimits.observationBuffer))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id: id) } }
        subscribers[id] = pair.continuation
        return BridgeObservation(id: id, snapshot: snapshot(after: requestedCursor), events: pair.stream)
    }

    public func unsubscribe(id: UUID) { subscribers.removeValue(forKey: id)?.finish() }

    public func attach() async throws -> ServerInfo {
        guard connectionState == .detached, transport == nil, pending.isEmpty, retirement == nil else { throw BridgeError.busy }
        try Task.checkCancellation()
        let gen = UUID()
        let io: MCPProcessTransport
        do { io = try MCPProcessTransport(configuration: configuration) }
        catch { throw Self.bridgeError(error) }
        try admission.install(generation: gen, writer: io.writer)
        generation = gen
        transport = io
        framer = MCPLineFramer()
        readBytes = 0
        readChunks = 0
        stderrBytes = 0
        observedExitStatus = nil
        serverInfo = nil
        attachGateCursor = nil
        serverAdvertisesTools = false
        connectionState = .attaching
        emit(.connectionChanged(.attaching), generation: gen)
        let completion = BridgeOneShot<ServerInfo>()
        attachCompletion = completion
        let deadline = timing.now().advanced(by: .seconds(5))
        let clock = timing
        let admission = self.admission
        attachTimer = Task { [weak self] in
            do { try await clock.sleep(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.attachExpired(generation: gen)
        }
        attachWorker = Task { [weak self, io] in
            do {
                guard let self else { throw BridgeError.detached }
                try await self.requireLockedForAttach(generation: gen)
                try await io.start()
                let info = try await self.finishAttach(generation: gen, io: io, deadline: deadline)
                completion.finish(.success(info))
            } catch {
                let typed = Self.bridgeError(error)
                completion.finish(.failure(typed))
                await self?.attachFailed(generation: gen, error: typed)
            }
            await self?.attachWorkerFinished(generation: gen)
        }
        return try await withTaskCancellationHandler {
            do {
                let info = try await completion.value()
                try Task.checkCancellation()
                try admission.check(generation: gen)
                return info
            }
            catch {
                attachFailed(generation: gen, error: Self.bridgeError(error))
                throw error
            }
        } onCancel: {
            admission.revoke(.connection(generation: gen), reason: .requestCancelled)
            completion.finish(.failure(BridgeError.cancelled(receipt: nil)))
        }
    }

    private func requireLockedForAttach(generation gen: UUID) async throws {
        let snapshot = await interlockGate.observationSnapshot(historyLimit: 0)
        try admission.check(generation: gen)
        guard snapshot.currentStatus == .locked else {
            throw BridgeError.gateRejected(snapshot.currentStatus == .emergencyAbort ? .emergencyAbortActive : .gateLocked, receipt: nil)
        }
        attachGateCursor = snapshot.cursor
    }

    private func finishAttach(generation gen: UUID, io: MCPProcessTransport, deadline: ContinuousClock.Instant) async throws -> ServerInfo {
        try admission.check(generation: gen)
        guard generation == gen, connectionState == .attaching else { throw BridgeError.staleGeneration }
        localProcessIdentifier = await io.processIdentifier
        let output = io.output
        readerTask = Task { [weak self] in
            do {
                for try await item in output {
                    guard !Task.isCancelled else { return }
                    await self?.receive(item, generation: gen)
                }
                await self?.outputEnded(generation: gen)
            } catch { await self?.connectionFailed(generation: gen, error: Self.bridgeError(error)) }
        }
        let params: MCPJSONValue = .object([
            "protocolVersion": .string(BridgeLimits.supportedProtocols[0]),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("scramkd"), "version": .string("1.0")])
        ])
        let result = try await performRPC(method: "initialize", params: params, generation: gen, toolName: nil, overallDeadline: deadline)
        guard let response = try MCPJSONCodec.decode(result.rawResponseData).object,
              let initialize = response["result"]?.object,
              let version = initialize["protocolVersion"]?.string,
              BridgeLimits.supportedProtocols.contains(version),
              let capabilities = initialize["capabilities"]?.object,
              let server = initialize["serverInfo"]?.object,
              let name = server["name"]?.string, !name.isEmpty, name.utf8.count <= 256,
              let serverVersion = server["version"]?.string, !serverVersion.isEmpty, serverVersion.utf8.count <= 256,
              capabilities["tools"] == nil || capabilities["tools"]?.object != nil else {
            throw BridgeError.protocolViolation(reason: "Invalid initialize result", receipt: result.receipt)
        }
        try await sendInitialized(generation: gen, deadline: deadline)
        let gateSnapshot = await interlockGate.observationSnapshot(historyLimit: 0)
        try admission.check(generation: gen)
        guard generation == gen, connectionState == .attaching else { throw BridgeError.staleGeneration }
        guard timing.now() < deadline else { throw BridgeError.timedOut(.attach, receipt: nil) }
        guard gateSnapshot.currentStatus == .locked, gateSnapshot.cursor == attachGateCursor else {
            throw BridgeError.gateRejected(gateSnapshot.currentStatus == .emergencyAbort ? .emergencyAbortActive : .gateLocked, receipt: nil)
        }
        let info = ServerInfo(generation: gen, advertisedName: name, advertisedVersion: serverVersion, protocolVersion: version)
        serverInfo = info
        serverAdvertisesTools = capabilities["tools"] != nil
        connectionState = .attached
        attachTimer?.cancel()
        attachTimer = nil
        emit(.serverInitialized(info), generation: gen)
        emit(.connectionChanged(.attached), generation: gen)
        return info
    }

    private func attachWorkerFinished(generation gen: UUID) {
        guard generation == gen else { return }
        attachWorker = nil
        attachCompletion = nil
        finishRetirementIfReady()
    }

    private func attachExpired(generation gen: UUID) {
        guard generation == gen, connectionState == .attaching else { return }
        attachFailed(generation: gen, error: .timedOut(.attach, receipt: nil))
    }

    private func attachFailed(generation gen: UUID, error: BridgeError) {
        guard generation == gen else { return }
        attachTimer?.cancel()
        attachTimer = nil
        attachCompletion?.finish(.failure(error))
        connectionFailed(generation: gen, error: error)
    }

    public func detach() async -> BridgeDetachReceipt {
        let started = timing.nanoseconds()
        if transport == nil, generation == nil {
            if connectionState != .detached {
                connectionState = .detached
                emit(.connectionChanged(.detached), generation: nil)
            }
            return BridgeDetachReceipt(generation: nil, localProcessIdentifier: nil, terminationRequested: false,
                                       observedExitStatus: nil, handlesClosed: true, settledRequestCount: 0,
                                       elapsedNanoseconds: elapsed(since: started), outcome: .alreadyDetached)
        }
        beginRetirement(requested: true, error: .revoked(.detached, receipt: nil))
        guard let completion = retirement?.completion else {
            return BridgeDetachReceipt(generation: generation, localProcessIdentifier: localProcessIdentifier,
                                       terminationRequested: false, observedExitStatus: observedExitStatus,
                                       handlesClosed: false, settledRequestCount: 0, elapsedNanoseconds: elapsed(since: started),
                                       outcome: .cleanupIncomplete)
        }
        // The bounded teardown worker, not caller cancellation, owns cleanup.
        if let observer = hooks.detachObserverRegistered, let gen = retirement?.generation { await observer(gen) }
        do { return try await completion.value() }
        catch {
            return BridgeDetachReceipt(generation: generation, localProcessIdentifier: localProcessIdentifier,
                                       terminationRequested: true, observedExitStatus: observedExitStatus,
                                       handlesClosed: false, settledRequestCount: 0, elapsedNanoseconds: elapsed(since: started),
                                       outcome: .cleanupIncomplete)
        }
    }

    public func launchBridge() async throws { _ = try await attach() }
    public func terminateBridge() async { _ = await detach() }

    public func submitTool(name: String, argumentsJSON: Data, generation gen: UUID) async throws -> BridgeToolResult {
        try requireAttached(gen)
        try MCPJSONCodec.validateToolName(name)
        let arguments = try MCPJSONCodec.decode(argumentsJSON, maximumBytes: BridgeLimits.requestBytes)
        guard arguments.object != nil else { throw BridgeError.malformedRequest }
        return try await performRPC(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]),
                                    generation: gen, toolName: name, overallDeadline: nil)
    }

    /// Caller IDs are validated but remapped to fresh owned UUIDs on this app-only
    /// connection. Returned raw responses contain the actual owned wire ID.
    public func dispatchMCPCommand(_ payload: Data) async throws -> Data {
        let request = try MCPJSONCodec.publicRequest(payload)
        guard let gen = generation else { throw BridgeError.detached }
        try requireAttached(gen)
        switch request {
        case .ping:
            return try await performRPC(method: "ping", params: .object([:]), generation: gen,
                                        toolName: nil, overallDeadline: nil).rawResponseData
        case .listTools(let cursor):
            let params: MCPJSONValue = .object(cursor.map { ["cursor": .string($0)] } ?? [:])
            return try await performRPC(method: "tools/list", params: params, generation: gen,
                                        toolName: nil, overallDeadline: nil).rawResponseData
        case .tool(let name, let arguments):
            return try await performRPC(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]),
                                        generation: gen, toolName: name, overallDeadline: nil).rawResponseData
        }
    }

    public func approve(_ key: BridgeApprovalKey) async throws -> BridgeApprovalReceipt {
        try Task.checkCancellation()
        try requireAttached(key.connectionGeneration)
        guard let intercept = pendingIntercept else { throw BridgeError.staleApproval }
        guard intercept.approval.requestID == key.requestID else { throw BridgeError.staleApproval }
        guard constantTimeHexEquals(intercept.approval.sha256, key.sha256) else { throw BridgeError.wrongHash }
        isAuthorizationHoldActive = false
        let receipt = try await interlockGate.admitBridgeRequest(
            fence: admission, key: key, timing: timing, beforeAdmission: hooks.beforeApprovalAdmission
        )
        // No cancellation check after acceptance: this receipt records an actual
        // Core transition even if the caller is cancelled before delivery.
        if let accepted = hooks.afterApprovalAdmission { await accepted(receipt) }
        if generation == key.connectionGeneration, pendingIntercept?.approval == key {
            if pendingIntercept?.phase == .awaitingApproval { setPhase(.approved, key: key) }
            emit(.approvalAdmitted(receipt), generation: key.connectionGeneration)
        }
        return receipt
    }

    public func cancel(_ key: BridgeApprovalKey) async throws -> BridgeTransferReceipt {
        if let receipt = recentReceipts[key] { return receipt }
        guard key.connectionGeneration == generation else { throw BridgeError.staleGeneration }
        guard let request = pending[key.requestID], let expected = request.key else { throw BridgeError.staleApproval }
        guard expected.requestID == key.requestID else { throw BridgeError.staleApproval }
        guard constantTimeHexEquals(expected.sha256, key.sha256) else { throw BridgeError.wrongHash }
        isAuthorizationHoldActive = false
        admission.revoke(.request(key), reason: .operatorDeclined)
        // Snapshot the actual write ledger before any suspension or removal.
        let receipt = try makeReceipt(request, outcome: .declined)
        for waiter in writeWaiters where waiter.id == key.requestID {
            waiter.ready.finish(.failure(BridgeError.declined))
        }
        emit(.admissionsRevoked(scope: .request(key), reason: .operatorDeclined), generation: key.connectionGeneration)
        if receipt.transmissionStage != .none {
            beginRetirement(requested: false, error: .revoked(.operatorDeclined, receipt: nil))
        }
        return receipt
    }

    /// Engage Dead-Man's Hold-to-Read on the currently pending intercept, extending its
    /// approval deadline up to `activeHoldPolicy.maxHoldDuration` from request creation.
    /// Immediately preempted if `ESC` (`tripEmergencyAbort()` / `cancel`) or `lock()` is invoked.
    @discardableResult
    public func beginAuthorizationHold(now: ContinuousClock.Instant? = nil) async -> ContinuousClock.Instant? {
        guard connectionState == .attached,
              let gen = generation,
              let intercept = pendingIntercept,
              intercept.phase == .awaitingApproval,
              let request = pending[intercept.approval.requestID],
              request.generation == gen
        else {
            isAuthorizationHoldActive = false
            return nil
        }
        let gateStatus = await interlockGate.currentStatus
        guard gateStatus == .armed else {
            isAuthorizationHoldActive = false
            return nil
        }
        let currentNow = now ?? timing.now()
        guard let currentDeadline = request.deadline, currentNow < currentDeadline else {
            isAuthorizationHoldActive = false
            return nil
        }
        let holdCeiling = request.createdAt.advanced(by: activeHoldPolicy.maxHoldDuration)
        let extendedDeadline = max(currentDeadline, holdCeiling)
        guard admission.updateApprovalDeadline(id: request.id, generation: gen, deadline: extendedDeadline) else {
            isAuthorizationHoldActive = false
            return nil
        }
        isAuthorizationHoldActive = true
        let updated = PendingIntercept(
            approval: intercept.approval,
            toolHook: intercept.toolHook,
            commandPayload: intercept.commandPayload,
            originPID: intercept.originPID,
            originTrust: intercept.originTrust,
            phase: intercept.phase,
            approvalDeadline: extendedDeadline
        )
        pendingIntercept = updated
        armTimer(id: request.id, generation: gen, deadline: extendedDeadline, kind: .approval)
        emit(.interceptChanged(approval: intercept.approval, phase: intercept.phase), generation: gen)
        return extendedDeadline
    }

    /// Release Dead-Man's Hold-to-Read on the currently pending intercept, restoring a bounded
    /// `activeHoldPolicy.initialWindow` countdown (clamped to `maxHoldDuration`).
    @discardableResult
    public func endAuthorizationHold(now: ContinuousClock.Instant? = nil) -> ContinuousClock.Instant? {
        guard isAuthorizationHoldActive else { return nil }
        isAuthorizationHoldActive = false
        guard connectionState == .attached,
              let gen = generation,
              let intercept = pendingIntercept,
              intercept.phase == .awaitingApproval,
              let request = pending[intercept.approval.requestID],
              request.generation == gen
        else {
            return nil
        }
        let currentNow = now ?? timing.now()
        guard let currentDeadline = request.deadline, currentNow < currentDeadline else {
            return nil
        }
        let maxCeiling = request.createdAt.advanced(by: activeHoldPolicy.maxHoldDuration)
        let resumedDeadline = min(maxCeiling, currentNow.advanced(by: activeHoldPolicy.initialWindow))
        guard admission.updateApprovalDeadline(id: request.id, generation: gen, deadline: resumedDeadline) else {
            return nil
        }
        let updated = PendingIntercept(
            approval: intercept.approval,
            toolHook: intercept.toolHook,
            commandPayload: intercept.commandPayload,
            originPID: intercept.originPID,
            originTrust: intercept.originTrust,
            phase: intercept.phase,
            approvalDeadline: resumedDeadline
        )
        pendingIntercept = updated
        armTimer(id: request.id, generation: gen, deadline: resumedDeadline, kind: .approval)
        emit(.interceptChanged(approval: intercept.approval, phase: intercept.phase), generation: gen)
        return resumedDeadline
    }

    public nonisolated func revokeAdmissions(scope: RevocationScope, reason: BridgeRevocationReason) {
        let capturedGeneration = admission.revoke(scope, reason: reason)
        guard let capturedGeneration else { return }
        Task { [weak self] in await self?.recordRevocation(scope: scope, reason: reason, generation: capturedGeneration) }
    }

    private func recordRevocation(scope: RevocationScope, reason: BridgeRevocationReason, generation gen: UUID) {
        guard generation == gen else { return }
        isAuthorizationHoldActive = false
        emit(.admissionsRevoked(scope: scope, reason: reason), generation: gen)
        if case .request(let key) = scope {
            for waiter in writeWaiters where waiter.id == key.requestID {
                waiter.ready.finish(.failure(BridgeError.revoked(reason, receipt: nil)))
            }
        }
        if case .privileged = scope {
            for waiter in writeWaiters where pending[waiter.id]?.key != nil {
                waiter.ready.finish(.failure(BridgeError.revoked(reason, receipt: nil)))
            }
        }
        do { try admission.check(generation: gen) }
        catch { beginRetirement(requested: false, error: .revoked(reason, receipt: nil)) }
    }

    private func requireAttached(_ gen: UUID) throws {
        guard generation == gen else { throw BridgeError.staleGeneration }
        guard connectionState == .attached else { throw BridgeError.detached }
        try admission.check(generation: gen)
    }

    private func performRPC(method: String, params: MCPJSONValue, generation gen: UUID,
                            toolName: String?, overallDeadline: ContinuousClock.Instant?) async throws -> BridgeToolResult {
        let id = UUID()
        let started = timing.nanoseconds()
        let createdAt = timing.now()
        let approvalDeadline = createdAt.advanced(by: activeHoldPolicy.initialWindow)
        let frame = try MCPJSONCodec.frame(id: id, method: method, params: params)
        let key = toolName.map { _ in BridgeAdmissionFence.key(requestID: id, generation: gen, frame: frame) }
        let approved = key.map { _ in BridgeOneShot<BridgeApprovalReceipt>() }
        let response = BridgeOneShot<Data>()
        guard pending.count < BridgeLimits.pendingRequests else { throw BridgeError.busy }
        if key != nil, pendingIntercept != nil { throw BridgeError.busy }
        try admission.register(id: id, generation: gen, frame: frame, key: key,
                               deadline: key == nil ? nil : approvalDeadline, approval: approved, response: response)
        pending[id] = RPC(id: id, generation: gen, frame: frame, key: key, approval: approved, response: response,
                          createdAt: createdAt, startNanoseconds: started,
                          baselineReadBytes: readBytes, baselineReadChunks: readChunks,
                          overallDeadline: overallDeadline)
        if let key, let toolName {
            let intercept = PendingIntercept(approval: key, toolHook: toolName, commandPayload: frame,
                                             originPID: ProcessInfo.processInfo.processIdentifier, originTrust: .appProcess,
                                             phase: .awaitingApproval, approvalDeadline: approvalDeadline)
            pendingIntercept = intercept
            emit(.interceptChanged(approval: key, phase: .awaitingApproval), generation: gen)
        }
        let admission = self.admission
        return try await withTaskCancellationHandler {
            do {
                if let key, let approved {
                    armTimer(id: id, generation: gen, deadline: approvalDeadline, kind: .approval)
                    if let hook = hooks.pendingPublished, let intercept = pendingIntercept { await hook(intercept) }
                    let status = await interlockGate.currentStatus
                    let ownGrant = admission.progress(id: id, generation: gen)?.admittedCursor != nil
                    guard status == .armed || (status == .permissiveGranted && ownGrant) else {
                        throw BridgeError.gateRejected(status == .emergencyAbort ? .emergencyAbortActive : .gateLocked, receipt: nil)
                    }
                    _ = try await approved.value()
                    setPhase(.writing, key: key)
                }
                let leaseWriteDeadline = admission.progress(id: id, generation: gen)?.writeDeadline
                let writeDeadline = overallDeadline ?? leaseWriteDeadline ?? timing.now().advanced(by: .seconds(5))
                armTimer(id: id, generation: gen, deadline: writeDeadline, kind: overallDeadline == nil ? .write : .attach)
                try await acquireWriter(id: id, generation: gen)
                try await writeFrame(id: id, generation: gen, privileged: key != nil, deadline: writeDeadline, started: started)
                releaseWriter(id: id, generation: gen)
                if let key { setPhase(.awaitingResponse, key: key) }
                guard let completedAt = admission.progress(id: id, generation: gen)?.completedAt else {
                    throw BridgeError.protocolViolation(reason: "Missing write completion time", receipt: nil)
                }
                let responseDeadline = overallDeadline ?? completedAt.advanced(by: .seconds(10))
                armTimer(id: id, generation: gen, deadline: responseDeadline, kind: overallDeadline == nil ? .response : .attach)
                let data = try await response.value()
                try Task.checkCancellation()
                guard let object = try MCPJSONCodec.decode(data).object else { throw BridgeError.malformedRequest }
                if let remoteError = object["error"]?.object {
                    guard case .number(let codeRaw)? = remoteError["code"], let code = Int(codeRaw),
                          remoteError["message"]?.string != nil else { throw BridgeError.malformedRequest }
                    let receipt = try await finishRequest(id: id, generation: gen, outcome: .remoteError(code: code))
                    throw BridgeError.remoteError(code: code, message: "Remote JSON-RPC error", receipt: receipt)
                }
                try Self.validateResult(object["result"], method: method)
                if object["result"]?.object?["isError"] == .bool(true) {
                    let receipt = try await finishRequest(id: id, generation: gen, outcome: .toolError)
                    throw BridgeError.toolError(receipt: receipt)
                }
                let receipt = try await finishRequest(id: id, generation: gen, outcome: .responseReceived)
                return BridgeToolResult(rawResponseData: data, receipt: receipt)
            } catch {
                if pending[id] == nil { throw error }
                var typed = Self.bridgeError(error)
                if case .transportFailed = typed, let reason = admission.revocation(id: id, generation: gen), reason != .transportFailure {
                    typed = .revoked(reason, receipt: nil)
                }
                if overallDeadline != nil, case .timedOut = typed { typed = .timedOut(.attach, receipt: nil) }
                var retire = (admission.progress(id: id, generation: gen)?.bytes ?? 0) > 0
                do { try admission.check(generation: gen) } catch { retire = true }
                switch typed {
                case .transportFailed, .protocolViolation, .endOfStream, .processExited, .timedOut: retire = true
                default: break
                }
                if retire {
                    beginRetirement(requested: false, error: typed)
                }
                let receipt = try await finishRequest(id: id, generation: gen, outcome: Self.outcome(typed))
                throw Self.withReceipt(typed, receipt: receipt)
            }
        } onCancel: {
            if let key { admission.revoke(.request(key), reason: .requestCancelled) }
            else { admission.fail(generation: gen, error: .cancelled(receipt: nil)) }
        }
    }

    private func sendInitialized(generation gen: UUID, deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        let started = timing.nanoseconds()
        let frame = try MCPJSONCodec.frame(id: nil, method: "notifications/initialized", params: .object([:]))
        try admission.register(id: id, generation: gen, frame: frame, key: nil, deadline: nil, approval: nil, response: nil)
        do {
            try await acquireWriter(id: id, generation: gen)
            try await writeFrame(id: id, generation: gen, privileged: false, deadline: deadline, started: started)
            releaseWriter(id: id, generation: gen)
            admission.remove(id: id, generation: gen)
        } catch {
            admission.fail(generation: gen, error: Self.bridgeError(error))
            releaseWriter(id: id, generation: gen)
            admission.remove(id: id, generation: gen)
            throw error
        }
    }

    private func acquireWriter(id: UUID, generation gen: UUID) async throws {
        try admission.check(generation: gen)
        if writeOwner == nil {
            try admission.beginWrite(id: id, generation: gen)
            writeOwner = id
            return
        }
        guard writeWaiters.count < BridgeLimits.pendingRequests else { throw BridgeError.busy }
        let ready = BridgeOneShot<Void>()
        writeWaiters.append(WriteWaiter(id: id, generation: gen, ready: ready))
        try await withTaskCancellationHandler {
            try await ready.value()
        } onCancel: {
            ready.finish(.failure(BridgeError.cancelled(receipt: nil)))
        }
        do {
            try admission.check(generation: gen)
        } catch {
            releaseWriter(id: id, generation: gen)
            throw error
        }
    }

    private func releaseWriter(id: UUID, generation gen: UUID) {
        guard generation == gen else { return }
        writeWaiters.removeAll { waiter in
            guard waiter.id == id else { return false }
            waiter.ready.finish(.failure(BridgeError.cancelled(receipt: nil)))
            return true
        }
        guard writeOwner == id else { return }
        admission.finishWrite(id: id, generation: gen)
        writeOwner = nil
        while !writeWaiters.isEmpty {
            let next = writeWaiters.removeFirst()
            do {
                try admission.beginWrite(id: next.id, generation: next.generation)
                writeOwner = next.id
                if next.ready.finish(.success(())) {
                    return
                }
                admission.finishWrite(id: next.id, generation: next.generation)
                writeOwner = nil
            } catch {
                next.ready.finish(.failure(error))
            }
        }
    }

    private func writeFrame(id: UUID, generation gen: UUID, privileged: Bool, deadline: ContinuousClock.Instant,
                            started: UInt64) async throws {
        guard let io = transport, generation == gen else { throw BridgeError.detached }
        var offset = 0
        while true {
            try Task.checkCancellation()
            if let before = hooks.beforeWrite { await before(id, offset) }
            let result: MCPTransportWriteResult
            if privileged {
                result = try await interlockGate.writeBridgeChunk(fence: admission, id: id, generation: gen,
                                                                  offset: offset, timing: timing, deadline: deadline)
            } else {
                result = try admission.writeMetadata(id: id, generation: gen, offset: offset,
                                                      now: timing.now(), deadline: deadline, clock: timing.now)
            }
            switch result {
            case .wouldBlock:
                try await io.writer.waitUntilWritable(deadline: deadline)
            case .written(let count):
                offset += count
                emit(.chunkWritten(requestID: id, bytes: count, totalWritten: offset,
                                   elapsedNanoseconds: elapsed(since: started)), generation: gen)
                if let after = hooks.afterWrite { await after(id, offset) }
                guard let progress = admission.progress(id: id, generation: gen) else { throw BridgeError.staleGeneration }
                if progress.stage == .complete { return }
            }
        }
    }

    private func armTimer(id: UUID, generation gen: UUID, deadline: ContinuousClock.Instant, kind: BridgeDeadlineKind) {
        pending[id]?.timer?.cancel()
        guard pending[id]?.correlated != true else {
            pending[id]?.timerID = nil
            pending[id]?.timer = nil
            return
        }
        let timerID = UUID()
        pending[id]?.timerID = timerID
        pending[id]?.deadline = deadline
        pending[id]?.deadlineKind = kind
        let clock = timing
        pending[id]?.timer = Task { [weak self] in
            do { try await clock.sleep(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.requestExpired(id: id, generation: gen, timerID: timerID, kind: kind)
        }
    }

    private func requestExpired(id: UUID, generation gen: UUID, timerID: UUID, kind: BridgeDeadlineKind) {
        guard let request = pending[id], request.generation == gen, request.timerID == timerID else { return }
        if let deadline = request.deadline, timing.now() < deadline {
            armTimer(id: id, generation: gen, deadline: deadline, kind: kind)
            return
        }
        if kind == .approval, let writeDeadline = admission.progress(id: id, generation: gen)?.writeDeadline {
            armTimer(id: id, generation: gen, deadline: writeDeadline, kind: .write)
            return
        }
        if kind == .write, let completedAt = admission.progress(id: id, generation: gen)?.completedAt {
            armTimer(id: id, generation: gen, deadline: completedAt.advanced(by: .seconds(10)), kind: .response)
            return
        }
        let error: BridgeError = kind == .approval ? .expired : .timedOut(kind, receipt: nil)
        if kind == .approval { isAuthorizationHoldActive = false }
        request.approval?.finish(.failure(error))
        request.response.finish(.failure(error))
        for waiter in writeWaiters where waiter.id == id { waiter.ready.finish(.failure(error)) }
        if let key = request.key { admission.revoke(.request(key), reason: .approvalExpired) }
        if (admission.progress(id: id, generation: gen)?.bytes ?? 0) > 0 || kind != .approval {
            connectionFailed(generation: gen, error: error)
        }
    }

    private func receive(_ output: MCPTransportOutput, generation gen: UUID) {
        guard generation == gen, retirement == nil else { return }
        do {
            switch output {
            case .stdout(let data):
                readBytes += data.count
                readChunks += 1
                for id in pending.keys {
                    if let request = pending[id] {
                        pending[id]?.readBytes = readBytes - request.baselineReadBytes
                        pending[id]?.readChunks = readChunks - request.baselineReadChunks
                    }
                }
                for line in try framer.append(data) { try receiveLine(line, generation: gen) }
            case .stderr(let data):
                // Drain, count, and discard; never retain/log untrusted stderr or secrets.
                stderrBytes = min(BridgeLimits.stderrBytes, stderrBytes + data.count)
            case .stdoutEOF:
                throw BridgeError.endOfStream(receipt: nil)
            case .exited(let status):
                observedExitStatus = status
                // Exit may precede trailing stdout. Wait for stdout EOF/stream end.
                break
            }
        } catch {
            let typed = Self.bridgeError(error)
            switch typed {
            case .malformedRequest, .limitExceeded:
                connectionFailed(generation: gen, error: .protocolViolation(reason: "Malformed or oversized server message", receipt: nil))
            default: connectionFailed(generation: gen, error: typed)
            }
        }
    }

    private func receiveLine(_ line: Data, generation gen: UUID) throws {
        guard let object = try MCPJSONCodec.decode(line).object, object["jsonrpc"] == .string("2.0") else {
            throw BridgeError.protocolViolation(reason: "Invalid JSON-RPC envelope", receipt: nil)
        }
        if let method = object["method"]?.string {
            guard object["id"] == nil, object["result"] == nil, object["error"] == nil,
                  Set(object.keys).isSubset(of: ["jsonrpc", "method", "params"]),
                  ["notifications/message", "notifications/progress", "notifications/tools/list_changed",
                   "notifications/resources/list_changed", "notifications/prompts/list_changed"].contains(method),
                  object["params"] == nil || object["params"]?.object != nil else {
                throw BridgeError.protocolViolation(reason: "Unsupported server request or notification", receipt: nil)
            }
            return
        }
        guard Set(object.keys).isSubset(of: ["jsonrpc", "id", "result", "error"]),
              let idValue = object["id"], case .string(let rawID) = try MCPRequestID(idValue),
              let id = UUID(uuidString: rawID), rawID == id.uuidString,
              var request = pending[id], request.generation == gen,
              !request.correlated, (object["result"] != nil) != (object["error"] != nil) else {
            throw BridgeError.protocolViolation(reason: "Unowned, duplicate, or malformed response", receipt: nil)
        }
        if let error = object["error"] {
            guard let fields = error.object, case .number(let code)? = fields["code"], Int(code) != nil,
                  fields["message"]?.string != nil else { throw BridgeError.malformedRequest }
        }
        guard let progress = admission.progress(id: id, generation: gen), progress.stage == .complete else {
            throw BridgeError.protocolViolation(reason: "Response before complete request transmission", receipt: nil)
        }
        request.correlated = true
        pending[id] = request
        let deadline: ContinuousClock.Instant?
        let kind: BridgeDeadlineKind
        if let overall = request.overallDeadline {
            deadline = overall
            kind = .attach
        } else if let completedAt = progress.completedAt {
            deadline = completedAt.advanced(by: .seconds(10))
            kind = .response
        } else {
            deadline = request.deadline
            kind = request.deadlineKind ?? .response
        }
        if let deadline, timing.now() >= deadline { throw BridgeError.timedOut(kind, receipt: nil) }
        pending[id]?.timer?.cancel()
        pending[id]?.timerID = nil
        pending[id]?.timer = nil
        request.response.finish(.success(line))
    }

    private func outputEnded(generation gen: UUID) {
        guard generation == gen, retirement == nil else { return }
        connectionFailed(generation: gen, error: .endOfStream(receipt: nil))
    }

    private func connectionFailed(generation gen: UUID, error: BridgeError) {
        guard generation == gen else { return }
        admission.fail(generation: gen, error: error)
        emit(.failure(error), generation: gen)
        beginRetirement(requested: false, error: error)
    }

    private func finishRequest(id: UUID, generation gen: UUID, outcome: BridgeTransferOutcome) async throws -> BridgeTransferReceipt {
        guard let request = pending[id], request.generation == gen else { throw BridgeError.staleApproval }
        request.timer?.cancel()
        pending[id]?.timerID = nil
        pending[id]?.timer = nil
        releaseWriter(id: id, generation: gen)
        if request.key != nil {
            // Do not lock a later Core grant or reset an abort during cleanup.
            try await admission.relockAbandoned(on: interlockGate, id: id, generation: gen)
        }
        guard let latest = pending[id] else { throw BridgeError.staleApproval }
        let receipt = try makeReceipt(latest, outcome: outcome)
        pending.removeValue(forKey: id)
        admission.remove(id: id, generation: gen)
        latestTransfer = receipt
        if let key = request.key {
            recentReceipts[key] = receipt
            recentKeys.append(key)
            if recentKeys.count > BridgeLimits.eventRetention {
                recentReceipts.removeValue(forKey: recentKeys.removeFirst())
            }
            if pendingIntercept?.approval == key {
                isAuthorizationHoldActive = false
                pendingIntercept = nil
                emit(.interceptCleared(approval: key), generation: gen)
            }
        }
        emit(.transferFinished(receipt), generation: gen)
        finishRetirementIfReady()
        return receipt
    }

    private func makeReceipt(_ request: RPC, outcome: BridgeTransferOutcome) throws -> BridgeTransferReceipt {
        guard let progress = admission.progress(id: request.id, generation: request.generation) else {
            throw BridgeError.protocolViolation(reason: "Missing authoritative transfer ledger", receipt: nil)
        }
        return BridgeTransferReceipt(requestID: request.id, connectionGeneration: request.generation,
                                     approval: request.key, bytesWritten: progress.bytes, writeChunks: progress.chunks,
                                     bytesRead: request.readBytes, readChunks: request.readChunks,
                                     elapsedNanoseconds: elapsed(since: request.startNanoseconds),
                                     transmissionStage: progress.stage, hasCorrelatedResponse: request.correlated, outcome: outcome)
    }

    private func setPhase(_ phase: BridgeInterceptPhase, key: BridgeApprovalKey) {
        guard let old = pendingIntercept, old.approval == key else { return }
        pendingIntercept = PendingIntercept(approval: key, toolHook: old.toolHook, commandPayload: old.commandPayload,
                                             originPID: old.originPID, originTrust: old.originTrust,
                                             phase: phase, approvalDeadline: old.approvalDeadline)
        emit(.interceptChanged(approval: key, phase: phase), generation: key.connectionGeneration)
    }

    private func beginRetirement(requested: Bool, error: BridgeError) {
        let started = timing.nanoseconds()
        let deadline = timing.now().advanced(by: .seconds(2))
        guard let gen = generation, let io = transport else {
            if requested { connectionState = .detached }
            return
        }
        if retirement != nil {
            if requested { retirement?.requested = true }
            return
        }
        admission.fail(generation: gen, error: error)
        attachCompletion?.finish(.failure(error))
        attachTimer?.cancel()
        attachWorker?.cancel()
        readerTask?.cancel()
        for waiter in writeWaiters { waiter.ready.finish(.failure(error)) }
        writeWaiters.removeAll()
        connectionState = requested ? .detaching : .failed
        emit(.connectionChanged(connectionState), generation: gen)
        let completion = BridgeSharedCompletion<BridgeDetachReceipt>()
        let retirementID = UUID()
        retirement = Retirement(id: retirementID, generation: gen, completion: completion, started: started, deadline: deadline,
                                processIdentifier: localProcessIdentifier, requested: requested, settledCount: pending.count)
        let clock = timing
        let timerHook = hooks.beforeRetirementTimerClaim
        stopTimer = Task { [weak self] in
            do { try await clock.sleep(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            if let timerHook { await timerHook(gen) }
            await self?.retirementTimedOut(generation: gen, id: retirementID)
        }
        let completionHook = hooks.beforeRetirementCompletion
        stopWorker = Task { [weak self, io] in
            let succeeded: Bool
            do {
                try await io.stop()
                succeeded = true
            } catch { succeeded = false }
            // Internal deterministic seam, outside I/O and all admission locks.
            if let completionHook { await completionHook(gen, succeeded) }
            await self?.stopFinished(generation: gen, succeeded: succeeded)
        }
    }

    private func stopFinished(generation gen: UUID, succeeded: Bool) {
        guard retirement?.generation == gen else { return }
        retirement?.stopSucceeded = succeeded
        stopWorker = nil
        if succeeded { finishRetirementIfReady() }
        else {
            emit(.failure(.transportFailed(reason: "Local process cleanup incomplete", receipt: nil)), generation: gen)
            if let retiring = retirement, let receipt = claimRetirementResult(retiring, complete: false) {
                emit(.detached(receipt), generation: gen)
            }
            // Retain the transport/fence; no replacement may inherit its work.
            retirement = nil
            stopTimer?.cancel()
            stopTimer = nil
        }
    }

    private func retirementTimedOut(generation gen: UUID, id: UUID? = nil) {
        guard let retiring = retirement, retiring.generation == gen, id == nil || retiring.id == id else { return }
        guard timing.now() >= retiring.deadline else { return }
        if let receipt = claimRetirementResult(retiring, complete: false) { emit(.detached(receipt), generation: gen) }
    }

    private func finishRetirementIfReady() {
        guard let retiring = retirement, retiring.stopSucceeded == true, pending.isEmpty, attachWorker == nil else { return }
        let first = claimRetirementResult(retiring, complete: true)
        if let first, first.outcome == .cleanupIncomplete {
            // The caller's deadline result is immutable. Eventual local closure is
            // a separate fact below, not a retroactive successful budget claim.
            emit(.detached(first), generation: retiring.generation)
        }
        let receipt = first?.outcome == .detached ? first : nil
        let closureReceipt = receipt ?? detachReceipt(retiring, complete: true)
        admission.clear(generation: retiring.generation)
        transport = nil
        generation = nil
        localProcessIdentifier = nil
        readerTask = nil
        writeOwner = nil
        serverInfo = nil
        attachGateCursor = nil
        serverAdvertisesTools = false
        isAuthorizationHoldActive = false
        pendingIntercept = nil
        framer = MCPLineFramer()
        connectionState = retiring.requested ? .detached : .failed
        retirement = nil
        stopTimer?.cancel()
        stopTimer = nil
        emit(.detached(closureReceipt), generation: retiring.generation)
        emit(.connectionChanged(connectionState), generation: retiring.generation)
    }

    private func detachReceipt(_ retiring: Retirement, complete: Bool) -> BridgeDetachReceipt {
        let remaining = pending.values.filter { $0.generation == retiring.generation }.count
        return BridgeDetachReceipt(generation: retiring.generation, localProcessIdentifier: retiring.processIdentifier,
                                   terminationRequested: true, observedExitStatus: observedExitStatus,
                                   handlesClosed: complete, settledRequestCount: max(0, retiring.settledCount - remaining),
                                   elapsedNanoseconds: elapsed(since: retiring.started), outcome: complete ? .detached : .cleanupIncomplete)
    }

    /// The monotonic deadline is checked under the result's completion lock at
    /// its first claim, independently of when the scheduled timer gets CPU time.
    private func claimRetirementResult(_ retiring: Retirement, complete: Bool) -> BridgeDetachReceipt? {
        let basis = detachReceipt(retiring, complete: complete)
        let clock = timing
        let claimed = retiring.completion.resolve {
            let now = clock.nanoseconds()
            let elapsed = now >= retiring.started ? now - retiring.started : 0
            let outcome: BridgeDetachOutcome = complete && clock.now() < retiring.deadline ? .detached : .cleanupIncomplete
            return .success(BridgeDetachReceipt(
                generation: basis.generation, localProcessIdentifier: basis.localProcessIdentifier,
                terminationRequested: basis.terminationRequested, observedExitStatus: basis.observedExitStatus,
                handlesClosed: basis.handlesClosed, settledRequestCount: basis.settledRequestCount,
                elapsedNanoseconds: elapsed, outcome: outcome
            ))
        }
        if case .success(let receipt)? = claimed { return receipt }
        return nil
    }

    private func emit(_ kind: BridgeEventKind, generation gen: UUID?) {
        cursor += 1
        let event = BridgeEvent(cursor: cursor, generation: gen, monotonicTimeNanoseconds: timing.nanoseconds(), kind: kind)
        history.append(event)
        if history.count > BridgeLimits.eventRetention { history.removeFirst(history.count - BridgeLimits.eventRetention) }
        var terminated: [UUID] = []
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(event) { terminated.append(id) }
        }
        for id in terminated { subscribers.removeValue(forKey: id) }
    }

    private func elapsed(since start: UInt64) -> UInt64 {
        let now = timing.nanoseconds()
        return now >= start ? now - start : 0
    }

    private static func bridgeError(_ error: any Error) -> BridgeError {
        if let error = error as? BridgeError { return error }
        if error is CancellationError { return .cancelled(receipt: nil) }
        if let error = error as? HardwareInterlockError { return .gateRejected(error, receipt: nil) }
        if let error = error as? MCPTransportError, error == .deadlineExceeded { return .timedOut(.write, receipt: nil) }
        return .transportFailed(reason: "Local stdio transport failed", receipt: nil)
    }

    private static func validateResult(_ value: MCPJSONValue?, method: String) throws {
        guard let result = value?.object else {
            throw BridgeError.protocolViolation(reason: "MCP result must be an object", receipt: nil)
        }
        switch method {
        case "tools/call":
            guard result["content"]?.array != nil,
                  result["isError"] == nil || result["isError"] == .bool(true) || result["isError"] == .bool(false) else {
                throw BridgeError.protocolViolation(reason: "Invalid tool result", receipt: nil)
            }
        case "tools/list":
            guard let tools = result["tools"]?.array else {
                throw BridgeError.protocolViolation(reason: "Invalid tool catalog", receipt: nil)
            }
            for tool in tools {
                guard let fields = tool.object, let name = fields["name"]?.string,
                      !name.isEmpty, name.utf8.count <= BridgeLimits.toolNameBytes,
                      fields["inputSchema"]?.object != nil else {
                    throw BridgeError.protocolViolation(reason: "Invalid tool catalog entry", receipt: nil)
                }
            }
            if let cursor = result["nextCursor"] {
                guard let string = cursor.string, string.utf8.count <= BridgeLimits.cursorBytes else {
                    throw BridgeError.protocolViolation(reason: "Invalid tool catalog cursor", receipt: nil)
                }
            }
        default: break
        }
    }

    private static func outcome(_ error: BridgeError) -> BridgeTransferOutcome {
        switch error {
        case .busy: .rejected(.busy)
        case .detached: .rejected(.detached)
        case .staleGeneration: .rejected(.staleGeneration)
        case .staleApproval: .rejected(.staleApproval)
        case .wrongHash: .rejected(.wrongHash)
        case .expired: .rejected(.expired)
        case .declined: .declined
        case .unsupportedMethod: .rejected(.unsupportedMethod)
        case .malformedRequest: .rejected(.malformedRequest)
        case .limitExceeded(let kind): .rejected(.limitExceeded(kind))
        case .gateRejected(let gate, _): .rejected(gate == .emergencyAbortActive ? .gateAborted : .gateNotArmed)
        case .cancelled: .cancelled
        case .revoked(let reason, _): .revoked(reason)
        case .timedOut(let kind, _): .timedOut(kind)
        case .endOfStream: .endOfStream
        case .processExited(let status, _): .processExited(status: status)
        case .transportFailed: .transportFailed
        case .protocolViolation: .protocolViolation
        case .remoteError(let code, _, _): .remoteError(code: code)
        case .toolError: .toolError
        }
    }

    private static func withReceipt(_ error: BridgeError, receipt: BridgeTransferReceipt) -> BridgeError {
        switch error {
        case .expired: .timedOut(.approval, receipt: receipt)
        case .gateRejected(let gate, _): .gateRejected(gate, receipt: receipt)
        case .cancelled: .cancelled(receipt: receipt)
        case .revoked(let reason, _): .revoked(reason, receipt: receipt)
        case .timedOut(let kind, _): .timedOut(kind, receipt: receipt)
        case .endOfStream: .endOfStream(receipt: receipt)
        case .processExited(let status, _): .processExited(status: status, receipt: receipt)
        case .transportFailed(let reason, _): .transportFailed(reason: reason, receipt: receipt)
        case .protocolViolation(let reason, _): .protocolViolation(reason: reason, receipt: receipt)
        default: error
        }
    }
}

private extension HardwareInterlockGate {
    func admitBridgeRequest(fence: BridgeAdmissionFence, key: BridgeApprovalKey, timing: BridgeTiming,
                            beforeAdmission: (@Sendable (BridgeApprovalKey) async -> Void)?) async throws -> BridgeApprovalReceipt {
        if let beforeAdmission { await beforeAdmission(key) }
        return try fence.approve(on: self, key: key, now: timing.now(), nanoseconds: timing.nanoseconds(),
                                clock: timing.now, counter: timing.nanoseconds)
    }

    func writeBridgeChunk(fence: BridgeAdmissionFence, id: UUID, generation: UUID, offset: Int,
                          timing: BridgeTiming, deadline: ContinuousClock.Instant) throws -> MCPTransportWriteResult {
        try fence.writePrivileged(on: self, id: id, generation: generation, offset: offset,
                                  now: timing.now(), deadline: deadline, clock: timing.now)
    }
}
