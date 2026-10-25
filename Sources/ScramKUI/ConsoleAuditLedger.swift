import SwiftUI

struct ConsoleAuditLedger: View {
    let rows: [AuditLogRow]
    let isObserving: Bool
    @State private var selectedFilter = ConsoleAuditFilter.all
    @State private var autoScroll = true

    private var visibleRows: [AuditLogRow] {
        rows.filter { selectedFilter.includes($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Rectangle().fill(isObserving ? DesignTokens.green : DesignTokens.lockedSlate)
                        .frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("REAL-TIME AUDIT LOG // ASYNCSTREAM BUS")
                        .font(DesignTokens.Font.mono(11, weight: "Bold"))
                        .tracking(0.5)
                }
                HStack(spacing: 4) {
                    ForEach(ConsoleAuditFilter.allCases) { filter in
                        ConsoleAuditFilterButton(
                            title: "[ \(filter.title) (\(rows.filter { filter.includes($0) }.count)) ]",
                            isSelected: selectedFilter == filter
                        ) { selectedFilter = filter }
                    }
                }
                .focusSection()
                Spacer(minLength: 0)
                Text(isObserving ? "[ GATE + BRIDGE AUDIT // LOCAL ]" : "[ OBSERVATION: OFFLINE ]")
                    .font(DesignTokens.Font.labelSm)
                    .foregroundStyle(DesignTokens.textMuted)
                Button { autoScroll.toggle() } label: {
                    Text("[ AUTO-SCROLL: \(autoScroll ? "ON" : "OFF") ]")
                        .font(DesignTokens.Font.mono(9, weight: "Bold"))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                }
                .buttonStyle(ConsoleButtonStyle(
                    fill: autoScroll ? DesignTokens.amber.opacity(0.12) : DesignTokens.railDark,
                    ink: autoScroll ? DesignTokens.amber : DesignTokens.textDim,
                    border: autoScroll ? DesignTokens.amber.opacity(0.4) : DesignTokens.slateBorder
                ))
                .accessibilityLabel("Audit auto-scroll")
                .accessibilityValue(autoScroll ? "On" : "Off")
                .accessibilityHint("Turn off to review or select older retained events")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(DesignTokens.chromeDark)
            .overlay(alignment: .bottom) { ConsoleRule() }

            HStack(spacing: 0) {
                Text("MONOTONIC TIME").frame(width: 110, alignment: .leading)
                Text("SUBSYSTEM").frame(width: 90, alignment: .leading)
                Text("EVENT DESCRIPTION").frame(maxWidth: .infinity, alignment: .leading)
                Text("METRIC / RESULT").frame(width: 130, alignment: .trailing)
            }
            .font(DesignTokens.Font.mono(9, weight: "Bold"))
            .tracking(0.6)
            .foregroundStyle(DesignTokens.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 21)
            .background(DesignTokens.chromeDark)
            .overlay(alignment: .bottom) { ConsoleRule() }
            .accessibilityHidden(true)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if visibleRows.isEmpty {
                            Text(isObserving ? "NO RETAINED \(selectedFilter.title) // AWAITING LIVE EVENTS" : "OBSERVATION OFFLINE // NO SEEDED EVENTS")
                                .font(DesignTokens.Font.labelMd)
                                .foregroundStyle(DesignTokens.textMuted)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(.horizontal, 12)
                        }
                        ForEach(visibleRows) { row in
                            ConsoleAuditEventRow(row: row)
                                .id(row.id)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
                .onChange(of: rows.last?.id) {
                    if autoScroll, let id = visibleRows.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: autoScroll) {
                    if autoScroll, let id = visibleRows.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: selectedFilter) {
                    if autoScroll, let id = visibleRows.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .accessibilityLabel("Retained live audit events")
                .accessibilityHint("Rows contain monotonic timestamps, not wall-clock times. Auto-scroll can be disabled for review and selection.")
            }
        }
        .background(DesignTokens.auditDark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audit ledger")
    }
}

private enum ConsoleAuditFilter: String, CaseIterable, Identifiable {
    case all
    case gate
    case commands
    case bridge

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "ALL EVENTS"
        case .gate: "GATE"
        case .commands: "COMMANDS"
        case .bridge: "BRIDGE / STDIO"
        }
    }

