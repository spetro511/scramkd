import SwiftUI
import TacticalCore
import TacticalVirtualization

struct ConsoleSafetyCockpit: View {
    let status: InterlockStatus
    let isObserving: Bool
    let countdownTTL: String
    let lastCommandResult: String
    let bridgeSnapshot: BridgeSnapshot?
    let isBridgeConfigured: Bool
    let grant: () -> Void
    let abort: () -> Void
    let airgap: () -> Void
    @StateObject private var payload = BridgePayloadPresentationModel()
    @State private var inspectionSelection: BridgeInspectionSelection?

    private var pending: PendingIntercept? { bridgeSnapshot?.pendingIntercept }
    private var document: BridgePayloadInspection? { payload.document(for: pending?.approval) }
    private var canGrant: Bool {
        BridgePresentation.canGrant(
            status: status, isObserving: isObserving, isConfigured: isBridgeConfigured,
            connection: bridgeSnapshot?.connectionState ?? .detached, phase: pending?.phase
        ) && (!isBridgeConfigured || (
            document?.issue == nil && document != nil
            && pending?.approval.connectionGeneration == bridgeSnapshot?.generation
        ))
    }

    private var grantHint: String {
        if !isBridgeConfigured {
            return "Legacy gate-only mode. Grants all Core waiters only while armed. Interlock > Arm Gate, Command-A."
        }
        return "Requires an attached bridge, the current inspected request awaiting approval, and armed Core. Captures this request at click time. Full frame write returns Core to locked. Not session-wide clearance. Interlock > Arm Gate, Command-A; grant with Space or Shift-Command-G."
    }

