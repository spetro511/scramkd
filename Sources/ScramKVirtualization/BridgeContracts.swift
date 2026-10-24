import Foundation
import ScramKCore

// Value contracts only. No transport, authorization, deadline, or teardown is
// implemented here. Producers must validate inputs and enforce their own bounds.

public enum BridgeConnectionState: String, Sendable, Hashable {
    case detached
    case attaching
    case attached
    case detaching
    case failed
}

/// Constant-time 64-byte ASCII hexadecimal SHA-256 digest comparison with
/// branchless hex validation and case-insensitive normalization.
public func constantTimeHexEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == 64 && rhsBytes.count == 64 else {
        return false
    }
    var diff: UInt8 = 0
    var validAll: Int32 = 1
    for index in 0..<64 {
        let lb = lhsBytes[index]
        let rb = rhsBytes[index]
        let lx = Int32(lb)
        let rx = Int32(rb)
        let lDigit = ~((lx - 0x30) | (0x39 - lx))
        let lUpper = ~((lx - 0x41) | (0x46 - lx))
        let lLower = ~((lx - 0x61) | (0x66 - lx))
        let lValid = ((lDigit | lUpper | lLower) >> 31) & 1

        let rDigit = ~((rx - 0x30) | (0x39 - rx))
        let rUpper = ~((rx - 0x41) | (0x46 - rx))
        let rLower = ~((rx - 0x61) | (0x66 - rx))
        let rValid = ((rDigit | rUpper | rLower) >> 31) & 1

        validAll &= (lValid & rValid)
        diff |= (lb | 0x20) ^ (rb | 0x20)
    }
    return validAll == 1 && diff == 0
}

/// Identity issued by the bridge for one immutable tools/call wire frame.
/// Not Codable and not publicly constructible. Possession is not authorization:
/// the bridge must still validate the current pending request, hash, and epoch.
public struct BridgeApprovalKey: Sendable, Hashable {
    public let requestID: UUID
    /// Lowercase SHA-256 hex of commandPayload, including its terminating LF.
    public let sha256: String
    public let connectionGeneration: UUID

    init(requestID: UUID, sha256: String, connectionGeneration: UUID) {
        self.requestID = requestID
        self.sha256 = sha256
        self.connectionGeneration = connectionGeneration
    }

    public static func == (lhs: BridgeApprovalKey, rhs: BridgeApprovalKey) -> Bool {
        lhs.requestID == rhs.requestID
            && lhs.connectionGeneration == rhs.connectionGeneration
            && constantTimeHexEquals(lhs.sha256, rhs.sha256)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(requestID)
        hasher.combine(connectionGeneration)
        hasher.combine(sha256.lowercased())
    }
}

/// No case asserts an OS-authenticated external agent or physical-human input.
public enum OriginTrustKind: String, Sendable, Hashable {
    /// The calling application itself; originPID is its own process identifier,
    /// never the Docker child/container PID or a claimed originating agent PID.
    case appProcess
    /// Caller-asserted identity; not OS-verified provenance.
    case claimed
    case unknown
}

/// Terminal requests leave pendingIntercept and are represented by receipts.
public enum BridgeInterceptPhase: String, Sendable, Hashable {
    case awaitingApproval
    case approved
    case writing
    case awaitingResponse
}

public struct PendingIntercept: Sendable, Equatable {
    public let approval: BridgeApprovalKey
    /// Validated MCP tool name, not an executable command or trusted UI markup.
    public let toolHook: String
    /// Exact frozen UTF-8 JSON-RPC tools/call frame, including one final LF.
    /// Display code must treat this potentially sensitive content as untrusted.
    public let commandPayload: Data
    public let payloadBytes: Int
    public let originPID: Int32?
    public let originTrust: OriginTrustKind
    public let phase: BridgeInterceptPhase
    /// Monotonic admission deadline; not a Core gate TTL or a remote-execution lease.
    public let approvalDeadline: ContinuousClock.Instant

