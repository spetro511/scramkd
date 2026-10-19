import SwiftUI
import TacticalCore
import TacticalVirtualization

@MainActor
struct ConsoleViewport: View {
    @ObservedObject var controller: ConsoleStateController

    var body: some View {
        VStack(spacing: 0) {
            ConsoleViewportHeader(
                activeBay: controller.activeBay,
                bridgeState: BridgePresentation.connection(controller.bridgeConnectionState,
                    configured: controller.isBridgeConfigured, observing: controller.isObserving)
            )
                .frame(height: 32)
            HStack(spacing: 0) {
                ForEach(0..<11) { tick in
                    Text(String(format: "%04d", tick * 128))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
            }
            .font(DesignTokens.Font.mono(8))
            .foregroundStyle(DesignTokens.lockedSlate)
            .padding(.horizontal, 12)
            .frame(height: 20)
            .background(DesignTokens.railDark)
            .overlay(alignment: .bottom) { ConsoleRule(color: DesignTokens.slateBorder.opacity(0.7)) }
            // Reference ruler is above, not painted into, the native drawable.
            .zIndex(1)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<6) { tick in
                        Text(String(format: "%03d", tick * 120))
                            .monospacedDigit()
                            .frame(maxHeight: .infinity, alignment: tick == 0 ? .top : (tick == 5 ? .bottom : .center))
                    }
                }
                .font(DesignTokens.Font.mono(8))
                .foregroundStyle(DesignTokens.lockedSlate)
                .padding(.vertical, 24)
                .frame(width: 28)
                .background(DesignTokens.railDark)
                .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.slateBorder.opacity(0.7)).frame(width: 1) }
                .accessibilityHidden(true)

                ZStack {
                    TacticalMetalViewportContainer(stateController: controller)
                    ConsoleViewportOverlay(
                        status: controller.currentStatus,
                        isObserving: controller.isObserving,
                        activeBay: controller.activeBay,
                        bridgeSnapshot: controller.bridgeSnapshot,
                        isBridgeConfigured: controller.isBridgeConfigured
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 14) {
                Text(BridgePresentation.transfer(controller.latestBridgeTransfer)).monospacedDigit()
                Spacer(minLength: 4)
                Text("FRAMEBUFFER: UNBOUND").font(DesignTokens.Font.labelSm)
                    .foregroundStyle(DesignTokens.textDim)
            }
            .font(DesignTokens.Font.mono(8))
            .foregroundStyle(DesignTokens.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(DesignTokens.chromeDark)
            .overlay(alignment: .top) { ConsoleRule() }
            .accessibilityElement(children: .combine)
        }
        .background(DesignTokens.canvasDark)
        .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.slateBorder).frame(width: 1) }
    }
}

private struct ConsoleViewportHeader: View {
    let activeBay: String
    let bridgeState: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DesignTokens.lockedSlate).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("CONTAINER VIEWPORT").font(DesignTokens.Font.mono(11, weight: "Bold"))
                .tracking(0.5)
            Text("[MCP: \(bridgeState)]").foregroundStyle(DesignTokens.textMuted)
            Spacer(minLength: 4)
            Text("[ FRAMEBUFFER: UNBOUND // MTKVIEW STATE ]")
                .font(DesignTokens.Font.labelSm)
                .foregroundStyle(DesignTokens.textDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(DesignTokens.railDark)
                .overlay { Rectangle().strokeBorder(DesignTokens.slateBorderLight, lineWidth: 1) }
        }
        .font(DesignTokens.Font.labelMd)
        .padding(.horizontal, 12)
        .background(DesignTokens.chromeDark)
        .overlay(alignment: .bottom) { ConsoleRule() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Container viewport, \(activeBay). MCP bridge \(bridgeState). Framebuffer unbound; native gate-state visualization only. Bridge attachment is not a guest display or containment proof.")
    }
}

