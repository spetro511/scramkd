import SwiftUI
import TacticalVirtualization

/// Native state drawable beneath SwiftUI's target labels and ruler overlays.
@MainActor
public struct TacticalMetalViewportContainer: NSViewRepresentable {
    @ObservedObject private var stateController: ConsoleStateController
    @Environment(\.colorSchemeContrast) private var contrast
    private let framebufferClient: FramebufferClient?

    public init(stateController: ConsoleStateController, framebufferClient: FramebufferClient? = nil) {
        self.stateController = stateController
        self.framebufferClient = framebufferClient
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> TacticalMetalViewportView {
        let view = TacticalMetalViewportView()
        updatePresentation(view)
        context.coordinator.bind(framebufferClient, to: view)
        return view
    }

    public func updateNSView(_ nsView: TacticalMetalViewportView, context: Context) {
        updatePresentation(nsView)
        context.coordinator.bind(framebufferClient, to: nsView)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TacticalMetalViewportView, context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 200
        return CGSize(width: max(320, width), height: max(200, height))
    }

    public static func dismantleNSView(_ nsView: TacticalMetalViewportView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.shutdown()
    }

    private func updatePresentation(_ view: TacticalMetalViewportView) {
        view.updateInterlockStatus(stateController.currentStatus, isObserving: stateController.isObserving)
        view.viewportRenderer.updateIncreasedContrast(contrast == .increased)
    }

    /// Observation only. Connect/disconnect remain explicit composition-root
    /// operations; this coordinator neither launches a source nor routes input.
    @MainActor
    public final class Coordinator {
        enum ObservationEvent: Sendable {
            case waitingForPredecessor
            case registered(UUID)
            case willUnsubscribe(UUID)
        }

        public private(set) var observationFailure: String?
        private var client: FramebufferClient?
        private weak var view: TacticalMetalViewportView?
        private var observationTask: Task<Void, Never>?
        // This tail owns ALL predecessors, including a canceled registration
        // waiting for an older unsubscribe. A nil binding must not discard it.
        private var settlementTask: Task<Void, Never>?
        private var handoffTicket: FramebufferObservationHandoffRegistry.Ticket?
        private let observationBarrier: @Sendable (ObservationEvent) async -> Void
        private var bindingID = UUID()
        private var cursor = TacticalFramebufferDeliveryCursor()
        private var isBound = false

        init(observationBarrier: @escaping @Sendable (ObservationEvent) async -> Void = { _ in }) {
            self.observationBarrier = observationBarrier
        }

        static func retainedHandoffExists(for client: FramebufferClient) -> Bool {
            FramebufferObservationHandoffRegistry.contains(client)
        }

        func bind(_ newClient: FramebufferClient?, to newView: TacticalMetalViewportView) {
            let sameClient: Bool
            if let client, let newClient { sameClient = client === newClient }
            else { sameClient = client == nil && newClient == nil }
            if isBound, sameClient, view === newView { return }
            let predecessor = stop()
            client = newClient
            view = newView
            isBound = true
            observationFailure = nil
            newView.viewportRenderer.setFramebufferSourceConfigured(newClient != nil)
            refresh(newView)
            guard let newClient else { return }
            let ticket: FramebufferObservationHandoffRegistry.Ticket
            let clientPredecessor: Task<Void, Never>?
            switch FramebufferObservationHandoffRegistry.acquire(newClient, owner: self) {
            case .admitted(let claim, let oldClientTail):
                ticket = claim
                clientPredecessor = oldClientTail
            case .activeOwner:
                // An unrelated active view is not an implicit handoff. Keep
                // this failure sticky until an explicit rebind; do not retry.
                observationFailure = "FRAMEBUFFER OBSERVER ALREADY OWNED"
                return
            case .capacity:
                observationFailure = "FRAMEBUFFER HANDOFF CAPACITY EXCEEDED"
                return
            }
            handoffTicket = ticket
            let currentBinding = bindingID
            let barrier = observationBarrier
            let task = Task { [weak self] in
                // Runs even when the coordinator has deinitialized or this
                // successor was canceled before it could register an observer.
                defer { FramebufferObservationHandoffRegistry.complete(ticket) }
                if predecessor != nil || clientPredecessor != nil {
                    await barrier(.waitingForPredecessor)
                    // Deliberately settle even when THIS waiter was canceled.
                    // Otherwise A -> canceled B -> C could bypass A's cleanup.
                    await predecessor?.value
                    await clientPredecessor?.value
                }
                guard !Task.isCancelled, self?.isCurrent(currentBinding) == true else { return }
                do {
                    // Actor contract: registration + current delivery are atomic.
                    // updates is latest-1; revision gaps are expected, not replayed.
                    let observationID: UUID
                    let updates: AsyncStream<FrameDelivery>
                    do {
                        let observation = try await newClient.observeFrames()
                        observationID = observation.id
                        updates = observation.updates
                        await barrier(.registered(observationID))
                        if !Task.isCancelled, self?.isCurrent(currentBinding) == true {
                            self?.receive(observation.current, binding: currentBinding)
                        }
                        // The bootstrap snapshot is not kept across the stream
                        // loop/cleanup; only its ID and bounded stream are needed.
                    }
                    if !Task.isCancelled, self?.isCurrent(currentBinding) == true {
                        for await delivery in updates {
                            guard !Task.isCancelled, self?.isCurrent(currentBinding) == true else { break }
                            self?.receive(delivery, binding: currentBinding)
                        }
                        if self?.isCurrent(currentBinding) == true {
                            self?.finish(binding: currentBinding, reason: "FRAME OBSERVATION ENDED")
                        }
                    }
                    // Runs on normal EOF, cancellation, replacement, and dismantle.
                    // No unstructured cleanup task or strong coordinator capture.
                    // No binding/cancellation guard may bypass owned cleanup.
                    FramebufferObservationHandoffRegistry.retire(ticket)
                    await barrier(.willUnsubscribe(observationID))
                    await newClient.unsubscribe(id: observationID)
                    // Keep the stream itself owned through explicit cleanup,
                    // including cancellation before an iterator is constructed.
                    withExtendedLifetime(updates) {}
                } catch {
                    self?.finish(binding: currentBinding, reason: "FRAME OBSERVATION FAILED: \(error)")
                }
            }
            observationTask = task
            settlementTask = task
            FramebufferObservationHandoffRegistry.publish(task, for: ticket)
        }

        @discardableResult
        func stop() -> Task<Void, Never>? {
            bindingID = UUID()
            // Publish retirement before clearing the client/owner fields. A
            // different coordinator can now await this exact client's tail.
            if let handoffTicket { FramebufferObservationHandoffRegistry.retire(handoffTicket) }
            handoffTicket = nil
            let oldTask = observationTask
            oldTask?.cancel()
            observationTask = nil
            if let view {
                view.viewportRenderer.clearFramebuffer()
                refresh(view)
            }
            client = nil
            view = nil
            cursor = TacticalFramebufferDeliveryCursor()
            isBound = false
            return settlementTask // Includes inactive/nil-binding cleanup predecessors.
        }

        deinit {
            // Registry ownership is weak. A nil owner legitimizes waiting on
            // its already-published tail; no actor access is needed in deinit.
            observationTask?.cancel()
        }

        private func isCurrent(_ binding: UUID) -> Bool {
            bindingID == binding && isBound && view?.isDismantled == false
        }

        private func receive(_ delivery: FrameDelivery, binding: UUID) {
            guard isCurrent(binding), let view else { return }
            if let revision = cursor.revision, delivery.revision <= revision { return }
            guard cursor.accept(revision: delivery.revision, generation: delivery.generation, frame: delivery.frame) else {
                observationFailure = "FRAME DELIVERY METADATA REJECTED"
                view.viewportRenderer.clearFramebuffer()
                refresh(view)
                return
            }
            if let frame = delivery.frame {
                view.viewportRenderer.beginFramebufferGeneration(frame.generation)
                view.viewportRenderer.updateFramebuffer(frame)
            } else {
                // A newer nil delivery retires both the visible image and pending
                // CPU upload synchronously, including disconnect/failure/EOF.
                view.viewportRenderer.clearFramebuffer()
            }
            refresh(view)
        }

        private func finish(binding: UUID, reason: String) {
            guard isCurrent(binding), let view else { return }
            observationFailure = reason
            view.viewportRenderer.clearFramebuffer()
            refresh(view)
            observationTask = nil
            isBound = false
        }

        private func refresh(_ view: TacticalMetalViewportView) {
            view.synchronizeStateBackground()
            view.refreshAccessibilitySummary()
        }
    }
}

/// Cross-coordinator ownership, confined to MainActor. No client is stored in
/// this registry: a worker retains its client only until real unsubscription.
/// One latest tail per client, at most 8 clients and 16 unfinished workers;
/// superseded predecessors remain counted until their own completion defer.
@MainActor
private enum FramebufferObservationHandoffRegistry {
    struct Ticket: Sendable {
        let clientID: ObjectIdentifier
        let token: UUID
    }
    enum Admission {
        case admitted(Ticket, Task<Void, Never>?)
        case activeOwner
        case capacity
    }
    @MainActor
    private final class Entry {
        let token: UUID
        weak var owner: TacticalMetalViewportContainer.Coordinator?
        var retiring = false
        var tail: Task<Void, Never>?

