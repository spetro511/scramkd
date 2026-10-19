import Combine
import Foundation
import os
import TacticalCore
import TacticalVirtualization

public enum ConsoleCommand: Sendable, Equatable {
    case grantPermissive
    case emergencyAbort
    case forceAirgapDump
    case armGate
    case resetEmergencyAbort

    fileprivate var label: String {
        switch self {
        case .grantPermissive: "GRANT"
        case .emergencyAbort: "ABORT"
        case .forceAirgapDump: "F12"
        case .armGate: "ARM"
        case .resetEmergencyAbort: "RESET"
        }
    }
}

public enum ConsoleStateControllerError: Error, Sendable, Equatable {
    case notObserving
    case notImplemented
    case cancelled
    case expiredGeneration
    case bridgeNotConfigured
    case noPendingIntercept
}

/// Capture synchronously at button press, before scheduling asynchronous UI work.
/// There is no public initializer or writable generation; requests cannot adopt a
/// later observation session, including a session on another controller.
public struct ConsoleCommandRequest: Identifiable, Sendable {
    public let id: UUID
    public let command: ConsoleCommand
    fileprivate let generation: UUID?
    fileprivate let bridgeApproval: BridgeApprovalKey?
    fileprivate let bridgePhase: BridgeInterceptPhase?

    fileprivate init(
        command: ConsoleCommand, generation: UUID?, bridgeApproval: BridgeApprovalKey? = nil,
        bridgePhase: BridgeInterceptPhase? = nil
    ) {
        self.id = UUID()
        self.command = command
        self.generation = generation
        self.bridgeApproval = bridgeApproval
        self.bridgePhase = bridgePhase
    }
}

/// Synchronous revocation races stop/cancellation against gate-actor admission.
/// The lock covers only an existing nonsuspending gate operation, never await;
/// gate state remains exclusively actor-owned. Revocation never rolls back an
/// operation that already won admission and completed its mutation.
private final class ConsoleCommandAdmission: Sendable {
    private let revocation = OSAllocatedUnfairLock<ConsoleStateControllerError?>(initialState: nil)

    func revoke(_ reason: ConsoleStateControllerError) {
        revocation.withLock { if $0 == nil { $0 = reason } }
    }

    func check() throws {
        try revocation.withLock { reason in if let reason { throw reason } }
    }

    func withAdmission<T>(
        on gate: isolated HardwareInterlockGate,
        _ body: (isolated HardwareInterlockGate) throws -> T
    ) throws -> T {
        // This nonescaping callback executes synchronously on the supplied gate
        // actor. withLockUnchecked relaxes callback Sendable checking only; it
        // preserves locking and does not move isolated work to another executor.
        try revocation.withLockUnchecked { reason in
            if let reason { throw reason }
            return try body(gate)
        }
    }
}

private struct ConsoleGateCommandReceipt: Sendable {
    let didTransition: Bool
}

private extension HardwareInterlockGate {
    /// Dispatch existing gate APIs and measure their effect in one nonsuspending
    /// actor turn. A separate preflight read could misidentify a raced no-op.
    func executeConsoleCommand(
        _ command: ConsoleCommand,
        abortReason: String,
        admission: ConsoleCommandAdmission,
        beforeAdmission: (@Sendable (ConsoleCommand) async -> Void)?
    ) async throws -> ConsoleGateCommandReceipt {
        // Internal test barrier only; production has no suspension within admission.
        if let beforeAdmission { await beforeAdmission(command) }
        return try admission.withAdmission(on: self) { gate in
            let before = gate.observationSnapshot(historyLimit: 0).cursor
            // Admission linearizes here under the revocation lock. Cancellation
            // after this check may not rewrite an already accepted gate effect.
            try Task.checkCancellation()
            switch command {
            case .grantPermissive:
                try gate.grantPermissive()
            case .emergencyAbort:
                gate.tripEmergencyAbort(reason: abortReason)
            case .armGate:
                try gate.arm()
            case .resetEmergencyAbort:
                try gate.resetEmergencyAbort()
            case .forceAirgapDump:
                throw ConsoleStateControllerError.notImplemented
            }
            return ConsoleGateCommandReceipt(
                didTransition: gate.observationSnapshot(historyLimit: 0).cursor != before
            )
        }
    }
}

private struct ConsolePendingCommand: Sendable {
    let admission: ConsoleCommandAdmission
    let bridgeApproval: BridgeApprovalKey?
    let task: Task<Result<ConsoleCommandEffect, any Error>, Never>
}

private enum ConsoleCommandEffect: Sendable {
    case core(didTransition: Bool)
    case bridgeApproval(BridgeApprovalReceipt)
}

private struct ConsoleBootstrap: Sendable {
    let core: InterlockObservation
    let bridge: BridgeObservation?
}

private struct ConsoleBridgeOperation: Sendable {
    let cancel: @Sendable () -> Void
    let settle: @Sendable () async -> Void
}

private struct ConsoleBridgeRetirementResult: Sendable {
    let receipt: BridgeDetachReceipt
    let snapshot: BridgeSnapshot
}

private struct ConsoleBridgeRetirement: Sendable {
    let id: UUID
    let task: Task<ConsoleBridgeRetirementResult, Never>
}

public struct AuditLogRow: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: String
    public let subsystem: String
    public let tagColor: String
    public let description: String
    public let metric: String
    public let isEmergency: Bool

    public init(
        id: UUID = UUID(),
        timestamp: String,
        subsystem: String,
        tagColor: String,
        description: String,
        metric: String,
        isEmergency: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.tagColor = tagColor
        self.description = description
        self.metric = metric
        self.isEmergency = isEmergency
    }
}

