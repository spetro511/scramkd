import SwiftUI

/// Native state drawable beneath SwiftUI's target labels and ruler overlays.
@MainActor
public struct TacticalMetalViewportContainer: NSViewRepresentable {
    @ObservedObject private var stateController: ConsoleStateController
    @Environment(\.colorSchemeContrast) private var contrast

    public init(stateController: ConsoleStateController) {
        self.stateController = stateController
    }

    public func makeNSView(context: Context) -> TacticalMetalViewportView {
        let view = TacticalMetalViewportView()
        updatePresentation(view)
        return view
    }

    public func updateNSView(_ nsView: TacticalMetalViewportView, context: Context) {
        updatePresentation(nsView)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TacticalMetalViewportView, context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 200
        return CGSize(width: max(320, width), height: max(200, height))
    }

    public static func dismantleNSView(_ nsView: TacticalMetalViewportView, coordinator: ()) {
        nsView.shutdown()
    }

    private func updatePresentation(_ view: TacticalMetalViewportView) {
        view.updateInterlockStatus(stateController.currentStatus, isObserving: stateController.isObserving)
        view.viewportRenderer.updateIncreasedContrast(contrast == .increased)
    }
}