    func includes(_ row: AuditLogRow) -> Bool {
        // Retention/gap diagnostics remain visible in every filter.
        guard !["OBSERVATION", "PRESENTATION"].contains(row.subsystem) else { return true }
        switch self {
        case .all: return true
        case .gate: return row.subsystem == "INTERLOCK"
        case .commands: return row.subsystem == "COMMAND"
        case .bridge: return ["BRIDGE", "STDIO", "MCP", "PIPE", "FRAME", "AUDIO", "SVS"].contains(row.subsystem)
        }
    }
}

private struct ConsoleAuditFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(DesignTokens.Font.mono(9, weight: isSelected ? "Bold" : "Medium"))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .frame(height: 24)
        }
        .buttonStyle(ConsoleButtonStyle(
            fill: isSelected ? DesignTokens.panelDark : DesignTokens.railDark,
            ink: isSelected ? DesignTokens.green : DesignTokens.textMuted,
            border: DesignTokens.slateBorder
        ))
        .overlay(alignment: .top) {
            Rectangle().fill(isSelected ? DesignTokens.green : .clear).frame(height: 2)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConsoleAuditEventRow: View {
    let row: AuditLogRow
    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var color: Color {
        switch row.tagColor {
        case "green": DesignTokens.green
        case "amber": DesignTokens.amber
        case "red": DesignTokens.red
        default: DesignTokens.textDim
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(BridgeDisplayText.escaped(row.timestamp, limit: 80))
                .font(DesignTokens.Font.mono(8))
                .monospacedDigit()
                .foregroundStyle(contrast == .increased ? DesignTokens.textDim : DesignTokens.textMuted)
                .frame(width: 110, alignment: .leading)
                .help(BridgeDisplayText.escaped(row.timestamp, limit: 80))
            Text(BridgeDisplayText.escaped(row.subsystem, limit: 24))
                .font(DesignTokens.Font.mono(9, weight: "Bold"))
                .foregroundStyle(row.isEmergency ? Color.white : color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(row.isEmergency ? DesignTokens.red : color.opacity(0.1))
                .frame(width: 90, alignment: .leading)
            HStack(alignment: .top, spacing: 6) {
                if row.isEmergency {
                    Text("!").font(DesignTokens.Font.mono(10, weight: "ExtraBold"))
                        .accessibilityHidden(true)
                }
                Text(BridgeDisplayText.escaped(row.description, limit: 2048))
                    .font(DesignTokens.Font.mono(10, weight: row.isEmergency ? "Bold" : "Regular"))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(row.isEmergency ? DesignTokens.red : DesignTokens.textReadout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
            Text(BridgeDisplayText.escaped(row.metric, limit: 2048))
                .font(DesignTokens.Font.mono(9, weight: "SemiBold"))
                .monospacedDigit()
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 27, alignment: .top)
        .background(row.isEmergency ? DesignTokens.red.opacity(0.08) : (isHovered ? DesignTokens.panelDark.opacity(0.6) : .clear))
        .overlay(alignment: .leading) {
            Rectangle().fill(row.isEmergency ? DesignTokens.red : .clear).frame(width: 2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { ConsoleRule(color: DesignTokens.slateBorder.opacity(0.3)) }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.isEmergency ? "Emergency. " : "")\(BridgeDisplayText.escaped(row.timestamp, limit: 80)). \(BridgeDisplayText.escaped(row.subsystem, limit: 24)). \(BridgeDisplayText.escaped(row.description, limit: 2048)). \(BridgeDisplayText.escaped(row.metric, limit: 2048))")
    }
}