    var body: some View {
        VStack(spacing: 10) {
            ConsoleGateStatusCard(status: status, isObserving: isObserving, countdownTTL: countdownTTL,
                                  isBridgeConfigured: isBridgeConfigured)
            if isBridgeConfigured {
                ConsoleBridgeClearanceSlip(
                    snapshot: bridgeSnapshot, isObserving: isObserving, document: document,
                    inspect: {
                        guard let pending, let document else { return }
                        inspectionSelection = BridgeInspectionSelection(pending: pending, document: document)
                    }
                )
            } else {
                ConsoleClearanceSlip(status: status, isObserving: isObserving)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("COMMAND RESULT").font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                    .tracking(0.8).foregroundStyle(DesignTokens.textMuted)
                Text(lastCommandResult.isEmpty ? "NO OPERATOR COMMAND ISSUED" : BridgeDisplayText.escaped(lastCommandResult, limit: 512))
                    .font(DesignTokens.Font.labelSm)
                    .foregroundStyle(DesignTokens.textDim)
                    .lineLimit(2)
                    .help(BridgeDisplayText.escaped(lastCommandResult, limit: 2048))
                    .textSelection(.enabled)
                    .accessibilityValue(lastCommandResult.isEmpty ? "No operator command issued" : BridgeDisplayText.escaped(lastCommandResult, limit: 2048))
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button(action: grant) {
                    ConsoleActionLabel(
                        title: "[ GRANT PERMISSIVE ]", symbol: "checkmark.seal", key: "SPACE",
                        keyColor: DesignTokens.green
                    )
                }
                .buttonStyle(ConsoleButtonStyle(
                    fill: DesignTokens.green, ink: DesignTokens.pitchBlack,
                    border: DesignTokens.green.opacity(0.8)
                ))
                .disabled(!canGrant)
                .accessibilityLabel("Grant permissive")
                .accessibilityHint(grantHint)

                Button(action: abort) {
                    ConsoleActionLabel(
                        title: "[ EMERGENCY ABORT ]", symbol: "xmark.circle", key: "ESC",
                        keyColor: DesignTokens.textReadout
                    )
                }
                .buttonStyle(ConsoleButtonStyle(
                    fill: DesignTokens.red, ink: .white, border: DesignTokens.red.opacity(0.8)
                ))
                .modifier(HazardStripesModifier())
                .disabled(!isObserving || status == .emergencyAbort)
                .accessibilityLabel("Emergency abort")
                .accessibilityHint("Trips Core and revokes configured bridge admissions. Already transmitted effects cannot be rolled back by this button; external teardown is not verified. Escape or Interlock > Emergency Abort, Command-Period. Reset requires Interlock > Reset Abort, Command-R.")

                Button(action: airgap) {
                    Text("AIRGAP DUMP & RESEED NONCE [ F12 ]")
                        .font(DesignTokens.Font.mono(9, weight: "Bold"))
                        .tracking(0.7)
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(ConsoleButtonStyle())
                .accessibilityLabel("Airgap dump and reseed nonce. Not implemented")
                .accessibilityHint("Reports not implemented. Does not disconnect, reseed, or invoke abort. F12.")
                .help("NOT IMPLEMENTED — no disconnect or reseed capability is bound")
            }
            .focusSection()
        }
        .padding(16)
        .background(DesignTokens.cockpitDark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Safety cockpit")
        .task(id: pending?.approval) { [pending] in
            await payload.load(pending)
        }
        .onChange(of: pending?.approval) { inspectionSelection = nil }
        .sheet(item: $inspectionSelection) { selection in
            BridgeInspectionView(selection: selection)
        }
    }
}

private struct ConsoleActionLabel: View {
    let title: String
    let symbol: String
    let key: String
    let keyColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .accessibilityHidden(true)
            Text(title).font(DesignTokens.Font.mono(12, weight: "ExtraBold")).tracking(0.4)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            ConsoleKeycap(key: key, color: keyColor)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

private struct ConsoleGateStatusCard: View {
    let status: InterlockStatus
    let isObserving: Bool
    let countdownTTL: String
    let isBridgeConfigured: Bool

    var body: some View {
        let presentation = ConsoleGatePresentation(status: status, isObserving: isObserving)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: presentation.symbol).font(.system(size: 12, weight: .bold))
                        .accessibilityHidden(true)
                    Text("GATE INTERLOCK: \(presentation.title)")
                        .font(DesignTokens.Font.hudTitleLarge)
                        .tracking(0.6)
                        .lineLimit(1)
                }
                .foregroundStyle(isObserving && status != .locked ? presentation.color : DesignTokens.textReadout)
                Text(isBridgeConfigured ? "APP-ONLY MCP // REQUEST-BOUND CLEARANCE" : presentation.compactDetail)
                    .font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                    .tracking(0.2)
                    .foregroundStyle(DesignTokens.textReadout)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text("TTL POLICY:").font(DesignTokens.Font.labelSm)
                Text(countdownTTL).font(DesignTokens.Font.mono(12, weight: "ExtraBold")).monospacedDigit()
            }
            .foregroundStyle(isObserving && status != .locked ? DesignTokens.pitchBlack : DesignTokens.textReadout)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(presentation.color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(presentation.color.opacity(0.12))
        .overlay { Rectangle().strokeBorder(presentation.color, lineWidth: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gate interlock")
        .accessibilityValue("\(isObserving ? status.rawValue : "Unconfirmed"). \(presentation.detail) \(isBridgeConfigured ? "Bridge clearance is request bound, not session wide." : "Legacy gate only.") Core TTL policy \(countdownTTL). No automatic Core abort deadline is configured.")
    }
}

private struct ConsoleBridgeClearanceSlip: View {
    let snapshot: BridgeSnapshot?
    let isObserving: Bool
    let document: BridgePayloadInspection?
    let inspect: () -> Void

    private var pending: PendingIntercept? { snapshot?.pendingIntercept }
    private var receipt: BridgeTransferReceipt? { snapshot?.latestTransfer }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CLEARANCE // MCP TOOLS/CALL")
                    .font(DesignTokens.Font.mono(10, weight: "Bold"))
                Spacer(minLength: 0)
                Text(isObserving ? BridgePresentation.phase(pending?.phase) : "UNOBSERVED")
                    .font(DesignTokens.Font.mono(8, weight: "Bold"))
                    .foregroundStyle(pending?.phase == .awaitingApproval ? DesignTokens.amber : DesignTokens.textDim)
            }
            ConsoleRule()
            ConsoleSlipField(label: "TOOL HOOK", value: pending.map {
                BridgeDisplayText.escaped($0.toolHook, limit: 40)
            } ?? "UNBOUND")
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ARGUMENT PREVIEW // INSPECT ALL")
                        .font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                        .foregroundStyle(DesignTokens.textMuted)
                    Text(pending == nil ? "UNBOUND // NO LIVE REQUEST" : (document?.preview ?? "INSPECTION PENDING"))
                        .font(DesignTokens.Font.labelSm)
                        .foregroundStyle(document?.issue == nil ? DesignTokens.textDim : DesignTokens.red)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: inspect) {
                    Text("INSPECT").font(DesignTokens.Font.labelSm)
                        .padding(.horizontal, 8).frame(height: 26)
                }
                .buttonStyle(ConsoleButtonStyle())
                .disabled(pending == nil || document == nil)
                .accessibilityLabel("Inspect complete frozen request and all decoded arguments")
                .accessibilityHint("Read only. Escapes control and bidirectional characters. Does not execute or grant.")
            }
            .frame(height: 44, alignment: .top)
            Text(pending.map(BridgePresentation.origin) ?? "SOURCE APPLICATION PID: UNBOUND")
                .font(DesignTokens.Font.mono(8))
                .foregroundStyle(DesignTokens.textDim)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text("SHA-256 // EXACT WIRE + LF // NOT A SIGNATURE")
                    .font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                    .foregroundStyle(DesignTokens.textMuted)
                Text(pending?.approval.sha256 ?? "UNBOUND // NO PAYLOAD")
                    .font(DesignTokens.Font.mono(8))
                    .foregroundStyle(DesignTokens.textReadout)
                    .textSelection(.enabled)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("REQUEST: \(pending?.approval.requestID.uuidString ?? "UNBOUND")")
                Text("GENERATION: \(pending?.approval.connectionGeneration.uuidString ?? snapshot?.generation?.uuidString ?? "UNBOUND")")
            }
            .font(DesignTokens.Font.mono(8))
            .foregroundStyle(DesignTokens.textDim)
            .monospacedDigit()
            HStack {
                Text(pending.map { "FROZEN: \($0.payloadBytes) B" } ?? "FROZEN: --")
                Spacer(minLength: 0)
                Text(pending == nil ? "REQUEST WAIT: UNBOUND" : "REQUEST WAIT: MONOTONIC DEADLINE")
            }
            .font(DesignTokens.Font.mono(8, weight: "SemiBold"))
            .foregroundStyle(DesignTokens.textMuted)
            .monospacedDigit()
            ConsoleRule()
            VStack(alignment: .leading, spacing: 2) {
                Text("LAST \(BridgePresentation.transfer(receipt))")
                Text(receipt.map {
                    "STDOUT: \($0.bytesRead) B / \($0.readChunks) CH // \($0.transmissionStage.rawValue.uppercased()) // \($0.hasCorrelatedResponse ? "CORRELATED" : "NO RESPONSE")"
                } ?? "STDOUT: -- // STAGE: UNBOUND // RESPONSE: UNBOUND")
                Text(receipt.map { "OUTCOME: \(BridgePresentation.outcome($0.outcome))" } ?? "OUTCOME: UNBOUND")
                    .lineLimit(1)
            }
            .font(DesignTokens.Font.mono(8))
            .foregroundStyle(DesignTokens.textDim)
            .monospacedDigit()
            .accessibilityHint("Local pipe write counts and observed stdout over this request interval. Read counts may include notifications. Neither proves external execution.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 264, alignment: .top)
        .background(DesignTokens.cardSlip)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorderLight, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request-bound clearance. App-only bridge; not OS-verified calling-agent identity.")
    }
}