    public init(
        approval: BridgeApprovalKey,
        toolHook: String,
        commandPayload: Data,
        originPID: Int32?,
        originTrust: OriginTrustKind,
        phase: BridgeInterceptPhase,
        approvalDeadline: ContinuousClock.Instant
    ) {
        self.approval = approval
        self.toolHook = toolHook
        self.commandPayload = commandPayload
        self.payloadBytes = commandPayload.count
        self.originPID = originPID
        self.originTrust = originTrust
        self.phase = phase
        self.approvalDeadline = approvalDeadline
    }
}

/// Values advertised in a correlated initialize result, not peer authentication.
public struct ServerInfo: Sendable, Equatable {
    public let generation: UUID
    public let advertisedName: String
    public let advertisedVersion: String
    public let protocolVersion: String

    public init(
        generation: UUID,
        advertisedName: String,
        advertisedVersion: String,
        protocolVersion: String
    ) {
        self.generation = generation
        self.advertisedName = advertisedName
        self.advertisedVersion = advertisedVersion
        self.protocolVersion = protocolVersion
    }
}

/// Bytes accepted by the local pipe, not proof of remote receipt or execution.
public enum BridgeTransmissionStage: String, Sendable, Hashable {
    case none
    case partial
    /// The entire frozen frame, including LF, was accepted by local writes.
    case complete
}

public enum BridgeDeadlineKind: String, Sendable, Hashable {
    case attach
    case approval
    case write
    case response
    case detach
}

public enum BridgeLimitKind: String, Sendable, Hashable {
    case requestBytes
    case responseBytes
    case lineBytes
    case jsonDepth
    case toolNameBytes
    case cursorBytes
    case pendingRequests
    case diagnosticBytes
}

public enum BridgeRejectionReason: Sendable, Equatable {
    case busy
    case detached
    case staleGeneration
    case staleApproval
    case wrongHash
    case expired
    case declined
    case malformedRequest
    case unsupportedMethod
    case gateNotArmed
    case gateAborted
    case gateChanged
    case limitExceeded(BridgeLimitKind)
}

/// Generation-scoped broad revocation cannot target a replacement connection.
public enum RevocationScope: Sendable, Equatable {
    case request(BridgeApprovalKey)
    case privileged(generation: UUID)
    case connection(generation: UUID)
    /// Capture and revoke only the currently installed connection/attach attempt.
    /// Does not create a revocation policy inherited by a future generation.
    case currentConnection
}

/// Revocation describes local admission policy, not rollback of transmitted I/O.
public enum BridgeRevocationReason: String, Sendable, Hashable {
    case operatorAbort
    case operatorDeclined
    case requestCancelled
    case approvalExpired
    case gateChanged
    case detached
    case windowClosed
    case applicationQuit
    case connectionReplaced
    case transportFailure
}

/// A correlated response establishes only the protocol result. For every other
/// outcome after partial/complete transmission, external effects remain unknown.
public enum BridgeTransferOutcome: Sendable, Equatable {
    case responseReceived
    case remoteError(code: Int)
    case toolError
    case rejected(BridgeRejectionReason)
    case declined
    case cancelled
    case revoked(BridgeRevocationReason)
    case timedOut(BridgeDeadlineKind)
    case endOfStream
    case processExited(status: Int32)
    case transportFailed
    case protocolViolation
}

public struct BridgeTransferReceipt: Sendable, Equatable {
    public let requestID: UUID
    public let connectionGeneration: UUID
    /// Nil for internal bootstrap and allowlisted metadata, never a bypass flag.
    public let approval: BridgeApprovalKey?
    /// Successful physical write counts for this frame, including LF if written.
    public let bytesWritten: Int
    public let writeChunks: Int
    /// Observed connection stdout deltas over this request's measured interval.
    /// May include notifications; overlapping intervals are not additive. Zero
    /// means no stdout observed in that interval, not zero remote activity.
    public let bytesRead: Int
    public let readChunks: Int
    /// Measured monotonic elapsed time, including any approval wait.
    public let elapsedNanoseconds: UInt64
    public let transmissionStage: BridgeTransmissionStage
    public let hasCorrelatedResponse: Bool
    public let outcome: BridgeTransferOutcome