/// App-owned bridge presentation. External direct Docker clients are outside this boundary.
@MainActor
public final class ConsoleStateController: ObservableObject {
    /// Includes the persistent truncation marker when older presentation rows are removed.
    public static let auditRowLimit = 256

    @Published public private(set) var currentStatus: InterlockStatus = .locked
    // Core TTL remains UNBOUND. The bridge's approval budget is a separate
    // backend deadline, not a Core lease or a UI enforcement timer.
    @Published public private(set) var countdownTTL: String = "UNBOUND"
    @Published public private(set) var auditRows: [AuditLogRow] = []
    @Published public private(set) var isObserving: Bool = false
    @Published public private(set) var lastCommandResult: String = "UNBOUND"
    @Published public var activeBay: String = "BAY-01"
    @Published public private(set) var bridgeSnapshot: BridgeSnapshot?

    public var bridgeConnectionState: BridgeConnectionState { bridgeSnapshot?.connectionState ?? .detached }
    public var pendingIntercept: PendingIntercept? { bridgeSnapshot?.pendingIntercept }
    public var serverInfo: ServerInfo? { bridgeSnapshot?.serverInfo }
    public var latestBridgeTransfer: BridgeTransferReceipt? { bridgeSnapshot?.latestTransfer }
    public var isBridgeConfigured: Bool { bridge != nil }

    private let interlockGate: HardwareInterlockGate
    private let bridge: ContainerSocketBridge?
    private var sessionID: UUID?
    private var subscriptionID: UUID?
    private var bootstrapTask: Task<ConsoleBootstrap, Never>?
    private var observationTask: Task<Void, Never>?
    private var bridgeObservationTask: Task<Void, Never>?
    private var bridgeSubscriptionID: UUID?
    private var bridgeRetirement: ConsoleBridgeRetirement?
    private var bridgeOperations: [UUID: ConsoleBridgeOperation] = [:]
    private var lastBridgeCursor: UInt64 = 0
    private var omittedBridgeEvents: UInt64 = 0
    var pendingBridgeOperationCount: Int { bridgeOperations.count }
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var lastCursor: UInt64 = 0
    private var latestCommandID: UUID?
    private var pendingCommands: [UUID: ConsolePendingCommand] = [:]
    var pendingCommandCount: Int { pendingCommands.count }
    private var discardedAuditRows: UInt64 = 0
    private var omittedAuditTransitions: UInt64 = 0
    private let truncationRowID = UUID()
    // Internal deterministic completion seam. Production has no barrier or command queue.
    private let commandCompletionBarrier: (@MainActor @Sendable (ConsoleCommand) async -> Void)?
    private let observationDeliveryBarrier: (@MainActor @Sendable () async -> Void)?
    private let bootstrapDeliveryBarrier: (@MainActor @Sendable (InterlockObservationSnapshot) async -> Void)?
    private let commandAdmissionBarrier: (@Sendable (ConsoleCommand) async -> Void)?
    private let bridgeBootstrapDeliveryBarrier: (@MainActor @Sendable (BridgeSnapshot) async -> Void)?
    private let bridgeObservationDeliveryBarrier: (@MainActor @Sendable () async -> Void)?
    private let bridgeAttachBarrier: (@Sendable () async -> Void)?

    public init(interlockGate: HardwareInterlockGate, bridge: ContainerSocketBridge? = nil) {
        self.interlockGate = interlockGate
        self.bridge = bridge
        self.bridgeSnapshot = nil
        self.commandCompletionBarrier = nil
        self.observationDeliveryBarrier = nil
        self.bootstrapDeliveryBarrier = nil
        self.commandAdmissionBarrier = nil
        self.bridgeBootstrapDeliveryBarrier = nil
        self.bridgeObservationDeliveryBarrier = nil
        self.bridgeAttachBarrier = nil
    }

    init(
        interlockGate: HardwareInterlockGate,
        bridge: ContainerSocketBridge? = nil,
        observationDeliveryBarrier: (@MainActor @Sendable () async -> Void)?,
        bootstrapDeliveryBarrier: (@MainActor @Sendable (InterlockObservationSnapshot) async -> Void)? = nil,
        commandAdmissionBarrier: (@Sendable (ConsoleCommand) async -> Void)? = nil,
        bridgeBootstrapDeliveryBarrier: (@MainActor @Sendable (BridgeSnapshot) async -> Void)? = nil,
        bridgeObservationDeliveryBarrier: (@MainActor @Sendable () async -> Void)? = nil,
        bridgeAttachBarrier: (@Sendable () async -> Void)? = nil,
        commandCompletionBarrier: (@MainActor @Sendable (ConsoleCommand) async -> Void)? = nil
    ) {
        self.interlockGate = interlockGate
        self.bridge = bridge
        self.bridgeSnapshot = nil
        self.commandCompletionBarrier = commandCompletionBarrier
        self.observationDeliveryBarrier = observationDeliveryBarrier
        self.bootstrapDeliveryBarrier = bootstrapDeliveryBarrier
        self.commandAdmissionBarrier = commandAdmissionBarrier
        self.bridgeBootstrapDeliveryBarrier = bridgeBootstrapDeliveryBarrier
        self.bridgeObservationDeliveryBarrier = bridgeObservationDeliveryBarrier
        self.bridgeAttachBarrier = bridgeAttachBarrier
    }

    deinit {
        bridge?.revokeAdmissions(scope: .currentConnection, reason: .windowClosed)
        bootstrapTask?.cancel()
        observationTask?.cancel()
        bridgeObservationTask?.cancel()
        for operation in bridgeOperations.values { operation.cancel() }
        for command in pendingCommands.values {
            command.admission.revoke(.expiredGeneration)
            command.task.cancel()
        }
    }