        init(token: UUID, owner: TacticalMetalViewportContainer.Coordinator) {
            self.token = token
            self.owner = owner
        }
    }
    private static let maximumClients = 8
    private static let maximumUnfinishedWorkers = 16
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var unfinished: Set<UUID> = []

    static func contains(_ client: FramebufferClient) -> Bool {
        entries[ObjectIdentifier(client)] != nil
    }

    static func acquire(_ client: FramebufferClient, owner: TacticalMetalViewportContainer.Coordinator) -> Admission {
        let key = ObjectIdentifier(client)
        let previous = entries[key]
        if let previous, !previous.retiring, previous.owner != nil { return .activeOwner }
        guard unfinished.count < maximumUnfinishedWorkers,
              previous != nil || entries.count < maximumClients else { return .capacity }
        let ticket = Ticket(clientID: key, token: UUID())
        let predecessor = previous?.tail
        entries[key] = Entry(token: ticket.token, owner: owner)
        unfinished.insert(ticket.token)
        return .admitted(ticket, predecessor)
    }

    static func publish(_ task: Task<Void, Never>, for ticket: Ticket) {
        guard let entry = entries[ticket.clientID], entry.token == ticket.token else { return }
        entry.tail = task
    }

    static func retire(_ ticket: Ticket) {
        guard let entry = entries[ticket.clientID], entry.token == ticket.token else { return }
        entry.retiring = true
    }

    static func complete(_ ticket: Ticket) {
        guard unfinished.remove(ticket.token) != nil else { return }
        // Old cleanup must never erase a replacement coordinator's entry.
        guard entries[ticket.clientID]?.token == ticket.token else { return }
        entries.removeValue(forKey: ticket.clientID)
    }
}
