import Foundation

/// Unique identifier for discrete supervisor subsystems.
public enum SubsystemIdentifier: String, Sendable, Hashable, Codable, CustomStringConvertible {
    case core = "CORE"
    case interlock = "INTERLOCK"
    case audioSVS = "AUDIO_SVS"
    case virtualization = "VIRT"
    case ui = "UI"

    public var description: String {
        rawValue
    }
}

/// Operational state of hardware interlock safety mechanisms.
public enum InterlockStatus: String, Sendable, Hashable, Codable, CustomStringConvertible {
    case locked = "LOCKED"
    case armed = "ARMED"
    case permissiveGranted = "PERMISSIVE_GRANTED"
    case emergencyAbort = "EMERGENCY_ABORT"

    public var description: String {
        rawValue
    }
}

/// Errors originating from hardware interlock validation and transition constraints.
public enum HardwareInterlockError: Error, Sendable, Equatable {
    case invalidTransition(from: InterlockStatus, to: InterlockStatus)
    case gateLocked
    case notArmed
    case emergencyAbortActive
    case timedOut
    case taskCancelled
    case subsystemFailure(reason: String)
}

/// Subsystem operational health status.
public enum SubsystemHealth: String, Sendable, Hashable, Codable {
    case nominal = "NOMINAL"
    case degraded = "DEGRADED"
    case critical = "CRITICAL"
    case offline = "OFFLINE"
}

/// Immutable, thread-safe telemetry frame transmitted between hypervisor subsystems.
public struct TelemetryFrame: Sendable, Hashable, Codable {
    public let timestampNanoseconds: UInt64
    public let sequenceNumber: UInt64
    public let subsystem: SubsystemIdentifier
    public let health: SubsystemHealth
    public let interlockState: InterlockStatus
    public let payloadSize: Int

    public init(
        timestampNanoseconds: UInt64,
        sequenceNumber: UInt64,
        subsystem: SubsystemIdentifier,
        health: SubsystemHealth,
        interlockState: InterlockStatus,
        payloadSize: Int
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.sequenceNumber = sequenceNumber
        self.subsystem = subsystem
        self.health = health
        self.interlockState = interlockState
        self.payloadSize = payloadSize
    }
}

/// Single-use, request-bound monotonic permissive permit issued by `HardwareInterlockGate`.
public struct PermissivePermit: Sendable, Hashable, Equatable {
    public let permitID: UUID
    public let requestID: UUID
    public let issuedStateVersion: UInt64
    public let expiresAt: ContinuousClock.Instant

    public init(
        permitID: UUID = UUID(),
        requestID: UUID,
        issuedStateVersion: UInt64,
        expiresAt: ContinuousClock.Instant
    ) {
        self.permitID = permitID
        self.requestID = requestID
        self.issuedStateVersion = issuedStateVersion
        self.expiresAt = expiresAt
    }
}

/// Bounded Dead-Man's Hold-to-Read policy for extending an active intercept authorization window.
public struct ActiveHoldPolicy: Sendable, Hashable, Equatable {
    public let initialWindow: Duration
    public let maxHoldDuration: Duration
    public let criticalReadGuardDuration: Duration

    public init(
        initialWindow: Duration = .seconds(5),
        maxHoldDuration: Duration = .seconds(120),
        criticalReadGuardDuration: Duration = .milliseconds(1500)
    ) {
        self.initialWindow = initialWindow
        self.maxHoldDuration = maxHoldDuration
        self.criticalReadGuardDuration = criticalReadGuardDuration
    }
}