    /// Idempotent atomic bootstrap. Initialization itself owns no background work.
    public func start() async {
        if isObserving, let sessionID {
            await reconcile(session: sessionID)
            await reconcileBridge(session: sessionID)
            return
        }

        let session: UUID
        let bootstrap: Task<ConsoleBootstrap, Never>
        if let existingSession = sessionID, let existingBootstrap = bootstrapTask {
            session = existingSession
            bootstrap = existingBootstrap
        } else {
            session = UUID()
            sessionID = session
            let gate = interlockGate
            let cursor = lastCursor
            let bootstrapBarrier = bootstrapDeliveryBarrier
            let bridge = self.bridge
            let bridgeCursor = lastBridgeCursor
            let bridgeBarrier = bridgeBootstrapDeliveryBarrier
            bootstrap = Task {
                let observation = await gate.observeTransitions(after: cursor, historyLimit: Self.auditRowLimit)
                if let bootstrapBarrier { await bootstrapBarrier(observation.snapshot) }
                let bridgeObservation: BridgeObservation?
                if let bridge {
                    let source = await bridge.observe(after: bridgeCursor)
                    if let bridgeBarrier { await bridgeBarrier(source.snapshot) }
                    bridgeObservation = source
                } else {
                    bridgeObservation = nil
                }
                return ConsoleBootstrap(core: observation, bridge: bridgeObservation)
            }
            bootstrapTask = bootstrap
        }

        let observation = await bootstrap.value
        guard sessionID == session else {
            await interlockGate.unsubscribeObservation(id: observation.core.id)
            if let source = observation.bridge, let bridge { await bridge.unsubscribe(id: source.id) }
            return
        }
        guard !isObserving else { return }
        bootstrapTask = nil
        subscriptionID = observation.core.id
        apply(observation.core.snapshot)
        if let source = observation.bridge { applyBridgeSnapshot(source.snapshot) }
        isObserving = true
        let gate = interlockGate
        let deliveryBarrier = observationDeliveryBarrier
        observationTask = Task { [weak self] in
            for await transition in observation.core.transitions {
                guard !Task.isCancelled else { break }
                if let deliveryBarrier { await deliveryBarrier() }
                guard !Task.isCancelled else { break }
                // The optional reference is held only for this delivery, never across next().
                await self?.receive(transition, session: session)
            }
            await gate.unsubscribeObservation(id: observation.core.id)
            self?.observationEnded(session: session)
        }
        if let source = observation.bridge, let bridge {
            bridgeSubscriptionID = source.id
            let barrier = bridgeObservationDeliveryBarrier
            bridgeObservationTask = Task { [weak self] in
                for await event in source.events {
                    guard !Task.isCancelled else { break }
                    if let barrier { await barrier() }
                    guard !Task.isCancelled else { break }
                    await self?.receiveBridge(event, session: session)
                }
                await bridge.unsubscribe(id: source.id)
            }
        }
    }

    /// Invalidates callbacks before awaiting cleanup. Gate safety remains independent.
    public func stop() async {
        // Revokes the actual installed/attaching connection, not a possibly stale UI snapshot.
        let retirement = beginBridgeRetirement(reason: .windowClosed)
        if !isBridgeConfigured, sessionID == nil, bootstrapTask == nil, observationTask == nil, pendingCommands.isEmpty {
            await cleanupTask?.value
            return
        }
        sessionID = nil
        latestCommandID = nil
        let oldCommands = Array(pendingCommands.values)
        pendingCommands.removeAll()
        for command in oldCommands {
            command.admission.revoke(.expiredGeneration)
            command.task.cancel()
        }
        isObserving = false
        let pendingBootstrap = bootstrapTask
        bootstrapTask = nil
        pendingBootstrap?.cancel()
        let oldTask = observationTask
        observationTask = nil
        oldTask?.cancel()
        let oldSubscription = subscriptionID
        subscriptionID = nil
        let oldBridgeTask = bridgeObservationTask
        bridgeObservationTask = nil
        oldBridgeTask?.cancel()
        let oldBridgeSubscription = bridgeSubscriptionID
        bridgeSubscriptionID = nil
        let previousCleanup = cleanupTask
        let gate = interlockGate
        let bridge = self.bridge
        let cleanup = Task<Void, Never> { [weak self] in
            await previousCleanup?.value
            if let oldSubscription {
                await gate.unsubscribeObservation(id: oldSubscription)
            }
            if let pendingBootstrap {
                let observation = await pendingBootstrap.value
                await gate.unsubscribeObservation(id: observation.core.id)
                if let source = observation.bridge, let bridge { await bridge.unsubscribe(id: source.id) }
            }
            if let oldBridgeSubscription, let bridge { await bridge.unsubscribe(id: oldBridgeSubscription) }
            await oldTask?.value
            await oldBridgeTask?.value
            for command in oldCommands { _ = await command.task.value }
            if let retirement {
                let result = await retirement.task.value
                self?.finishBridgeRetirement(retirement, result: result, session: nil)
            }
        }
        let id = UUID()
        cleanupID = id
        cleanupTask = cleanup
        await cleanup.value
        if cleanupID == id {
            cleanupID = nil
            cleanupTask = nil
            if sessionID == nil, let bridge {
                let snapshot = await bridge.snapshot(after: lastBridgeCursor)
                if sessionID == nil { applyBridgeSnapshot(snapshot) }
            }
        }
    }

    /// Buttons and key routing use the same path. No UI queue can hold abort behind grant.
    public func perform(_ command: ConsoleCommand) async {
        // The shared executor publishes both accepted and rejected outcomes once.
        _ = await execute(command)
    }

    public func commandRequest(_ command: ConsoleCommand) -> ConsoleCommandRequest {
        let approval = command == .grantPermissive && pendingIntercept?.phase == .awaitingApproval
            ? pendingIntercept?.approval : nil
        return ConsoleCommandRequest(
            command: command, generation: isObserving ? sessionID : nil,
            bridgeApproval: approval, bridgePhase: pendingIntercept?.phase
        )
    }