    public init(
        requestID: UUID,
        connectionGeneration: UUID,
        approval: BridgeApprovalKey?,
        bytesWritten: Int,
        writeChunks: Int,
        bytesRead: Int,
        readChunks: Int,
        elapsedNanoseconds: UInt64,
        transmissionStage: BridgeTransmissionStage,
        hasCorrelatedResponse: Bool,
        outcome: BridgeTransferOutcome
    ) {
        self.requestID = requestID
        self.connectionGeneration = connectionGeneration
        self.approval = approval
        self.bytesWritten = bytesWritten
        self.writeChunks = writeChunks
        self.bytesRead = bytesRead
        self.readChunks = readChunks
        self.elapsedNanoseconds = elapsedNanoseconds
        self.transmissionStage = transmissionStage
        self.hasCorrelatedResponse = hasCorrelatedResponse
        self.outcome = outcome
    }
}

/// Optional receipts preserve actual transmission on interruption. Nil means no
/// transfer was created, not an invented all-zero receipt. Diagnostic strings must
/// be bounded and scrubbed by the producer; raw stderr/payloads are not diagnostics.
public enum BridgeError: Error, Sendable, Equatable {
    case busy
    case detached
    case staleGeneration
    case staleApproval
    case wrongHash
    case expired
    case declined
    case unsupportedMethod(String)
    case malformedRequest
    case limitExceeded(BridgeLimitKind)
    case gateRejected(HardwareInterlockError, receipt: BridgeTransferReceipt?)
    case cancelled(receipt: BridgeTransferReceipt?)
    case revoked(BridgeRevocationReason, receipt: BridgeTransferReceipt?)
    case timedOut(BridgeDeadlineKind, receipt: BridgeTransferReceipt?)
    case endOfStream(receipt: BridgeTransferReceipt?)
    case processExited(status: Int32, receipt: BridgeTransferReceipt?)
    case transportFailed(reason: String, receipt: BridgeTransferReceipt?)
    case protocolViolation(reason: String, receipt: BridgeTransferReceipt?)
    case remoteError(code: Int, message: String, receipt: BridgeTransferReceipt)
    case toolError(receipt: BridgeTransferReceipt)
}

/// Admission metadata only. Core retains its grant-all-waiters semantics. A bridge
/// must recheck this exact gate cursor and request lease on every physical write.
public struct BridgeApprovalReceipt: Sendable, Equatable {
    public let key: BridgeApprovalKey
    public let admittedGateCursor: UInt64
    public let admittedAtNanoseconds: UInt64

    public init(key: BridgeApprovalKey, admittedGateCursor: UInt64, admittedAtNanoseconds: UInt64) {
        self.key = key
        self.admittedGateCursor = admittedGateCursor
        self.admittedAtNanoseconds = admittedAtNanoseconds
    }
}

public enum BridgeDetachOutcome: String, Sendable, Hashable {
    case detached
    case alreadyDetached
    /// Cleanup failed or was not verified within this operation's budget. Later
    /// resource closure can be reported separately without revising this result.
    case cleanupIncomplete
}

/// Local bridge teardown evidence; never a claim of container destruction or
/// remote cancellation. An absent exit status means exit was not observed.
public struct BridgeDetachReceipt: Sendable, Equatable {
    public let generation: UUID?
    public let localProcessIdentifier: Int32?
    /// A local stop request was made; not evidence that a signal was delivered.
    public let terminationRequested: Bool
    public let observedExitStatus: Int32?
    public let handlesClosed: Bool
    public let settledRequestCount: Int
    public let elapsedNanoseconds: UInt64
    public let outcome: BridgeDetachOutcome

    public init(
        generation: UUID?,
        localProcessIdentifier: Int32?,
        terminationRequested: Bool,
        observedExitStatus: Int32?,
        handlesClosed: Bool,
        settledRequestCount: Int,
        elapsedNanoseconds: UInt64,
        outcome: BridgeDetachOutcome
    ) {
        self.generation = generation
        self.localProcessIdentifier = localProcessIdentifier
        self.terminationRequested = terminationRequested
        self.observedExitStatus = observedExitStatus
        self.handlesClosed = handlesClosed
        self.settledRequestCount = settledRequestCount
        self.elapsedNanoseconds = elapsedNanoseconds
        self.outcome = outcome
    }
}

