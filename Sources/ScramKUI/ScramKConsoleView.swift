import SwiftUI
import ScramKCore

/// Fixed logical-point console. The composition root owns lifecycle and key routing.
@MainActor
public struct ScramKConsoleView: View {
    @ObservedObject private var controller: ConsoleStateController
    @State private var grantRequest: ConsoleCommandRequest?
    @State private var abortRequest: ConsoleCommandRequest?
    @State private var dumpRequest: ConsoleCommandRequest?
    @State private var drawerToggleID: UUID?

    public init(controller: ConsoleStateController) {
        self.controller = controller
    }

    public var body: some View {
        let semanticSummary = controller.currentSemanticInterceptSummary
        VStack(spacing: 0) {
            ConsoleWindowChromeBar(
                status: controller.currentStatus,
                isObserving: controller.isObserving,
                countdownTTL: controller.countdownTTL,
                bridgeSnapshot: controller.bridgeSnapshot,
                isBridgeConfigured: controller.isBridgeConfigured,
                audioStatusLabel: controller.audioStatusLabel,
                audioStatusColorName: controller.audioStatusColorName,
                residentMemoryMB: controller.residentMemoryMB,
                securityProfile: controller.securityProfile,
                isHoldActive: controller.isAuthorizationHoldActive,
                semanticSummary: semanticSummary
            )
            .frame(height: DesignTokens.Layout.chromeHeight)

            HStack(spacing: 0) {
                ConsoleNavigationRail(
                    activeBay: $controller.activeBay,
                    bridgeSnapshot: controller.bridgeSnapshot,
                    isBridgeConfigured: controller.isBridgeConfigured,
                    isObserving: controller.isObserving,
                    frameSnapshot: controller.frameSnapshot,
                    isFramebufferConfigured: controller.isFramebufferConfigured
                )
                    .frame(width: DesignTokens.Layout.railWidth)
                ConsoleViewport(controller: controller)
                    .frame(width: DesignTokens.Layout.viewportWidth)
                ConsoleSafetyCockpit(
                    status: controller.currentStatus,
                    isObserving: controller.isObserving,
                    countdownTTL: controller.countdownTTL,
                    lastCommandResult: controller.lastCommandResult,
                    bridgeSnapshot: controller.bridgeSnapshot,
                    isBridgeConfigured: controller.isBridgeConfigured,
                    grant: { grantRequest = controller.commandRequest(.grantPermissive) },
                    abort: { abortRequest = controller.commandRequest(.emergencyAbort) },
                    airgap: { dumpRequest = controller.commandRequest(.forceAirgapDump) },
                    securityProfile: controller.securityProfile,
                    isAuthorizationHoldActive: controller.isAuthorizationHoldActive,
                    isInspectorDrawerExpanded: controller.isInspectorDrawerExpanded,
                    semanticSummary: semanticSummary,
                    pendingIntercept: controller.pendingIntercept,
                    toggleInspectorDrawer: { drawerToggleID = UUID() }
                )
                .frame(width: DesignTokens.Layout.cockpitWidth)
            }
            .frame(height: DesignTokens.Layout.workspaceHeight)
            .overlay(alignment: .bottom) { ConsoleRule() }

            ConsoleAuditLedger(rows: controller.auditRows, isObserving: controller.isObserving)
                .frame(height: DesignTokens.Layout.auditHeight)
        }
        .frame(width: DesignTokens.Layout.width, height: DesignTokens.Layout.height)
        .font(DesignTokens.Font.body)
        .monospacedDigit()
        .foregroundStyle(DesignTokens.textReadout)
        .background(DesignTokens.pitchBlack)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1).allowsHitTesting(false) }
        .preferredColorScheme(.dark)
        // Button callbacks bind requests to the observing session synchronously.
        // Capture each request/controller by value before async execution, never
        // minting a request from whichever session happens to exist at task start.
        // Separate view-owned tasks keep abort independent of grant work. SwiftUI
        // cancels them on replacement/removal; the controller owns work settlement.
        // Actor awaits suspend rather than blocking rendering. Detached tasks would
        // discard this UI lifetime/isolation contract without making gate hops faster.
        .task(id: grantRequest?.id) { [request = grantRequest, controller] in
            guard !Task.isCancelled, let request else { return }
            await controller.perform(request)
        }
        .task(id: abortRequest?.id) { [request = abortRequest, controller] in
            guard !Task.isCancelled, let request else { return }
            await controller.perform(request)
        }
        .task(id: dumpRequest?.id) { [request = dumpRequest, controller] in
            guard !Task.isCancelled, let request else { return }
            await controller.perform(request)
        }
        .task(id: drawerToggleID) { [toggleID = drawerToggleID, controller] in
            guard !Task.isCancelled, toggleID != nil else { return }
            _ = await controller.toggleInspectorDrawer()
        }
    }
}

struct ConsoleGatePresentation {
    let status: InterlockStatus
    let isObserving: Bool

    var title: String {
        guard isObserving else { return "UNCONFIRMED" }
        switch status {
        case .locked: return "LOCKED"
        case .armed: return "ARMED"
        case .permissiveGranted: return "PERMISSIVE"
        case .emergencyAbort: return "ABORT"
        }
    }

    var color: Color {
        guard isObserving else { return DesignTokens.lockedSlate }
        switch status {
        case .locked: return DesignTokens.lockedSlate
        case .armed: return DesignTokens.amber
        case .permissiveGranted: return DesignTokens.green
        case .emergencyAbort: return DesignTokens.red
        }
    }

    var symbol: String {
        guard isObserving else { return "questionmark.square" }
        switch status {
        case .locked: return "lock.fill"
        case .armed: return "exclamationmark.triangle.fill"
        case .permissiveGranted: return "checkmark.shield.fill"
        case .emergencyAbort: return "xmark.octagon.fill"
        }
    }

    var visibleDetail: String {
        guard isObserving else { return "AUTHORITATIVE OBSERVATION PENDING" }
        switch status {
        case .locked: return "LOCKED // Interlock > Arm Gate [CMD-A]"
        case .armed: return "ARMED // GRANT OR ABORT AVAILABLE"
        case .permissiveGranted: return "PERMISSIVE // EXTERNAL EXECUTION NOT VERIFIED"
        case .emergencyAbort: return "ABORT ACTIVE // EXTERNAL TEARDOWN NOT VERIFIED"
        }
    }

    var detail: String {
        guard isObserving else { return "Awaiting authoritative gate observation." }
        switch status {
        case .locked: return "Gate locked. Choose Interlock > Arm Gate (Command-A)."
        case .armed: return "Gate armed. Operator grant or abort available."
        case .permissiveGranted: return "Gate permissive. External execution is not verified."
        case .emergencyAbort: return "Abort active. External teardown is not verified."
        }
    }

    var compactDetail: String {
        guard isObserving else { return "AUTHORITATIVE STATE // SYNC PENDING" }
        switch status {
        case .locked: return "GATE CLOSED // EXPLICIT ARM REQUIRED"
        case .armed: return "OPERATOR CLEARANCE // GATE STATE ONLY"
        case .permissiveGranted: return "GATE OPEN // EXECUTION NOT VERIFIED"
        case .emergencyAbort: return "GATE ABORT // TEARDOWN NOT VERIFIED"
        }
    }
}