    public func perform(_ request: ConsoleCommandRequest) async {
        _ = await execute(request)
    }

    public func grantPermissive() async throws {
        let result = await execute(.grantPermissive)
        try result.get()
    }

    public func armGate() async throws {
        let result = await execute(.armGate)
        try result.get()
    }

    public func resetAbort() async throws {
        let result = await execute(.resetEmergencyAbort)
        try result.get()
    }

    public func tripAbort(reason: String = "MANUAL_OPERATOR_OVERRIDE") async {
        _ = await execute(.emergencyAbort, abortReason: reason)
    }

    public func emergencyAbort() async { await tripAbort() }
    public func forceAirgapDump() async { await perform(.forceAirgapDump) }
    public func resetEmergencyAbort() async { await perform(.resetEmergencyAbort) }

    public func attachBridge() async throws {
        let (bridge, session) = try bridgeSession()
        if let cleanupTask { await cleanupTask.value }
        while let retirement = bridgeRetirement {
            let result = await retirement.task.value
            finishBridgeRetirement(retirement, result: result, session: session)
        }
        try validateSession(session)
        let barrier = bridgeAttachBarrier
        do {
            let _: ServerInfo = try await runBridgeOperation(session: session) {
                if let barrier { await barrier() }
                try Task.checkCancellation()
                return try await bridge.attach()
            }
            try validateSession(session)
            await reconcileBridge(session: session)
        } catch {
            if sessionID == session {
                await reconcileBridge(session: session)
                if sessionID == session { publishCommandResult("ATTACH FAILED: \(Self.bridgeErrorLabel(error))", color: "amber") }
            }
            throw error
        }
    }

    public func detachBridge() async {
        let session = sessionID
        guard let retirement = beginBridgeRetirement(reason: .detached) else { return }
        let result = await retirement.task.value
        finishBridgeRetirement(retirement, result: result, session: session)
        if let session, sessionID == session { await reconcile(session: session) }
    }

    public func submitTool(name: String, argumentsJSON: Data) async throws -> BridgeToolResult {
        let (bridge, session) = try bridgeSession()
        guard bridgeConnectionState == .attached, let generation = bridgeSnapshot?.generation else {
            throw BridgeError.detached
        }
        do {
            let result = try await runBridgeOperation(session: session) {
                try await bridge.submitTool(name: name, argumentsJSON: argumentsJSON, generation: generation)
            }
            if sessionID == session {
                await reconcile(session: session)
                await reconcileBridge(session: session)
            }
            return result
        } catch {
            if sessionID == session {
                await reconcile(session: session)
                await reconcileBridge(session: session)
            }
            throw error
        }
    }

