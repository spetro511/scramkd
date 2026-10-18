import SwiftUI
import TacticalCore

struct ConsoleSafetyCockpit: View {
    let status: InterlockStatus
    let isObserving: Bool
    let countdownTTL: String
    let lastCommandResult: String
    let grant: () -> Void
    let abort: () -> Void
    let airgap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ConsoleGateStatusCard(status: status, isObserving: isObserving, countdownTTL: countdownTTL)
            ConsoleClearanceSlip(status: status, isObserving: isObserving)
            VStack(alignment: .leading, spacing: 5) {
                Text("COMMAND RESULT").font(DesignTokens.Font.mono(8, weight: "SemiBold"))
                    .tracking(0.8).foregroundStyle(DesignTokens.textMuted)
                Text(lastCommandResult.isEmpty ? "NO OPERATOR COMMAND ISSUED" : lastCommandResult)
                    .font(DesignTokens.Font.labelSm)
                    .foregroundStyle(DesignTokens.textDim)
                    .lineLimit(2)
                    .help(lastCommandResult)
                    .textSelection(.enabled)
                    .accessibilityValue(lastCommandResult.isEmpty ? "No operator command issued" : lastCommandResult)
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
                .disabled(!isObserving || status != .armed)
                .accessibilityLabel("Grant permissive")
                .accessibilityHint(isObserving && status == .armed
                    ? "Grants the gate and releases all waiting callers. Does not verify external execution. Space or Interlock > Grant Permissive, Shift-Command-G."
                    : "Available only while the observed gate is armed. Choose Interlock > Arm Gate, Command-A.")

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
                .accessibilityHint("Trips the gate and rejects waiting callers. External teardown is not verified. Escape or Interlock > Emergency Abort, Command-Period. Reset requires Interlock > Reset Abort, Command-R.")

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
                Text(presentation.compactDetail)
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
        .accessibilityValue("\(isObserving ? status.rawValue : "Unconfirmed"). \(presentation.detail) TTL policy \(countdownTTL). No automatic abort deadline is configured.")
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