private struct ConsoleClearanceSlip: View {
    let status: InterlockStatus
    let isObserving: Bool

    var body: some View {
        let presentation = ConsoleGatePresentation(status: status, isObserving: isObserving)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(presentation.color)
                    .accessibilityHidden(true)
                Text("CLEARANCE RECORD // UNBOUND")
                    .font(DesignTokens.Font.mono(10, weight: "Bold"))
                    .tracking(0.3)
                Spacer(minLength: 0)
                Text("[NO REQUEST]")
                    .font(DesignTokens.Font.mono(8, weight: "ExtraBold"))
                    .foregroundStyle(DesignTokens.textDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(DesignTokens.railDark)
                    .overlay { Rectangle().strokeBorder(DesignTokens.slateBorderLight, lineWidth: 1) }
            }
            ConsoleRule()
            ConsoleSlipField(label: "TOOL HOOK", value: "NOT CONNECTED")
            VStack(alignment: .leading, spacing: 5) {
                Text("COMMAND PAYLOAD").font(DesignTokens.Font.labelSm)
                    .foregroundStyle(DesignTokens.textMuted)
                Text("UNBOUND // NO LIVE REQUEST")
                    .font(DesignTokens.Font.mono(11, weight: "SemiBold"))
                    .foregroundStyle(DesignTokens.textDim)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.auditDark)
                    .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }
                    .textSelection(.enabled)
            }
            ConsoleSlipField(label: "ORIGIN", value: "UNBOUND")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SHA-256 CHECKSUM")
                    Spacer(minLength: 0)
                    Text("[NO PAYLOAD]").foregroundStyle(DesignTokens.textDim)
                }
                .font(DesignTokens.Font.labelSm)
                .foregroundStyle(DesignTokens.textMuted)
                Text("-- // PAYLOAD UNBOUND")
                    .font(DesignTokens.Font.labelSm)
                    .foregroundStyle(DesignTokens.textDim)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.auditDark)
                    .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                ConsoleSlipStatus(label: "GATE STATE", value: presentation.title,
                    color: isObserving && status != .locked ? presentation.color : DesignTokens.textReadout)
                ConsoleSlipStatus(label: "CRYPTO NONCE", value: "UNBOUND")
                ConsoleSlipStatus(label: "RULESET", value: "NOT BOUND")
            }
        }
        .padding(12)
        .background(DesignTokens.cardSlip)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorderLight, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clearance record, no live request bound")
    }
}

private struct ConsoleSlipField: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(DesignTokens.Font.labelSm).foregroundStyle(DesignTokens.textMuted)
            Spacer(minLength: 0)
            Text(value).font(DesignTokens.Font.labelMd).monospacedDigit().foregroundStyle(DesignTokens.textDim)
                .lineLimit(1)
                .help(value)
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { ConsoleRule(color: DesignTokens.slateBorder.opacity(0.5)) }
        .accessibilityElement(children: .combine)
    }
}

private struct ConsoleSlipStatus: View {
    let label: String
    let value: String
    var color: Color = DesignTokens.textDim

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                .foregroundStyle(DesignTokens.textMuted)
            Text(value).font(DesignTokens.Font.mono(10, weight: "Bold"))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(DesignTokens.railDark)
        .overlay { Rectangle().strokeBorder(DesignTokens.slateBorder, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}
