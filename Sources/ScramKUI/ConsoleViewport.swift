import SwiftUI
import ScramKCore
import ScramKVirtualization

@MainActor
struct ConsoleViewport: View {
    @ObservedObject var controller: ConsoleStateController

    var body: some View {
        let frame = ConsoleFramePresentation(snapshot: controller.frameSnapshot,
            isConfigured: controller.isFramebufferConfigured, isObserving: controller.isObserving)
        VStack(spacing: 0) {
            ConsoleViewportHeader(
                activeBay: controller.activeBay,
                bridgeState: BridgePresentation.connection(controller.bridgeConnectionState,
                    configured: controller.isBridgeConfigured, observing: controller.isObserving),
                frame: frame
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
                    ScramKMetalViewportContainer(
                        stateController: controller, framebufferClient: controller.framebufferClient
                    )
                    ConsoleViewportOverlay(
                        controller: controller,
                        frame: frame
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .frame(maxHeight: .infinity)

            ConsoleViewportFooter(frame: frame, transfer: controller.latestBridgeTransfer)
        }
        .background(DesignTokens.canvasDark)
        .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.slateBorder).frame(width: 1) }
    }
}

private struct ConsoleViewportHeader: View {
    let activeBay: String
    let bridgeState: String
    let frame: ConsoleFramePresentation

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DesignTokens.lockedSlate).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("CONTAINER VIEWPORT").font(DesignTokens.Font.mono(11, weight: "Bold"))
                .tracking(0.5)
            Text("[MCP: \(bridgeState)]").foregroundStyle(DesignTokens.textMuted)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if frame.isConfigured {
                    Text("FRAME: \(frame.stateLabel)").font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                    Text(frame.badge).font(DesignTokens.Font.mono(8))
                } else {
                    Text("[ FRAMEBUFFER: UNBOUND // MTKVIEW STATE ]").font(DesignTokens.Font.labelSm)
                }
            }
            .foregroundStyle(frame.isFailed ? DesignTokens.red : DesignTokens.textDim)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DesignTokens.railDark)
            .overlay { Rectangle().strokeBorder(DesignTokens.slateBorderLight, lineWidth: 1) }
        }
        .font(DesignTokens.Font.labelMd)
        .padding(.horizontal, 12)
        .background(DesignTokens.chromeDark)
        .overlay(alignment: .bottom) { ConsoleRule() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Container viewport, \(activeBay). MCP bridge \(bridgeState). \(frame.accessibilitySummary)")
        .accessibilityHint("The framebuffer source is separate from MCP. RFB None security does not authenticate the container. Source sRGB interpretation is assumed, not a verified ICC profile. Source updates and GPU draws are independent.")
    }
}

private struct ConsoleViewportFooter: View {
    let frame: ConsoleFramePresentation
    let transfer: BridgeTransferReceipt?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if frame.isConfigured {
                Text(frame.statisticsLabel).lineLimit(1).help(frame.statisticsLabel)
                HStack(spacing: 8) {
                    Text(frame.sourceLabel).foregroundStyle(DesignTokens.textDim)
                    Spacer(minLength: 0)
                    Text("SOURCE COUNTS ≠ GPU FPS")
                }
            } else {
                HStack(spacing: 14) {
                    Text(BridgePresentation.transfer(transfer))
                    Spacer(minLength: 4)
                    Text("FRAMEBUFFER: UNBOUND").font(DesignTokens.Font.labelSm)
                        .foregroundStyle(DesignTokens.textDim)
                }
            }
        }
        .font(DesignTokens.Font.mono(8))
        .monospacedDigit()
        .foregroundStyle(DesignTokens.textMuted)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(DesignTokens.chromeDark)
        .overlay(alignment: .top) { ConsoleRule() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Viewport source measurements")
        .accessibilityValue(frame.isConfigured ? frame.accessibilitySummary : BridgePresentation.transfer(transfer) + ". Framebuffer unbound.")
        .accessibilityHint("RX excludes HTTP and WebSocket framing and control bytes. SAME counts no-change source updates. REPLACED counts overwritten frame deliveries, not all dropped frames. No measured VSYNC or presentation-rate claim.")
    }
}