private struct ConsoleViewportOverlay: View {
    let status: InterlockStatus
    let isObserving: Bool
    let activeBay: String
    let bridgeSnapshot: BridgeSnapshot?
    let isBridgeConfigured: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(activeBay) // \(ConsoleBay(rawValue: activeBay)?.title ?? "UNBOUND BAY")")
                    .font(DesignTokens.Font.labelSm)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Text("COORDINATES: REFERENCE").font(DesignTokens.Font.mono(8))
            }
            .foregroundStyle(DesignTokens.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 12) {
                if activeBay == ConsoleBay.overview.rawValue {
                    ConsoleInterceptCard(status: status, isObserving: isObserving,
                        bridgeSnapshot: bridgeSnapshot, isBridgeConfigured: isBridgeConfigured)
                        .frame(maxWidth: 650)
                } else {
                    ConsoleUnboundBayCard(bay: ConsoleBay(rawValue: activeBay))
                        .frame(maxWidth: 650)
                }
                // One reference target illustration, separate from the renderer's
                // categorical state glyph at the bottom-right of the drawable.
                ConsoleReferenceReticle().frame(width: 112)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
            HStack {
                Text("NATIVE STATE GEOMETRY // FRAMEBUFFER UNBOUND")
                    .font(DesignTokens.Font.mono(8))
                    .foregroundStyle(DesignTokens.textMuted)
                Spacer(minLength: 0)
                Text("[GATE STATE]")
                    .font(DesignTokens.Font.mono(8))
                    .foregroundStyle(DesignTokens.textMuted)
                    .frame(width: 64)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

private struct ConsoleInterceptCard: View {
    let status: InterlockStatus
    let isObserving: Bool
    let bridgeSnapshot: BridgeSnapshot?
    let isBridgeConfigured: Bool

    var body: some View {
        let presentation = ConsoleGatePresentation(status: status, isObserving: isObserving)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Rectangle().fill(presentation.color).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("MCP BRIDGE: \(BridgePresentation.connection(bridgeSnapshot?.connectionState ?? .detached, configured: isBridgeConfigured, observing: isObserving))")
                    .foregroundStyle(DesignTokens.textDim)
                Spacer(minLength: 0)
                Text("DISPLAY: UNBOUND").foregroundStyle(DesignTokens.textMuted)
                    .font(DesignTokens.Font.labelSm)
            }
            .font(DesignTokens.Font.labelMd)
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(DesignTokens.panelDark)
            .overlay(alignment: .bottom) { ConsoleRule() }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bridgeSnapshot?.serverInfo.map {
                        "SERVER ADVERTISED: \(BridgeDisplayText.escaped($0.advertisedName, limit: 28)) // \(BridgeDisplayText.escaped($0.advertisedVersion, limit: 16))"
                    } ?? "SERVER ADVERTISED: UNBOUND")
                    Text(bridgeSnapshot?.serverInfo.map {
                        "MCP PROTOCOL: \(BridgeDisplayText.escaped($0.protocolVersion, limit: 24)) // IDENTITY: NOT VERIFIED"
                    } ?? "MCP PROTOCOL: UNBOUND // PEER IDENTITY: UNKNOWN")
                }
                .font(DesignTokens.Font.mono(8))
                .foregroundStyle(DesignTokens.textDim)
                .lineLimit(2)
                .accessibilityHint("Server name, version, and protocol are advertised values, not authenticated identity.")
                Text("REFERENCE // NOT EXECUTED")
                    .font(DesignTokens.Font.labelSm)
                    .tracking(0.8)
                    .foregroundStyle(DesignTokens.textMuted)
                Text("$ ./detonate_sample.sh --isolated --quarantine-net")
                    .font(DesignTokens.Font.mono(11, weight: "SemiBold"))
                    .foregroundStyle(DesignTokens.textDim)
                    .textSelection(.enabled)
                    .accessibilityLabel("Reference command only. Not executed. detonate sample dot sh, isolated, quarantine net.")
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("[MOSDEF-GATE] \(presentation.title)")
                            .font(DesignTokens.Font.mono(10, weight: "Bold"))
                            .tracking(0.5)
                        Spacer(minLength: 0)
                        Text("GATE STATE ONLY")
                            .font(DesignTokens.Font.mono(9, weight: "ExtraBold"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(presentation.color.opacity(0.15))
                    }
                    .foregroundStyle(presentation.color)
                    ConsoleRule(color: presentation.color.opacity(0.3))
                    Text(isBridgeConfigured
                         ? BridgePresentation.gateDetail(status: status, phase: bridgeSnapshot?.pendingIntercept?.phase, observing: isObserving)
                         : presentation.visibleDetail)
                        .font(DesignTokens.Font.labelMd)
                        .foregroundStyle(DesignTokens.textReadout)
                    Text("INSTRUCTION POINTER: UNBOUND | SYSCALL: UNBOUND | KERNEL HOOK: NOT CONNECTED")
                        .font(DesignTokens.Font.labelSm)
                        .foregroundStyle(DesignTokens.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if isBridgeConfigured {
                        Text("MCP INTERCEPT: \(BridgePresentation.phase(bridgeSnapshot?.pendingIntercept?.phase))")
                            .font(DesignTokens.Font.labelSm)
                            .foregroundStyle(DesignTokens.textDim)
                    }
                }
                .padding(10)
                .background(presentation.color.opacity(0.07))
                .overlay { Rectangle().strokeBorder(presentation.color, lineWidth: 1) }
                .accessibilityElement(children: .combine)
                HStack(alignment: .top, spacing: 7) {
                    Text(">>>").foregroundStyle(presentation.color)
                        .font(DesignTokens.Font.mono(10, weight: "Bold"))
                    Text(!isObserving ? "OBSERVATION PENDING // NO COMMAND"
                         : (isBridgeConfigured ? "APP-ONLY BOUNDARY // FULL WRITE RELOCKS CORE" : "\(presentation.compactDetail) // \(ConsoleBay.overview.rawValue)"))
                        .font(DesignTokens.Font.labelSm)
                        .foregroundStyle(DesignTokens.textDim)
                    Spacer(minLength: 0)
                    Rectangle().fill(presentation.color).frame(width: 7, height: 13)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
        }
        .background(DesignTokens.canvasDark)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }
    }
}

