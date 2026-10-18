import Combine
import Foundation
import os
import TacticalCore

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
}

/// Capture synchronously at button press, before scheduling asynchronous UI work.
/// There is no public initializer or writable generation; requests cannot adopt a
/// later observation session, including a session on another controller.
public struct ConsoleCommandRequest: Identifiable, Sendable {
    public let id: UUID
    public let command: ConsoleCommand
    fileprivate let generation: UUID?

    fileprivate init(command: ConsoleCommand, generation: UUID?) {
        self.id = UUID()
        self.command = command
        self.generation = generation
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
    let task: Task<Result<ConsoleGateCommandReceipt, any Error>, Never>
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

/// Offline gate presentation. No transport, teardown, or deadline capability is bound.
@MainActor
public final class ConsoleStateController: ObservableObject {
    /// Includes the persistent truncation marker when older presentation rows are removed.
    public static let auditRowLimit = 256

    @Published public private(set) var currentStatus: InterlockStatus = .locked
    // No countdown task: neither deadline duration nor enforcement meaning is approved.
    @Published public private(set) var countdownTTL: String = "UNBOUND"
    @Published public private(set) var auditRows: [AuditLogRow] = []
    @Published public private(set) var isObserving: Bool = false
    @Published public private(set) var lastCommandResult: String = "UNBOUND"
    @Published public var activeBay: String = "BAY-01"

    private let interlockGate: HardwareInterlockGate
    private var sessionID: UUID?
    private var subscriptionID: UUID?
    private var bootstrapTask: Task<InterlockObservation, Never>?
    private var observationTask: Task<Void, Never>?
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

    public init(interlockGate: HardwareInterlockGate) {
        self.interlockGate = interlockGate
        self.commandCompletionBarrier = nil
        self.observationDeliveryBarrier = nil
        self.bootstrapDeliveryBarrier = nil
        self.commandAdmissionBarrier = nil
    }

    init(
        interlockGate: HardwareInterlockGate,
        observationDeliveryBarrier: (@MainActor @Sendable () async -> Void)?,
        bootstrapDeliveryBarrier: (@MainActor @Sendable (InterlockObservationSnapshot) async -> Void)? = nil,
        commandAdmissionBarrier: (@Sendable (ConsoleCommand) async -> Void)? = nil,
        commandCompletionBarrier: (@MainActor @Sendable (ConsoleCommand) async -> Void)? = nil
    ) {
        self.interlockGate = interlockGate
        self.commandCompletionBarrier = commandCompletionBarrier
        self.observationDeliveryBarrier = observationDeliveryBarrier
        self.bootstrapDeliveryBarrier = bootstrapDeliveryBarrier
        self.commandAdmissionBarrier = commandAdmissionBarrier
    }

    deinit {
        bootstrapTask?.cancel()
        observationTask?.cancel()
        for command in pendingCommands.values {
            command.admission.revoke(.expiredGeneration)
            command.task.cancel()
        }
    }

    /// Idempotent atomic bootstrap. Initialization itself owns no background work.
    public func start() async {
        if isObserving, let sessionID {
            await reconcile(session: sessionID)
            return
        }

        let session: UUID
        let bootstrap: Task<InterlockObservation, Never>
        if let existingSession = sessionID, let existingBootstrap = bootstrapTask {
            session = existingSession
            bootstrap = existingBootstrap
        } else {
            session = UUID()
            sessionID = session
            let gate = interlockGate
            let cursor = lastCursor
            let bootstrapBarrier = bootstrapDeliveryBarrier
            bootstrap = Task {
                let observation = await gate.observeTransitions(after: cursor, historyLimit: Self.auditRowLimit)
                if let bootstrapBarrier { await bootstrapBarrier(observation.snapshot) }
                return observation
            }
            bootstrapTask = bootstrap
        }

        let observation = await bootstrap.value
        guard sessionID == session else {
            await interlockGate.unsubscribeObservation(id: observation.id)
            return
        }
        guard !isObserving else { return }
        bootstrapTask = nil
        subscriptionID = observation.id
        apply(observation.snapshot)
        isObserving = true
        let gate = interlockGate
        let deliveryBarrier = observationDeliveryBarrier
        observationTask = Task { [weak self] in
            for await transition in observation.transitions {
                guard !Task.isCancelled else { break }
                if let deliveryBarrier { await deliveryBarrier() }
                guard !Task.isCancelled else { break }
                // The optional reference is held only for this delivery, never across next().
                await self?.receive(transition, session: session)
            }
            await gate.unsubscribeObservation(id: observation.id)
            self?.observationEnded(session: session)
        }
    }

    /// Invalidates callbacks before awaiting cleanup. Gate safety remains independent.
    public func stop() async {
        if sessionID == nil, bootstrapTask == nil, observationTask == nil, pendingCommands.isEmpty {
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
        let previousCleanup = cleanupTask
        let gate = interlockGate
        let cleanup = Task<Void, Never> {
            await previousCleanup?.value
            if let oldSubscription {
                await gate.unsubscribeObservation(id: oldSubscription)
            }
            if let pendingBootstrap {
                let observation = await pendingBootstrap.value
                await gate.unsubscribeObservation(id: observation.id)
            }
            await oldTask?.value
            for command in oldCommands { _ = await command.task.value }
        }
        let id = UUID()
        cleanupID = id
        cleanupTask = cleanup
        await cleanup.value
        if cleanupID == id {
            cleanupID = nil
            cleanupTask = nil
        }
    }

    /// Buttons and key routing use the same path. No UI queue can hold abort behind grant.
    public func perform(_ command: ConsoleCommand) async {
        // The shared executor publishes both accepted and rejected outcomes once.
        _ = await execute(command)
    }

    public func commandRequest(_ command: ConsoleCommand) -> ConsoleCommandRequest {
        ConsoleCommandRequest(command: command, generation: isObserving ? sessionID : nil)
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

        let admission = ConsoleCommandAdmission()
        let gate = interlockGate
        let beforeAdmission = commandAdmissionBarrier
        let executionID = UUID()
        let ownedTask = Task<Result<ConsoleGateCommandReceipt, any Error>, Never> {
            do {
                return .success(try await gate.executeConsoleCommand(
                    command, abortReason: abortReason, admission: admission,
                    beforeAdmission: beforeAdmission
                ))
            } catch {
                return .failure(error)
            }
        }
        pendingCommands[executionID] = ConsolePendingCommand(admission: admission, task: ownedTask)
        let gateOutcome = await withTaskCancellationHandler {
            await ownedTask.value
        } onCancel: {
            admission.revoke(.cancelled)
            ownedTask.cancel()
        }
        pendingCommands.removeValue(forKey: executionID)

        let outcome: Result<Void, any Error>
        let message: String
        let color: String
        do {
            let receipt = try gateOutcome.get()
            outcome = .success(())
            message = receipt.didTransition
                ? "\(command.label) ACCEPTED: GATE ONLY"
                : "\(command.label) NO-OP: GATE UNCHANGED"
            color = receipt.didTransition ? (command == .emergencyAbort ? "red" : "green") : "slate"
        } catch let error as HardwareInterlockError {
            outcome = .failure(error)
            message = "\(command.label) REJECTED: \(Self.describe(error))"
            color = "amber"
        } catch let error as ConsoleStateControllerError {
            outcome = .failure(error)
            let reason = error == .cancelled ? "CANCELLED" : "EXPIRED SESSION"
            message = "\(command.label) REJECTED: \(reason)"
            color = "amber"
        } catch is CancellationError {
            outcome = .failure(ConsoleStateControllerError.cancelled)
            message = "\(command.label) REJECTED: CANCELLED"
            color = "amber"
        } catch {
            outcome = .failure(error)
            message = "\(command.label) FAILED: \(String(describing: error))"
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
        let needsMarker = discardedAuditRows > 0 || omittedAuditTransitions > 0 || rows.count > Self.auditRowLimit
        let retainedLimit = Self.auditRowLimit - (needsMarker ? 1 : 0)
        if rows.count > retainedLimit {
            let removed = rows.count - retainedLimit
            discardedAuditRows += UInt64(removed)
            rows.removeFirst(removed)
        }
        if needsMarker {
            let hasGap = omittedAuditTransitions > 0
            rows.insert(AuditLogRow(
                id: truncationRowID, timestamp: "—", subsystem: hasGap ? "OBSERVATION" : "PRESENTATION",
                tagColor: "amber",
                description: hasGap ? "AUDIT GAP; AUTHORITATIVE SNAPSHOT RECONCILED" : "OLDER DISPLAY ROWS TRUNCATED",
                metric: hasGap
                    ? "\(omittedAuditTransitions) TRANSITIONS OMITTED; \(discardedAuditRows) DISPLAY ROWS TRUNCATED"
                    : "\(discardedAuditRows) ROWS",
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
}