private struct ConsoleViewportOverlay: View {
    @ObservedObject var controller: ConsoleStateController
    let frame: ConsoleFramePresentation

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(controller.activeBay) // \(ConsoleBay(rawValue: controller.activeBay)?.title ?? "UNBOUND BAY")")
                    .font(DesignTokens.Font.labelSm)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Text("AXES: REFERENCE // NOT SOURCE PX").font(DesignTokens.Font.mono(8))
            }
            .foregroundStyle(DesignTokens.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 12) {
                if controller.activeBay == ConsoleBay.overview.rawValue {
                    ConsoleInterceptCard(status: controller.currentStatus, isObserving: controller.isObserving,
                        bridgeSnapshot: controller.bridgeSnapshot, isBridgeConfigured: controller.isBridgeConfigured, frame: frame)
                        .frame(maxWidth: 650)
                } else {
                    ConsoleBayDetailCard(bay: ConsoleBay(rawValue: controller.activeBay), controller: controller)
                        .frame(maxWidth: 650)
                }
                // One reference target illustration, separate from the renderer's
                // categorical state glyph at the bottom-right of the drawable.
                ConsoleReferenceReticle().frame(width: 112)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
            HStack {
                Text(frame.isConfigured ? frame.badge : "NATIVE STATE GEOMETRY // FRAMEBUFFER UNBOUND")
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
    let frame: ConsoleFramePresentation

    var body: some View {
        let presentation = ConsoleGatePresentation(status: status, isObserving: isObserving)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Rectangle().fill(presentation.color).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("MCP BRIDGE: \(BridgePresentation.connection(bridgeSnapshot?.connectionState ?? .detached, configured: isBridgeConfigured, observing: isObserving))")
                    .foregroundStyle(DesignTokens.textDim)
                Spacer(minLength: 0)
                Text("DISPLAY: \(frame.stateLabel)").foregroundStyle(frame.isFailed ? DesignTokens.red : DesignTokens.textMuted)
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
                    if let diagnostic = frame.diagnostic {
                        Text("FRAME FAILURE: \(diagnostic)").foregroundStyle(DesignTokens.red)
                    }
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

private struct ConsoleBayDetailCard: View {
    let bay: ConsoleBay?
    @ObservedObject var controller: ConsoleStateController

    var body: some View {
        switch bay {
        case .network:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BAY-02 // NETWORK DEFENSE (CONTAINMENT)")
                        .font(DesignTokens.Font.mono(11, weight: "Bold"))
                    Spacer()
                    Text("STATUS: \(controller.bridgeSnapshot?.connectionState.rawValue.uppercased() ?? "DETACHED")")
                        .font(DesignTokens.Font.mono(9, weight: "SemiBold"))
                        .foregroundStyle(controller.isBridgeConfigured && controller.bridgeSnapshot?.connectionState == .attached ? DesignTokens.green : DesignTokens.textDim)
                }
                ConsoleRule()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("BRIDGE ENDPOINT:").foregroundStyle(DesignTokens.textMuted)
                        Text("unix://~/.docker/run/docker.sock").monospacedDigit()
                    }
                    HStack {
                        Text("FRAMEBUFFER LOOPBACK:").foregroundStyle(DesignTokens.textMuted)
                        Text("127.0.0.1:7860/websockify (BSD TCP Raw)").monospacedDigit()
                    }
                    HStack {
                        Text("SANDBOX ISOLATION:").foregroundStyle(DesignTokens.textMuted)
                        Text("Zero-Trust Stdio Framing + 16KiB Bounded Chunking")
                    }
                    HStack {
                        Text("OUTBOUND BYTES:").foregroundStyle(DesignTokens.textMuted)
                        Text(controller.bridgeSnapshot?.latestTransfer.map { "\($0.bytesWritten) B (\($0.writeChunks) chunks)" } ?? "--").monospacedDigit()
                    }
                }
                .font(DesignTokens.Font.mono(9))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.cardSlip)
            .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }

        case .avionics:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BAY-03 // AVIONICS KINEMATICS & SVS")
                        .font(DesignTokens.Font.mono(11, weight: "Bold"))
                    Spacer()
                    Text("AUDIO SVS: \(controller.audioStatusLabel)")
                        .font(DesignTokens.Font.mono(9, weight: "SemiBold"))
                        .foregroundStyle(controller.audioStatusColorName == "green" ? DesignTokens.green : (controller.audioStatusColorName == "amber" ? DesignTokens.amber : DesignTokens.textMuted))
                }
                ConsoleRule()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("REAL-TIME ENGINE:").foregroundStyle(DesignTokens.textMuted)
                        Text("AVAudioEngine + AVAudioSourceNode (MRC Native Block, Zero ARC)")
                    }
                    HStack {
                        Text("LOCK-FREE QUEUE:").foregroundStyle(DesignTokens.textMuted)
                        Text("C11 SPSC Ring Buffer + Atomic Mailbox Preemption")
                    }
                    HStack {
                        Text("SYNTHESIS PROFILE:").foregroundStyle(DesignTokens.textMuted)
                        Text("440Hz Sine / 880Hz Sine / 1200Hz Saw / 660-880Hz Harmonic Pulses")
                    }
                    HStack {
                        Text("MASTER ATTENUATION:").foregroundStyle(DesignTokens.textMuted)
                        Text("-24.0 dBFS (5 ms Linear Endpoint Fades)").monospacedDigit()
                    }
                }
                .font(DesignTokens.Font.mono(9))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.cardSlip)
            .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }

        case .threats:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BAY-04 // THREAT VECTOR MATRIX")
                        .font(DesignTokens.Font.mono(11, weight: "Bold"))
                    Spacer()
                    Text("INTERCEPT: ACTIVE")
                        .font(DesignTokens.Font.mono(9, weight: "SemiBold"))
                        .foregroundStyle(DesignTokens.amber)
                }
                ConsoleRule()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("GATED PRIVILEGED TOOLS:").foregroundStyle(DesignTokens.textMuted)
                        Text("screenenv.bash_execute, screenenv.file_write, etc.")
                    }
                    HStack {
                        Text("CLEARANCE LEASE:").foregroundStyle(DesignTokens.textMuted)
                        Text("One-Shot Execution Lease; Auto-Relock On Wire Completion")
                    }
                    HStack {
                        Text("WIRE VERIFICATION:").foregroundStyle(DesignTokens.textMuted)
                        Text("Immutable SHA-256 Frame Fingerprint Validation")
                    }
                    HStack {
                        Text("PROCESS PROVENANCE:").foregroundStyle(DesignTokens.textMuted)
                        Text("App-Owned Local Dispatch; Zero Foreign Ingress")
                    }
                }
                .font(DesignTokens.Font.mono(9))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.cardSlip)
            .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }

        case .orchestration:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BAY-05 // CORE ORCHESTRATION")
                        .font(DesignTokens.Font.mono(11, weight: "Bold"))
                    Spacer()
                    Text("INTERLOCK: \(controller.currentStatus.rawValue)")
                        .font(DesignTokens.Font.mono(9, weight: "SemiBold"))
                        .foregroundStyle(controller.currentStatus == .permissiveGranted ? DesignTokens.green : (controller.currentStatus == .armed ? DesignTokens.amber : (controller.currentStatus == .emergencyAbort ? DesignTokens.red : DesignTokens.lockedSlate)))
                }
                ConsoleRule()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("SAFETY ACTOR:").foregroundStyle(DesignTokens.textMuted)
                        Text("HardwareInterlockGate (Actor-Isolated, Sendable)")
                    }
                    HStack {
                        Text("SYNCHRONIZATION:").foregroundStyle(DesignTokens.textMuted)
                        Text("OSAllocatedUnfairLock Protected Waiters & Stream Observation")
                    }
                    HStack {
                        Text("MEMORY USAGE:").foregroundStyle(DesignTokens.textMuted)
                        Text("Resident Set Size: \(controller.residentMemoryMB)").monospacedDigit()
                    }
                    HStack {
                        Text("TRANSITION RECOVERY:").foregroundStyle(DesignTokens.textMuted)
                        Text("Strict Recovery Ladder: .emergencyAbort -> .locked Only")
                    }
                }
                .font(DesignTokens.Font.mono(9))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.cardSlip)
            .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }

        case .overview, nil:
            ConsoleUnboundBayCard(bay: bay)
        }
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
