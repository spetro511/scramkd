import Foundation

/// A transition's stable position in this gate's audit history. Cursors start at one
/// and must not be reused with a different gate instance.
public struct InterlockObservedTransition: Sendable, Hashable {
    public let cursor: UInt64
    public let record: InterlockTransitionRecord

    public init(cursor: UInt64, record: InterlockTransitionRecord) {
        self.cursor = cursor
        self.record = record
    }
}

/// Status and a bounded audit suffix captured in one gate actor turn.
public struct InterlockObservationSnapshot: Sendable {
    public let currentStatus: InterlockStatus
    /// All transitions through this boundary are reflected in currentStatus.
    public let cursor: UInt64
    public let transitions: [InterlockObservedTransition]
    /// Transitions after the requested cursor omitted from the bounded suffix.
    public let omittedTransitionCount: UInt64

    public init(
        currentStatus: InterlockStatus,
        cursor: UInt64,
        transitions: [InterlockObservedTransition],
        omittedTransitionCount: UInt64
    ) {
        self.currentStatus = currentStatus
        self.cursor = cursor
        self.transitions = transitions
        self.omittedTransitionCount = omittedTransitionCount
    }
}

/// Atomic bootstrap plus future-only observations. Explicitly unsubscribe when done.
/// Buffer overflow is detectable by a cursor gap; reconcile using observationSnapshot.
public struct InterlockObservation: Sendable {
    public let id: UUID
    public let snapshot: InterlockObservationSnapshot
    public let transitions: AsyncStream<InterlockObservedTransition>

    public init(
        id: UUID,
        snapshot: InterlockObservationSnapshot,
        transitions: AsyncStream<InterlockObservedTransition>
    ) {
        self.id = id
        self.snapshot = snapshot
        self.transitions = transitions
    }
}
