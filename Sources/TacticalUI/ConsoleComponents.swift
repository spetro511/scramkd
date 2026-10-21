import SwiftUI
import TacticalCore
import TacticalVirtualization

struct ConsoleRule: View {
    var color: Color = DesignTokens.slateBorder
    var body: some View {
        Rectangle().fill(color).frame(height: 1).accessibilityHidden(true)
    }
}

/// Uses native Button semantics; adds an orthogonal, immediate focus/press treatment.
struct ConsoleButtonStyle: ButtonStyle {
    var fill: Color = DesignTokens.railDark
    var ink: Color = DesignTokens.textDim
    var border: Color = DesignTokens.slateBorder
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        ConsoleButtonSurface(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            fill: fill,
            ink: ink,
            border: contrast == .increased ? DesignTokens.textDim : border
        )
    }
}

private struct ConsoleButtonSurface<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isEnabled: Bool
    let fill: Color
    let ink: Color
    let border: Color
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        label
            .foregroundStyle(isEnabled ? ink : DesignTokens.textDim)
            .background(isEnabled ? fill : DesignTokens.panelDark)
            .overlay {
                Rectangle().fill(Color.white.opacity(isPressed && isEnabled ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                Rectangle().strokeBorder(
                    isFocused ? DesignTokens.textReadout : border,
                    lineWidth: isFocused ? 2 : 1
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
    }
}

struct ConsoleKeycap: View {
    let key: String
    var color: Color = DesignTokens.textReadout

    var body: some View {
        Text("[ \(key) ]")
            .font(DesignTokens.Font.keycap)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DesignTokens.pitchBlack)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(0.5), lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .accessibilityHidden(true)
    }
}

struct ConsoleReadout: View {
    let label: String
    let value: String
    var color: Color = DesignTokens.textReadout

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(DesignTokens.textMuted)
            Text(value).foregroundStyle(color).font(DesignTokens.Font.labelMd).monospacedDigit()
        }
        .font(DesignTokens.Font.labelSm)
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(DesignTokens.railDark)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Coarse, read-only UI projection. No image bytes, client subscriptions, timers,
/// transport side effects, or assumptions that RFB initialization means pixels.
struct ConsoleFramePresentation {
    let snapshot: FrameSnapshot?
    let isConfigured: Bool
    let isObserving: Bool

    var hasReceivedFrame: Bool {
        guard isConfigured, isObserving, let snapshot,
              snapshot.state == .connected, snapshot.failure == nil,
              snapshot.generation != nil, snapshot.lastFrameAt != nil else { return false }
        return validDimensions != nil
    }

    var isFailed: Bool {
        isConfigured && isObserving && (snapshot?.state == .failed || snapshot?.failure != nil)
    }

    var stateLabel: String {
        guard isConfigured else { return "UNBOUND" }
        guard isObserving else { return "UNOBSERVED" }
        guard let snapshot else { return "DETACHED" }
        guard !isFailed else { return "FAILED" }
        switch snapshot.state {
        case .connected: return hasReceivedFrame ? "STREAMING" : "AWAITING FRAME"
        case .connecting: return "CONNECTING"
        case .negotiating: return "NEGOTIATING"
        case .disconnecting: return "DISCONNECTING"
        case .detached: return "DETACHED"
        case .failed: return "FAILED"
        }
    }

    var badge: String {
        guard isConfigured else { return "[FRAMEBUFFER UNBOUND]" }
        return hasReceivedFrame ? "[READ-ONLY SOURCE // FRAME RECEIVED]" : "[STANDBY // CONTAINER DETACHED]"
    }

    var sourceLabel: String {
        guard isConfigured, isObserving, snapshot?.state == .connected, !isFailed,
              let dimensions = validDimensions else { return "SOURCE PX: -- // PROFILE: UNBOUND" }
        let size = "\(dimensions.width)×\(dimensions.height)"
        return hasReceivedFrame ? "SOURCE: \(size) PX // ASSUMED sRGB" : "RFB SIZE: \(size) // AWAITING PIXELS"
    }

    var statisticsLabel: String {
        guard isConfigured, isObserving, let stats = snapshot?.statistics else {
            return "RX: -- B / -- MSG // UPDATES: -- // SAME: -- // SRC: -- // REPLACED: --"
        }
        return "RX: \(stats.receivedBinaryPayloadBytes) B / \(stats.receivedBinaryMessages) MSG // UPDATES: \(stats.completedUpdates) // SAME: \(stats.noChangeUpdates) // SRC: \(stats.publishedFrames) // REPLACED: \(stats.replacedFrameDeliveries)"
    }

    var diagnostic: String? {
        guard isConfigured, isObserving, let failure = snapshot?.failure else { return nil }
        let label: String
        switch failure {
        case .busy: label = "BUSY"
        case .staleGeneration: label = "STALE GENERATION"
        case .cancelled: label = "CANCELLED"
        case .endOfStream: label = "END OF STREAM"
        case .transportFailure: label = "TRANSPORT FAILURE"
        case .timedOut(let stage): label = "TIMEOUT // \(stage.rawValue.uppercased())"
        case .systemCall(let code): label = "SYSTEM CALL // CODE \(code)"
        case .randomUnavailable: label = "RANDOM SOURCE UNAVAILABLE"
        case .httpRejected(let status): label = "HTTP REJECTED // STATUS \(status)"
        case .protocolViolation(let violation): label = "PROTOCOL // \(violation.rawValue.uppercased())"
        case .unsupportedVersion: label = "UNSUPPORTED RFB VERSION"
        case .unsupportedSecurity: label = "UNSUPPORTED RFB SECURITY"
        case .securityRejected: label = "RFB SECURITY REJECTED"
        case .unsupportedEncoding(let encoding): label = "UNSUPPORTED ENCODING // \(encoding)"
        case .limitExceeded(let limit): label = "LIMIT EXCEEDED // \(limit.rawValue.uppercased())"
        }
        // Enumerated categories and numeric codes only; never stringify a raw
        // error, server name, endpoint, clipboard content, or source pixels.
        return BridgeDisplayText.escaped(label, limit: 96)
    }

    var accessibilitySummary: String {
        "Framebuffer \(stateLabel). \(sourceLabel). \(statisticsLabel). \(diagnostic.map { "Failure: \($0)." } ?? "") Source counts are received binary payloads and published source frames, not GPU presentation FPS or proof of container identity. Replaced deliveries are not a total dropped-frame metric. No guest input forwarding."
    }

    private var validDimensions: (width: Int, height: Int)? {
        guard let width = snapshot?.width, let height = snapshot?.height,
              width > 0, width <= 4096, height > 0, height <= 4096 else { return nil }
        return (width, height)
    }
}

struct ConsoleWindowChromeBar: View {
    let status: InterlockStatus
    let isObserving: Bool
    let countdownTTL: String
    let bridgeSnapshot: BridgeSnapshot?
    let isBridgeConfigured: Bool

    var body: some View {
        let presentation = ConsoleGatePresentation(status: status, isObserving: isObserving)
        HStack(spacing: 12) {
            // Real traffic lights and drag behavior belong to the app/window owner.
            Color.clear.frame(width: DesignTokens.Layout.nativeControlsReserve).accessibilityHidden(true)
            Rectangle().fill(DesignTokens.slateBorder).frame(width: 1, height: 16)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text("HYPERVISOR//V4.2")
                    .foregroundStyle(DesignTokens.green)
                    .font(DesignTokens.Font.mono(12, weight: "Bold"))
                    .tracking(0.6)
                Text("[NODE: UNBOUND]").foregroundStyle(DesignTokens.textMuted)
                    .font(DesignTokens.Font.labelMd)
            }
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                ConsoleReadout(label: "FREQ:", value: "--")
                ConsoleReadout(label: "IOPS:", value: "--")
                ConsoleReadout(label: "GATE:", value: presentation.title, color: presentation.color)
                ConsoleReadout(label: "MCP:", value: BridgePresentation.connection(
                    bridgeSnapshot?.connectionState ?? .detached,
                    configured: isBridgeConfigured, observing: isObserving
                ))
                ConsoleReadout(label: "MEM:", value: "--")
            }
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                Image(systemName: presentation.symbol).accessibilityHidden(true)
                Text("[ GATE INTERLOCK: \(presentation.title) // TTL: \(countdownTTL) ]")
                    .monospacedDigit()
            }
            .font(DesignTokens.Font.mono(10, weight: "ExtraBold"))
            .foregroundStyle(status == .locked || !isObserving ? DesignTokens.textReadout : DesignTokens.pitchBlack)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(presentation.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gate interlock")
            .accessibilityValue("\(isObserving ? status.rawValue : "Unconfirmed"), TTL \(countdownTTL)")
        }
        .padding(.trailing, 16)
        .background(DesignTokens.chromeDark)
        .overlay(alignment: .bottom) { ConsoleRule() }
    }
}