private struct ConsoleUnboundBayCard: View {
    let bay: ConsoleBay?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(bay?.rawValue ?? "UNBOUND") // \(bay?.title ?? "UNKNOWN BAY")")
                .font(DesignTokens.Font.mono(11, weight: "Bold"))
            ConsoleRule()
            Text("TELEMETRY SOURCE: NOT CONNECTED")
                .font(DesignTokens.Font.labelMd)
                .foregroundStyle(DesignTokens.textDim)
            Text("NO LIVE \(sourceName.uppercased()) FEED // NOT CONNECTED")
                .font(DesignTokens.Font.body)
                .foregroundStyle(DesignTokens.textMuted)
            Text("MEASUREMENTS: -- // TRANSPORT: UNBOUND")
                .font(DesignTokens.Font.labelSm)
                .foregroundStyle(DesignTokens.textDim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.cardSlip)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private var sourceName: String {
        switch bay {
        case .network: "network"
        case .avionics: "kinematics"
        case .threats: "threat-vector"
        case .orchestration: "orchestration"
        case .overview, nil: "external"
        }
    }
}

private struct ConsoleReferenceReticle: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("REFERENCE")
                .font(DesignTokens.Font.mono(8, weight: "ExtraBold"))
                .tracking(0.8)
                .foregroundStyle(DesignTokens.amber)
            ZStack {
                Rectangle().strokeBorder(DesignTokens.amber, lineWidth: 1)
                Rectangle().fill(DesignTokens.amber.opacity(0.7)).frame(width: 1)
                Rectangle().fill(DesignTokens.amber.opacity(0.7)).frame(height: 1)
                Rectangle().fill(DesignTokens.amber.opacity(0.2)).frame(width: 12, height: 12)
                Rectangle().strokeBorder(DesignTokens.amber, lineWidth: 1).frame(width: 12, height: 12)
                ConsoleReticleCornerTicks().stroke(DesignTokens.amber, lineWidth: 1)
            }
            .frame(width: 64, height: 64)
            Text("[TRGT // 0x89C]")
                .font(DesignTokens.Font.mono(8, weight: "Bold"))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.amber)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(DesignTokens.pitchBlack)
                .overlay { Rectangle().strokeBorder(DesignTokens.amber, lineWidth: 1) }
            Text("NO LIVE TARGET")
                .font(DesignTokens.Font.mono(8))
                .foregroundStyle(DesignTokens.textMuted)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reference reticle. Target identifier 0x89C is reference artwork only. No live target.")
    }
}

private struct ConsoleReticleCornerTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for point in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ] {
            path.move(to: CGPoint(x: point.x - 3, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 3, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - 3))
            path.addLine(to: CGPoint(x: point.x, y: point.y + 3))
        }
        return path
    }
}