    /// App-owned metadata only. The backend independently validates/classifies it.
    public func dispatchMCPCommand(_ payload: Data) async throws -> Data {
        let (bridge, session) = try bridgeSession()
        guard payload.count <= 1_048_576 else { throw BridgeError.limitExceeded(.requestBytes) }
        try Self.checkMetadataDepth(payload)
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: payload) }
        catch { throw BridgeError.malformedRequest }
        guard let request = object as? [String: Any], let method = request["method"] as? String else {
            throw BridgeError.malformedRequest
        }
        guard method == "ping" || method == "tools/list" else {
            // Do not retain untrusted method/payload strings in diagnostic history.
            throw BridgeError.unsupportedMethod("APP METADATA ALLOWLIST")
        }
        guard bridgeConnectionState == .attached else { throw BridgeError.detached }
        do {
            let result = try await runBridgeOperation(session: session) {
                try await bridge.dispatchMCPCommand(payload)
            }
            if sessionID == session { await reconcileBridge(session: session) }
            return result
        } catch {
            if sessionID == session { await reconcileBridge(session: session) }
            throw error
        }
    }

    private func bridgeSession() throws -> (ContainerSocketBridge, UUID) {
        if Task.isCancelled { throw ConsoleStateControllerError.cancelled }
        guard let bridge else { throw ConsoleStateControllerError.bridgeNotConfigured }
        guard isObserving, let sessionID else { throw ConsoleStateControllerError.notObserving }
        return (bridge, sessionID)
    }

    private func validateSession(_ session: UUID) throws {
        if Task.isCancelled { throw ConsoleStateControllerError.cancelled }
        guard isObserving, sessionID == session else { throw ConsoleStateControllerError.expiredGeneration }
    }

    private func runBridgeOperation<T: Sendable>(
        session: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try validateSession(session)
        let id = UUID()
        let task = Task<Result<T, any Error>, Never> {
            do {
                try Task.checkCancellation()
                return .success(try await operation())
            } catch { return .failure(error) }
        }
        bridgeOperations[id] = ConsoleBridgeOperation(
            cancel: { task.cancel() }, settle: { _ = await task.value }
        )
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        bridgeOperations.removeValue(forKey: id)
        // Preserve a real response/effect that won cancellation; projection is
        // separately session-checked by callers, never rebound to a new session.
        return try result.get()
    }

    private func cancelBridgeWork() {
        for operation in bridgeOperations.values { operation.cancel() }
        for command in pendingCommands.values where command.bridgeApproval != nil {
            command.admission.revoke(.cancelled)
            command.task.cancel()
        }
    }

    /// Synchronous half of teardown. No actor hop precedes connection revocation.
    private func beginBridgeRetirement(reason: BridgeRevocationReason) -> ConsoleBridgeRetirement? {
        guard let bridge else { return nil }
        bridge.revokeAdmissions(scope: .currentConnection, reason: reason)
        let operations = Array(bridgeOperations.values)
        bridgeOperations.removeAll()
        for operation in operations { operation.cancel() }
        let commandIDs = pendingCommands.compactMap { $0.value.bridgeApproval == nil ? nil : $0.key }
        let commands = commandIDs.compactMap { pendingCommands.removeValue(forKey: $0) }
        for command in commands {
            command.admission.revoke(.expiredGeneration)
            command.task.cancel()
        }
        if let bridgeRetirement, operations.isEmpty, commands.isEmpty { return bridgeRetirement }
        let previous = bridgeRetirement
        let cursor = lastBridgeCursor
        let task = Task<ConsoleBridgeRetirementResult, Never> {
            if let previous { _ = await previous.task.value }
            let receipt = await bridge.detach()
            for operation in operations { await operation.settle() }
            for command in commands { _ = await command.task.value }
            return ConsoleBridgeRetirementResult(receipt: receipt, snapshot: await bridge.snapshot(after: cursor))
        }
        let retirement = ConsoleBridgeRetirement(id: UUID(), task: task)
        bridgeRetirement = retirement
        return retirement
    }

    private func finishBridgeRetirement(
        _ retirement: ConsoleBridgeRetirement,
        result: ConsoleBridgeRetirementResult,
        session: UUID?
    ) {
        guard bridgeRetirement?.id == retirement.id else { return }
        bridgeRetirement = nil
        guard sessionID == session else { return }
        applyBridgeSnapshot(result.snapshot)
        // The backend receipt, not the request to detach, is teardown evidence.
        if result.receipt.outcome == .cleanupIncomplete {
            publishCommandResult("DETACH INCOMPLETE: LOCAL CLEANUP", color: "red")
        }
    }

    private func execute(
        _ command: ConsoleCommand,
        abortReason: String = "MANUAL_OPERATOR_OVERRIDE"
    ) async -> Result<Void, any Error> {
        await execute(commandRequest(command), abortReason: abortReason)
    }

    private func execute(
        _ request: ConsoleCommandRequest,
        abortReason: String = "MANUAL_OPERATOR_OVERRIDE"
    ) async -> Result<Void, any Error> {
        let command = request.command
        if Task.isCancelled {
            publishCommandResult(
                "\(command.label) REJECTED: CANCELLED", color: "amber",
                updateLatest: isObserving && request.generation == sessionID
            )
            return .failure(ConsoleStateControllerError.cancelled)
        }
        let commandID = request.id
        if let generation = request.generation, !isObserving || sessionID != generation {
            publishCommandResult("\(command.label) REJECTED: EXPIRED SESSION", color: "amber", updateLatest: false)
            return .failure(ConsoleStateControllerError.expiredGeneration)
        }
        // F12 has no gate submission or external effect, including while stopped.
        if command == .forceAirgapDump {
            latestCommandID = commandID
            publishCommandResult("F12 NOT IMPLEMENTED", color: "amber")
            return .failure(ConsoleStateControllerError.notImplemented)
        }
        guard let generation = request.generation else {
            publishCommandResult("\(command.label) REJECTED: NOT OBSERVING", color: "amber")
            return .failure(ConsoleStateControllerError.notObserving)
        }
        guard isObserving, let session = sessionID, session == generation else {
            publishCommandResult("\(command.label) REJECTED: EXPIRED SESSION", color: "amber", updateLatest: false)
            return .failure(ConsoleStateControllerError.expiredGeneration)
        }
        latestCommandID = commandID

        let liveApproval: BridgeApprovalKey?
        if command == .grantPermissive, isBridgeConfigured {
            guard let frozen = request.bridgeApproval else {
                if let phase = request.bridgePhase, phase != .awaitingApproval {
                    publishCommandResult("GRANT REJECTED: BUSY", color: "amber")
                    return .failure(BridgeError.busy)
                }
                publishCommandResult("GRANT REJECTED: NO PENDING INTERCEPT", color: "amber")
                return .failure(ConsoleStateControllerError.noPendingIntercept)
            }
            liveApproval = frozen
        } else {
            liveApproval = nil
        }
        // Bind revocation and teardown to the connection installed at admission,
        // before any await. The owned retirement starts independently; Core abort
        // never waits for its transport cleanup. A delayed completion must only
        // settle this handle, never recapture currentConnection after reattach.
        let abortRetirement = command == .emergencyAbort
            ? beginBridgeRetirement(reason: .operatorAbort) : nil

        let admission = ConsoleCommandAdmission()
        let gate = interlockGate
        let bridge = self.bridge
        let beforeAdmission = commandAdmissionBarrier
        let executionID = UUID()
        let ownedTask = Task<Result<ConsoleCommandEffect, any Error>, Never> {
            do {
                if command == .grantPermissive, let bridge {
                    guard let liveApproval else { throw ConsoleStateControllerError.noPendingIntercept }
                    if let beforeAdmission { await beforeAdmission(command) }
                    try admission.check()
                    try Task.checkCancellation()
                    return .success(.bridgeApproval(try await bridge.approve(liveApproval)))
                }
                let receipt = try await gate.executeConsoleCommand(
                    command, abortReason: abortReason, admission: admission,
                    beforeAdmission: beforeAdmission
                )
                return .success(.core(didTransition: receipt.didTransition))
            } catch {
                return .failure(error)
            }
        }
        pendingCommands[executionID] = ConsolePendingCommand(
            admission: admission, bridgeApproval: liveApproval, task: ownedTask
        )
        let gateOutcome = await withTaskCancellationHandler {
            await ownedTask.value
        } onCancel: {
            if let liveApproval, let bridge {
                bridge.revokeAdmissions(scope: .request(liveApproval), reason: .requestCancelled)
            }
            admission.revoke(.cancelled)
            ownedTask.cancel()
        }
        pendingCommands.removeValue(forKey: executionID)

        let outcome: Result<Void, any Error>
        let message: String
        let color: String
        do {
            let effect = try gateOutcome.get()
            outcome = .success(())
            switch effect {
            case .core(let didTransition):
                message = didTransition
                    ? "\(command.label) ACCEPTED: GATE ONLY"
                    : "\(command.label) NO-OP: GATE UNCHANGED"
                color = didTransition ? (command == .emergencyAbort ? "red" : "green") : "slate"
            case .bridgeApproval:
                message = "APPROVAL ACCEPTED: REQUEST ONLY; EXECUTION UNKNOWN"
                color = "green"
            }
        } catch let error as HardwareInterlockError {
            outcome = .failure(error)
            message = "\(command.label) REJECTED: \(Self.describe(error))"
            color = "amber"
        } catch let error as ConsoleStateControllerError {
            outcome = .failure(error)
            message = "\(command.label) REJECTED: \(Self.controllerErrorLabel(error))"
            color = "amber"
        } catch let error as BridgeError {
            outcome = .failure(error)
            message = "\(command.label) REJECTED: \(Self.bridgeErrorLabel(error))"
            color = "amber"
        } catch is CancellationError {
            outcome = .failure(ConsoleStateControllerError.cancelled)
            message = "\(command.label) REJECTED: CANCELLED"
            color = "amber"
        } catch {
            outcome = .failure(error)
            message = "\(command.label) FAILED: UNCLASSIFIED ERROR"
            color = "red"
        }

        if let commandCompletionBarrier {
            await commandCompletionBarrier(command)
        }
        guard sessionID == session else { return outcome }
        // Never project a requested target or a late grant completion as current state.
        await reconcile(session: session)
        guard sessionID == session else { return outcome }
        // Preserve every completed command outcome in this session without letting
        // an older completion replace the newest command's presentation result.
        publishCommandResult(message, color: color, updateLatest: latestCommandID == commandID)
        if let retirement = abortRetirement {
            let result = await retirement.task.value
            finishBridgeRetirement(retirement, result: result, session: session)
        } else {
            await reconcileBridge(session: session)
        }
        return outcome
    }

    private func receive(_ transition: InterlockObservedTransition, session: UUID) async {
        guard sessionID == session, transition.cursor > lastCursor else { return }
        guard transition.cursor == lastCursor + 1 else {
            await reconcile(session: session)
            return
        }
        appendTransition(transition)
        lastCursor = transition.cursor
        currentStatus = transition.record.to
    }

    private func reconcile(session: UUID) async {
        let snapshot = await interlockGate.observationSnapshot(
            after: lastCursor,
            historyLimit: Self.auditRowLimit
        )
        guard sessionID == session else { return }
        apply(snapshot)
    }

    private func receiveBridge(_ event: BridgeEvent, session: UUID) async {
        guard sessionID == session, event.cursor > lastBridgeCursor else { return }
        // Events deliberately omit request bytes. Reconcile the atomic snapshot
        // to obtain both the current inspection payload and any missing audit suffix.
        await reconcileBridge(session: session)
    }

    private func reconcileBridge(session: UUID) async {
        guard sessionID == session, let bridge else { return }
        let snapshot = await bridge.snapshot(after: lastBridgeCursor)
        guard sessionID == session else { return }
        applyBridgeSnapshot(snapshot)
    }

    // Internal for deterministic DTO projection tests. This only projects values;
    // backend-issued leases and revocation still exclusively authorize live I/O.
    func applyBridgeSnapshot(_ snapshot: BridgeSnapshot) {
        guard snapshot.cursor >= lastBridgeCursor else { return }
        if snapshot.omittedEventCount > 0 {
            let first = snapshot.events.first?.cursor ?? (snapshot.cursor + 1)
            if first > lastBridgeCursor + 1 {
                omittedBridgeEvents += first - lastBridgeCursor - 1
                appendAudit(nil)
            }
        }
        for event in snapshot.events where event.cursor > lastBridgeCursor {
            appendBridgeEvent(event)
            lastBridgeCursor = event.cursor
        }
        lastBridgeCursor = snapshot.cursor
        bridgeSnapshot = snapshot
    }

    private func appendBridgeEvent(_ event: BridgeEvent) {
        let description: String
        let metric: String
        let color: String
        let subsystem: String
        switch event.kind {
        case .connectionChanged(let state):
            description = "APP BRIDGE \(state.rawValue.uppercased())"
            metric = "APP-OWNED BOUNDARY ONLY"
            color = state == .failed ? "red" : "slate"
            subsystem = "BRIDGE"
        case .serverInitialized:
            description = "CORRELATED INITIALIZE RESPONSE; ADVERTISED IDENTITY ONLY"
            metric = "NOT PEER AUTHENTICATION"
            color = "slate"
            subsystem = "BRIDGE"
        case let .interceptChanged(approval, phase):
            description = "INTERCEPT \(phase.rawValue.uppercased()); ORIGIN TRUST IN INSPECTOR"
            metric = "REQ \(approval.requestID.uuidString)"
            color = phase == .awaitingApproval ? "amber" : "slate"
            subsystem = "BRIDGE"
        case .interceptCleared(let approval):
            description = "INTERCEPT CLEARED; NO ROLLBACK CLAIM"
            metric = "REQ \(approval.requestID.uuidString)"
            color = "slate"
            subsystem = "BRIDGE"
        case .approvalAdmitted(let receipt):
            description = "REQUEST APPROVAL ACCEPTED; EXECUTION UNKNOWN"
            metric = "REQ \(receipt.key.requestID.uuidString) · GATE #\(receipt.admittedGateCursor)"
            color = "green"
            subsystem = "BRIDGE"
        case let .chunkWritten(requestID, bytes, totalWritten, elapsedNanoseconds):
            guard bytes > 0, totalWritten >= bytes else { return }
            description = "PIPE WRITE; LOCAL ACCEPTANCE ONLY"
            metric = "+\(bytes) B · TOTAL \(totalWritten) B · \(elapsedNanoseconds) ns · REQ \(requestID.uuidString)"
            color = "slate"
            subsystem = "STDIO"
        case .transferFinished(let receipt):
            guard receipt.bytesWritten >= 0, receipt.bytesRead >= 0,
                  receipt.writeChunks >= 0, receipt.readChunks >= 0 else { return }
            let response = receipt.hasCorrelatedResponse ? "CORRELATED RESPONSE; EXTERNAL EFFECTS UNVERIFIED" : "EXECUTION UNKNOWN"
            description = "PIPE \(receipt.transmissionStage.rawValue.uppercased()) · \(Self.transferOutcomeLabel(receipt.outcome)) · \(response)"
            metric = "WRITE \(receipt.bytesWritten) B/\(receipt.writeChunks) · STDOUT \(receipt.bytesRead) B/\(receipt.readChunks) · \(receipt.elapsedNanoseconds) ns · REQ \(receipt.requestID.uuidString)"
            color = receipt.outcome == .responseReceived ? "green" : "amber"
            subsystem = "STDIO"
        case .requestRejected(_, let reason):
            description = "BRIDGE REQUEST REJECTED: \(Self.rejectionLabel(reason))"
            metric = "NO EXECUTION CLAIM"
            color = "amber"
            subsystem = "BRIDGE"
        case let .admissionsRevoked(_, reason):
            description = "LOCAL ADMISSION REVOKED: \(reason.rawValue.uppercased())"
            metric = "TRANSMITTED EFFECTS NOT ROLLED BACK"
            color = reason == .operatorAbort ? "red" : "amber"
            subsystem = "BRIDGE"
        case .detached(let receipt):
            description = "LOCAL DETACH \(receipt.outcome.rawValue.uppercased()); CONTAINER DESTRUCTION NOT ASSERTED"
            metric = "HANDLES CLOSED \(receipt.handlesClosed ? "YES" : "NO") · SETTLED \(receipt.settledRequestCount) · \(receipt.elapsedNanoseconds) ns"
            color = receipt.outcome == .cleanupIncomplete ? "red" : "slate"
            subsystem = "BRIDGE"
        case .failure(let error):
            description = "BRIDGE FAILURE: \(Self.bridgeErrorLabel(error))"
            metric = "SEE TRANSMISSION RECEIPT; NO ROLLBACK CLAIM"
            color = "red"
            subsystem = "BRIDGE"
        }
        appendAudit(AuditLogRow(
            timestamp: "MONO \(event.monotonicTimeNanoseconds) ns", subsystem: subsystem,
            tagColor: color, description: description, metric: metric, isEmergency: color == "red"
        ))
    }

    private func apply(_ snapshot: InterlockObservationSnapshot) {
        guard snapshot.cursor >= lastCursor else { return }
        if snapshot.omittedTransitionCount > 0 {
            // Recompute the gap against the current cursor: another reconciliation may
            // have applied part of this snapshot while its actor hop was outstanding.
            let firstCursor = snapshot.transitions.first?.cursor ?? (snapshot.cursor + 1)
            if firstCursor > lastCursor + 1 {
                omittedAuditTransitions += firstCursor - lastCursor - 1
                appendAudit(nil)
            }
        }
        for transition in snapshot.transitions where transition.cursor > lastCursor {
            appendTransition(transition)
            lastCursor = transition.cursor
        }
        lastCursor = snapshot.cursor
        currentStatus = snapshot.currentStatus
    }

    private func observationEnded(session: UUID) {
        guard sessionID == session else { return }
        sessionID = nil
        bridge?.revokeAdmissions(scope: .currentConnection, reason: .windowClosed)
        cancelBridgeWork()
        for command in pendingCommands.values {
            command.admission.revoke(.expiredGeneration)
            command.task.cancel()
        }
        subscriptionID = nil
        observationTask = nil
        isObserving = false
    }

    private func appendTransition(_ transition: InterlockObservedTransition) {
        let record = transition.record
        let color: String = switch record.to {
        case .locked: "slate"
        case .armed: "amber"
        case .permissiveGranted: "green"
        case .emergencyAbort: "red"
        }
        appendAudit(AuditLogRow(
            timestamp: "MONO \(record.timestampNanoseconds) ns",
            subsystem: "INTERLOCK", tagColor: color,
            description: "\(record.from.rawValue) → \(record.to.rawValue): \(record.reason)",
            metric: "#\(transition.cursor)", isEmergency: record.to == .emergencyAbort
        ))
    }

    private func publishCommandResult(_ result: String, color: String, updateLatest: Bool = true) {
        if updateLatest { lastCommandResult = result }
        appendAudit(AuditLogRow(
            timestamp: "MONO \(DispatchTime.now().uptimeNanoseconds) ns",
            subsystem: "COMMAND", tagColor: color, description: result,
            metric: "LOCAL", isEmergency: color == "red"
        ))
    }

    private func appendAudit(_ row: AuditLogRow?) {
        var rows = auditRows
        if rows.first?.id == truncationRowID { rows.removeFirst() }
        if let row { rows.append(row) }
        let needsMarker = discardedAuditRows > 0 || omittedAuditTransitions > 0 || omittedBridgeEvents > 0 || rows.count > Self.auditRowLimit
        let retainedLimit = Self.auditRowLimit - (needsMarker ? 1 : 0)
        if rows.count > retainedLimit {
            let removed = rows.count - retainedLimit
            discardedAuditRows += UInt64(removed)
            rows.removeFirst(removed)
        }
        if needsMarker {
            let hasGap = omittedAuditTransitions > 0 || omittedBridgeEvents > 0
            rows.insert(AuditLogRow(
                id: truncationRowID, timestamp: "—", subsystem: hasGap ? "OBSERVATION" : "PRESENTATION",
                tagColor: "amber",
                description: hasGap ? "AUDIT GAP; AUTHORITATIVE SNAPSHOT RECONCILED" : "OLDER DISPLAY ROWS TRUNCATED",
                metric: omittedBridgeEvents > 0
                    ? "\(omittedAuditTransitions) CORE TRANSITIONS; \(omittedBridgeEvents) BRIDGE EVENTS OMITTED; \(discardedAuditRows) DISPLAY ROWS TRUNCATED"
                    : (hasGap ? "\(omittedAuditTransitions) TRANSITIONS OMITTED; \(discardedAuditRows) DISPLAY ROWS TRUNCATED" : "\(discardedAuditRows) ROWS"),
                isEmergency: false
            ), at: 0)
        }
        auditRows = rows
    }

    private static func describe(_ error: HardwareInterlockError) -> String {
        switch error {
        case let .invalidTransition(from, to): "\(from.rawValue) → \(to.rawValue)"
        case .gateLocked: "GATE LOCKED"
        case .notArmed: "NOT ARMED"
        case .emergencyAbortActive: "ABORT ACTIVE"
        case .timedOut: "TIMED OUT"
        case .taskCancelled: "CANCELLED"
        case let .subsystemFailure(reason): "SUBSYSTEM FAILURE: \(reason)"
        }
    }

    private static func controllerErrorLabel(_ error: ConsoleStateControllerError) -> String {
        switch error {
        case .notObserving: "NOT OBSERVING"
        case .notImplemented: "NOT IMPLEMENTED"
        case .cancelled: "CANCELLED"
        case .expiredGeneration: "EXPIRED SESSION"
        case .bridgeNotConfigured: "BRIDGE UNBOUND"
        case .noPendingIntercept: "NO PENDING INTERCEPT"
        }
    }

    private static func checkMetadataDepth(_ payload: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in payload {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
            } else {
                switch byte {
                case 0x22: inString = true
                case 0x7B, 0x5B:
                    depth += 1
                    guard depth <= 32 else { throw BridgeError.limitExceeded(.jsonDepth) }
                case 0x7D, 0x5D:
                    depth -= 1
                    guard depth >= 0 else { throw BridgeError.malformedRequest }
                default: break
                }
            }
        }
        guard depth == 0, !inString else { throw BridgeError.malformedRequest }
    }

    private static func bridgeErrorLabel(_ error: any Error) -> String {
        if let error = error as? ConsoleStateControllerError { return controllerErrorLabel(error) }
        if error is CancellationError { return "CANCELLED" }
        guard let error = error as? BridgeError else { return "UNCLASSIFIED ERROR" }
        switch error {
        case .busy: return "BUSY"
        case .detached: return "DETACHED"
        case .staleGeneration: return "STALE CONNECTION"
        case .staleApproval: return "STALE APPROVAL"
        case .wrongHash: return "HASH MISMATCH"
        case .expired: return "APPROVAL EXPIRED"
        case .declined: return "DECLINED"
        case .unsupportedMethod: return "UNSUPPORTED METHOD"
        case .malformedRequest: return "MALFORMED REQUEST"
        case .limitExceeded(let kind): return "LIMIT \(kind.rawValue.uppercased())"
        case .gateRejected(let error, _):
            if case .subsystemFailure = error { return "GATE SUBSYSTEM FAILURE" }
            return "GATE \(describe(error))"
        case .cancelled: return "CANCELLED"
        case .revoked(let reason, _): return "REVOKED \(reason.rawValue.uppercased())"
        case .timedOut(let kind, _): return "TIMEOUT \(kind.rawValue.uppercased())"
        case .endOfStream: return "EOF"
        case .processExited(let status, _): return "PROCESS EXIT \(status)"
        case .transportFailed: return "TRANSPORT FAILED"
        case .protocolViolation: return "PROTOCOL VIOLATION"
        case .remoteError(let code, _, _): return "JSON-RPC ERROR \(code)"
        case .toolError: return "TOOL ERROR RESPONSE"
        }
    }

    private static func rejectionLabel(_ reason: BridgeRejectionReason) -> String {
        switch reason {
        case .busy: "BUSY"
        case .detached: "DETACHED"
        case .staleGeneration: "STALE CONNECTION"
        case .staleApproval: "STALE APPROVAL"
        case .wrongHash: "HASH MISMATCH"
        case .expired: "EXPIRED"
        case .declined: "DECLINED"
        case .malformedRequest: "MALFORMED REQUEST"
        case .unsupportedMethod: "UNSUPPORTED METHOD"
        case .gateNotArmed: "GATE NOT ARMED"
        case .gateAborted: "GATE ABORTED"
        case .gateChanged: "GATE CHANGED"
        case .limitExceeded(let kind): "LIMIT \(kind.rawValue.uppercased())"
        }
    }

    private static func transferOutcomeLabel(_ outcome: BridgeTransferOutcome) -> String {
        switch outcome {
        case .responseReceived: "RESPONSE RECEIVED"
        case .remoteError(let code): "JSON-RPC ERROR \(code)"
        case .toolError: "TOOL ERROR"
        case .rejected(let reason): "REJECTED \(rejectionLabel(reason))"
        case .declined: "DECLINED"
        case .cancelled: "CANCELLED"
        case .revoked(let reason): "REVOKED \(reason.rawValue.uppercased())"
        case .timedOut(let kind): "TIMEOUT \(kind.rawValue.uppercased())"
        case .endOfStream: "EOF"
        case .processExited(let status): "PROCESS EXIT \(status)"
        case .transportFailed: "TRANSPORT FAILED"
        case .protocolViolation: "PROTOCOL VIOLATION"
        }
    }
}