enum ConsoleBay: String, CaseIterable, Identifiable {
    case overview = "BAY-01"
    case network = "BAY-02"
    case avionics = "BAY-03"
    case threats = "BAY-04"
    case orchestration = "BAY-05"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "TACTICAL OVERVIEW"
        case .network: "NETWORK DEFENSE"
        case .avionics: "AVIONICS KINEMATICS"
        case .threats: "THREAT VECTOR MATRIX"
        case .orchestration: "CORE ORCHESTRATION"
        }
    }
}

struct ConsoleNavigationRail: View {
    @Binding var activeBay: String
    let bridgeSnapshot: BridgeSnapshot?
    let isBridgeConfigured: Bool
    let isObserving: Bool
    let frameSnapshot: FrameSnapshot?
    let isFramebufferConfigured: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TELEMETRY BAYS").font(DesignTokens.Font.labelSm).tracking(0.8)
                Spacer(minLength: 0)
                Rectangle().fill(DesignTokens.textMuted).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DesignTokens.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(DesignTokens.canvasDark)
            .overlay(alignment: .bottom) { ConsoleRule() }
            VStack(spacing: 0) {
                ForEach(ConsoleBay.allCases) { bay in
                    ConsoleBayButton(bay: bay, isSelected: activeBay == bay.rawValue) {
                        activeBay = bay.rawValue
                    }
                }
            }
            .padding(.top, 4)
            .focusSection()
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                Text("BRIDGE TRANSPORT").font(DesignTokens.Font.labelSm).tracking(0.7)
                    .foregroundStyle(DesignTokens.textMuted)
                Text("MCP: \(BridgePresentation.connection(bridgeSnapshot?.connectionState ?? .detached, configured: isBridgeConfigured, observing: isObserving))")
                    .font(DesignTokens.Font.labelMd)
                HStack {
                    Text("PIPE OUT:")
                    Spacer(minLength: 0)
                    Text(bridgeSnapshot?.latestTransfer.map { "\($0.bytesWritten) B" } ?? "--").monospacedDigit()
                }
                .font(DesignTokens.Font.labelMd)
                Text(bridgeSnapshot?.latestTransfer.map { "WRITE CHUNKS: \($0.writeChunks)" } ?? "WRITE CHUNKS: --")
                    .font(DesignTokens.Font.labelSm).monospacedDigit()
                Text(isFramebufferConfigured
                     ? "FRAME: \(ConsoleFramePresentation(snapshot: frameSnapshot, isConfigured: true, isObserving: isObserving).stateLabel)"
                     : "FRAMEBUFFER: UNBOUND")
                    .font(DesignTokens.Font.mono(8))
                Rectangle().fill(DesignTokens.slateBorder).frame(height: 3)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DesignTokens.textDim)
            .padding(10)
            .background(DesignTokens.canvasDark)
            .overlay(alignment: .top) { ConsoleRule() }
            .accessibilityElement(children: .combine)
        }
        .background(DesignTokens.railDark)
        .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.slateBorder).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Telemetry bays")
    }
}

private struct ConsoleBayButton: View {
    let bay: ConsoleBay
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bay.rawValue).font(DesignTokens.Font.labelSm).monospacedDigit()
                    .foregroundStyle(isSelected ? DesignTokens.textDim : DesignTokens.textMuted)
                Text(bay.title).font(DesignTokens.Font.mono(9, weight: isSelected ? "Bold" : "Regular"))
                    .tracking(0.35)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .buttonStyle(ConsoleButtonStyle(
            fill: isSelected ? DesignTokens.green.opacity(0.12) : DesignTokens.railDark,
            ink: isSelected ? DesignTokens.green : DesignTokens.textDim,
            border: isSelected ? DesignTokens.green.opacity(0.3) : .clear
        ))
        .overlay(alignment: .leading) {
            Rectangle().fill(isSelected ? DesignTokens.green : .clear).frame(width: 2)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("\(bay.rawValue), \(bay.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(bay == .overview ? "Shows gate overview" : "Telemetry source not connected")
    }
}