public struct BridgeToolResult: Sendable, Equatable {
    /// Complete correlated UTF-8 JSON-RPC response object, excluding framing LF.
    /// This is untrusted remote content, not proof of the tool's external effects.
    public let rawResponseData: Data
    public let receipt: BridgeTransferReceipt

    public init(rawResponseData: Data, receipt: BridgeTransferReceipt) {
        self.rawResponseData = rawResponseData
        self.receipt = receipt
    }
}

/// Events retain summaries, not request payload copies. Reconcile the snapshot
/// for the current pending payload or after a stream cursor gap.
public enum BridgeEventKind: Sendable, Equatable {
    case connectionChanged(BridgeConnectionState)
    case serverInitialized(ServerInfo)
    case interceptChanged(approval: BridgeApprovalKey, phase: BridgeInterceptPhase)
    case interceptCleared(approval: BridgeApprovalKey)
    case approvalAdmitted(BridgeApprovalReceipt)
    case transferFinished(BridgeTransferReceipt)
    case chunkWritten(requestID: UUID, bytes: Int, totalWritten: Int, elapsedNanoseconds: UInt64)
    case requestRejected(requestID: UUID?, reason: BridgeRejectionReason)
    case admissionsRevoked(scope: RevocationScope, reason: BridgeRevocationReason)
    /// May report eventual local closure after an earlier cleanupIncomplete
    /// result. Such an event never revises that caller's deadline classification.
    case detached(BridgeDetachReceipt)
    case failure(BridgeError)
}

public struct BridgeEvent: Sendable, Equatable {
    /// Bridge-instance event cursor; monotonically increasing across attachments.
    public let cursor: UInt64
    /// Nil only for events with no connection generation, such as initial detach.
    public let generation: UUID?
    /// Process-local monotonic uptime; not a wall clock or cross-process timestamp.
    public let monotonicTimeNanoseconds: UInt64
    public let kind: BridgeEventKind

    public init(cursor: UInt64, generation: UUID?, monotonicTimeNanoseconds: UInt64, kind: BridgeEventKind) {
        self.cursor = cursor
        self.generation = generation
        self.monotonicTimeNanoseconds = monotonicTimeNanoseconds
        self.kind = kind
    }
}

/// Snapshot and bounded audit suffix captured in one bridge actor turn.
public struct BridgeSnapshot: Sendable, Equatable {
    public let cursor: UInt64
    public let connectionState: BridgeConnectionState
    public let generation: UUID?
    public let serverInfo: ServerInfo?
    public let pendingIntercept: PendingIntercept?
    public let latestTransfer: BridgeTransferReceipt?
    /// Producer-bounded events after the requested cursor, oldest first.
    public let events: [BridgeEvent]
    public let omittedEventCount: UInt64

    public init(
        cursor: UInt64,
        connectionState: BridgeConnectionState,
        generation: UUID?,
        serverInfo: ServerInfo?,
        pendingIntercept: PendingIntercept?,
        latestTransfer: BridgeTransferReceipt?,
        events: [BridgeEvent],
        omittedEventCount: UInt64
    ) {
        self.cursor = cursor
        self.connectionState = connectionState
        self.generation = generation
        self.serverInfo = serverInfo
        self.pendingIntercept = pendingIntercept
        self.latestTransfer = latestTransfer
        self.events = events
        self.omittedEventCount = omittedEventCount
    }
}

/// Atomic bootstrap plus a bounded future-only stream. Explicitly unsubscribe
/// even if never iterated. Cursor gaps require snapshot reconciliation.
public struct BridgeObservation: Sendable {
    public let id: UUID
    public let snapshot: BridgeSnapshot
    public let events: AsyncStream<BridgeEvent>

    public init(id: UUID, snapshot: BridgeSnapshot, events: AsyncStream<BridgeEvent>) {
        self.id = id
        self.snapshot = snapshot
        self.events = events
    }
}
