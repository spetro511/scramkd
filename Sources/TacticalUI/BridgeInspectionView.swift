import AppKit
import Combine
import Foundation
import SwiftUI
import TacticalCore
import TacticalVirtualization

/// Display encoding only; never transforms the frozen transport frame or its hash.
enum BridgeDisplayText {
    static func escaped(_ text: String, limit: Int? = nil) -> String {
        var result = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if let limit, count >= limit {
                result += "… [TRUNCATED]"
                break
            }
            count += 1
            switch scalar.value {
            case 0x5C: result += "\\\\"
            case 0x22: result += "\\\""
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                default: result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

enum BridgePresentation {
    static func canGrant(
        status: InterlockStatus, isObserving: Bool, isConfigured: Bool,
        connection: BridgeConnectionState, phase: BridgeInterceptPhase?
    ) -> Bool {
        guard isObserving, status == .armed else { return false }
        guard isConfigured else { return true } // Explicit nil-bridge legacy mode only.
        return connection == .attached && phase == .awaitingApproval
    }

    static func connection(_ state: BridgeConnectionState, configured: Bool, observing: Bool) -> String {
        guard configured else { return "UNBOUND" }
        guard observing else { return "UNOBSERVED" }
        return state.rawValue.uppercased()
    }

    static func phase(_ phase: BridgeInterceptPhase?) -> String {
        switch phase {
        case .awaitingApproval: "AWAITING APPROVAL"
        case .approved: "APPROVED"
        case .writing: "WRITING"
        case .awaitingResponse: "AWAITING RESPONSE"
        case nil: "NO REQUEST"
        }
    }

    static func gateDetail(status: InterlockStatus, phase: BridgeInterceptPhase?, observing: Bool) -> String {
        guard observing else { return "AUTHORITATIVE OBSERVATION PENDING" }
        switch status {
        case .locked: return "CORE LOCKED // Interlock > Arm Gate [CMD-A]"
        case .armed: return phase == .awaitingApproval
            ? "CORE ARMED // CURRENT REQUEST AWAITS CLEARANCE"
            : "CORE ARMED // NO REQUEST AWAITING APPROVAL"
        case .permissiveGranted: return "CORE PERMISSIVE // BRIDGE REQUEST LEASE ONLY"
        case .emergencyAbort: return "CORE ABORT // EXTERNAL EFFECTS NOT VERIFIED"
        }
    }

    static func origin(_ pending: PendingIntercept) -> String {
        let pid = pending.originPID.map(String.init) ?? "UNKNOWN"
        switch pending.originTrust {
        case .appProcess: return "SOURCE APPLICATION PID \(pid)"
        case .claimed: return "CLAIMED PID \(pid) // NOT VERIFIED"
        case .unknown: return "ORIGIN UNKNOWN // PID \(pid)"
        }
    }

    static func outcome(_ outcome: BridgeTransferOutcome) -> String {
        switch outcome {
        case .responseReceived: "PROTOCOL RESPONSE"
        case .remoteError(let code): "REMOTE ERROR \(code)"
        case .toolError: "TOOL ERROR"
        case .rejected: "REJECTED"
        case .declined: "DECLINED"
        case .cancelled: "CANCELLED"
        case .revoked(let reason): "REVOKED // \(reason.rawValue.uppercased())"
        case .timedOut(let kind): "TIMEOUT // \(kind.rawValue.uppercased())"
        case .endOfStream: "PIPE EOF"
        case .processExited(let status): "PROCESS EXIT \(status)"
        case .transportFailed: "TRANSPORT FAILED"
        case .protocolViolation: "PROTOCOL VIOLATION"
        @unknown default: "UNRECOGNIZED OUTCOME // EXTERNAL EFFECTS UNKNOWN"
        }
    }

    static func transfer(_ receipt: BridgeTransferReceipt?) -> String {
        guard let receipt else { return "PIPE OUT: -- // CHUNKS: -- // ELAPSED: --" }
        return "PIPE OUT: \(receipt.bytesWritten) B / \(receipt.writeChunks) CH // \(receipt.elapsedNanoseconds) ns"
    }
}

struct BridgePayloadInspection: Sendable {
    let escapedWire: String
    let allArguments: String
    let preview: String
    let issue: String?
}

private enum BridgeInspectionError: Error {
    case byteLimit, invalidUTF8, invalidFrame, invalidJSON, depthLimit, duplicateKey, invalidToolCall

    var label: String {
        switch self {
        case .byteLimit: "INSPECTION BYTE LIMIT EXCEEDED"
        case .invalidUTF8: "INVALID UTF-8 // NO REPLACEMENT DECODING"
        case .invalidFrame: "INVALID FRAME // FINAL LF REQUIRED"
        case .invalidJSON: "INVALID JSON // ARGUMENTS UNAVAILABLE"
        case .depthLimit: "JSON DEPTH LIMIT EXCEEDED"
        case .duplicateKey: "DUPLICATE JSON KEY // AMBIGUOUS ARGUMENTS"
        case .invalidToolCall: "INVALID TOOLS/CALL // ARGUMENTS UNAVAILABLE"
        }
    }
}

/// Own executor for bounded pure parsing. No controller, UI, authorization, or I/O.
actor BridgePayloadDecoder {
    static let maximumBytes = 1_048_576

    func decode(_ data: Data) throws -> BridgePayloadInspection {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else {
            return failure(.byteLimit, wire: "WIRE OMITTED // \(data.count) B EXCEEDS 1048576 B LIMIT")
        }
        guard let utf8 = String(data: data, encoding: .utf8) else {
            return failure(.invalidUTF8, wire: "WIRE UNAVAILABLE // INVALID UTF-8")
        }
        let escapedWire = BridgeDisplayText.escaped(utf8)
        do {
            guard data.last == 0x0A,
                  !data.dropLast().contains(where: { $0 == 0x0A || $0 == 0x0D }) else {
                throw BridgeInspectionError.invalidFrame
            }
            var parser = BridgeInspectionJSONParser(bytes: Array(data))
            let value = try parser.parse()
            guard case .object(let root) = value,
                  case .string("tools/call")? = root["method"],
                  case .string("2.0")? = root["jsonrpc"],
                  case .object(let params)? = root["params"],
                  case .string? = params["name"],
                  case .object? = params["arguments"],
                  let arguments = params["arguments"] else { throw BridgeInspectionError.invalidToolCall }
            let rendered = try arguments.render()
            try Task.checkCancellation()
            return BridgePayloadInspection(
                escapedWire: escapedWire, allArguments: rendered,
                preview: String(rendered.prefix(120)) + (rendered.count > 120 ? "… [TRUNCATED; INSPECT ALL]" : ""),
                issue: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let issue = (error as? BridgeInspectionError)?.label ?? BridgeInspectionError.invalidJSON.label
            return BridgePayloadInspection(escapedWire: escapedWire, allArguments: issue, preview: issue, issue: issue)
        }
    }

    private func failure(_ error: BridgeInspectionError, wire: String) -> BridgePayloadInspection {
        BridgePayloadInspection(escapedWire: wire, allArguments: error.label, preview: error.label, issue: error.label)
    }
}

/// Retains original numeric tokens; Foundation floating-point conversion cannot
/// round an argument during inspection. Duplicate keys are rejected, not collapsed.
private indirect enum BridgeInspectionJSON {
    case object([String: BridgeInspectionJSON])
    case array([BridgeInspectionJSON])
    case string(String)
    case scalar(String)

    func render() throws -> String {
        try Task.checkCancellation()
        switch self {
        case .object(let values):
            return "{" + (try values.keys.sorted().map { key in
                guard let value = values[key] else { throw BridgeInspectionError.invalidJSON }
                return "\"\(BridgeDisplayText.escaped(key))\": " + (try value.render())
            }).joined(separator: ", ") + "}"
        case .array(let values): return "[" + (try values.map { try $0.render() }).joined(separator: ", ") + "]"
        case .string(let value): return "\"\(BridgeDisplayText.escaped(value))\""
        case .scalar(let value): return value
        }
    }
}

private struct BridgeInspectionJSONParser {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() throws -> BridgeInspectionJSON {
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw BridgeInspectionError.invalidJSON }
        return result
    }

    private mutating func value(depth: Int) throws -> BridgeInspectionJSON {
        try Task.checkCancellation()
        guard depth <= 32 else { throw BridgeInspectionError.depthLimit }
        whitespace()
        guard index < bytes.count else { throw BridgeInspectionError.invalidJSON }
        switch bytes[index] {
        case 0x22: return .string(try string())
        case 0x7B:
            index += 1
            whitespace()
            var values: [String: BridgeInspectionJSON] = [:]
            if consume(0x7D) { return .object(values) }
            while true {
                whitespace()
                let key = try string()
                guard values[key] == nil else { throw BridgeInspectionError.duplicateKey }
                whitespace()
                guard consume(0x3A) else { throw BridgeInspectionError.invalidJSON }
                values[key] = try value(depth: depth + 1)
                whitespace()
                if consume(0x7D) { return .object(values) }
                guard consume(0x2C) else { throw BridgeInspectionError.invalidJSON }
            }
        case 0x5B:
            index += 1
            whitespace()
            var values: [BridgeInspectionJSON] = []
            if consume(0x5D) { return .array(values) }
            while true {
                values.append(try value(depth: depth + 1))
                whitespace()
                if consume(0x5D) { return .array(values) }
                guard consume(0x2C) else { throw BridgeInspectionError.invalidJSON }
            }
        default:
            let start = index
            while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
                index += 1
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            }
            guard start < index, let token = String(bytes: bytes[start..<index], encoding: .utf8),
                  ["true", "false", "null"].contains(token) || Self.isNumber(token) else {
                throw BridgeInspectionError.invalidJSON
            }
            return .scalar(token)
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard consume(0x22) else { throw BridgeInspectionError.invalidJSON }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            if escaped { escaped = false; continue }
            if byte == 0x5C { escaped = true; continue }
            if byte == 0x22 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                catch { throw BridgeInspectionError.invalidJSON }
            }
        }
        throw BridgeInspectionError.invalidJSON
    }

    private static func isNumber(_ token: String) -> Bool {
        // ASCII-only JSON number grammar; never converts/rounds its magnitude.
        token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private mutating func whitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

@MainActor
final class BridgePayloadPresentationModel: ObservableObject {
    @Published private(set) var key: BridgeApprovalKey?
    @Published private(set) var inspection: BridgePayloadInspection?
    private let decoder = BridgePayloadDecoder()

    func document(for key: BridgeApprovalKey?) -> BridgePayloadInspection? {
        guard let key, self.key == key else { return nil }
        return inspection
    }

    func load(_ pending: PendingIntercept?) async {
        guard !Task.isCancelled else { return }
        guard let pending else { key = nil; inspection = nil; return }
        if key == pending.approval, inspection != nil { return }
        key = pending.approval
        inspection = nil
        do {
            let result = try await decoder.decode(pending.commandPayload)
            guard !Task.isCancelled, key == pending.approval else { return }
            inspection = result
        } catch is CancellationError {
            // Superseded/closed inspections do not mutate current presentation.
        } catch {
            guard !Task.isCancelled, key == pending.approval else { return }
            inspection = BridgePayloadInspection(
                escapedWire: "INSPECTION FAILED", allArguments: "INSPECTION FAILED",
                preview: "INSPECTION FAILED", issue: "INSPECTION FAILED"
            )
        }
    }
}

struct BridgeInspectionSelection: Identifiable {
    let pending: PendingIntercept
    let document: BridgePayloadInspection
    var id: BridgeApprovalKey { pending.approval }
}

@MainActor
struct BridgeInspectionView: View {
    let selection: BridgeInspectionSelection
    @Environment(\.dismiss) private var dismiss
    @State private var showArguments = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FROZEN MCP REQUEST // READ ONLY").font(DesignTokens.Font.mono(13, weight: "SemiBold"))
                Spacer()
                Button { dismiss() } label: {
                    Text("CLOSE").padding(.horizontal, 12).padding(.vertical, 6)
                }
                    .buttonStyle(ConsoleButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Text("REQUEST: \(selection.pending.approval.requestID.uuidString)")
            Text("GENERATION: \(selection.pending.approval.connectionGeneration.uuidString)")
            Text(BridgePresentation.origin(selection.pending))
            Text("APP-SOURCED OR CLAIMED IDENTITY IS NOT OS-VERIFIED CALLING-AGENT IDENTITY")
                .foregroundStyle(DesignTokens.textDim)
            Text("SHA-256 // EXACT WIRE + FINAL LF // \(selection.pending.payloadBytes) B")
            Text(selection.pending.approval.sha256).textSelection(.enabled)
            Text("FINGERPRINT ONLY // NOT AN AUTHENTICATION SIGNATURE")
                .foregroundStyle(DesignTokens.amber)
            Text("REQUEST WAIT CONTINUES // CLOSE TO GRANT OR ABORT // CORE TTL: UNBOUND")
            HStack {
                Button { showArguments = false } label: {
                    Text("FROZEN WIRE + LF").padding(.horizontal, 10).padding(.vertical, 6)
                }
                Button { showArguments = true } label: {
                    Text("ALL DECODED ARGUMENTS").padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            .buttonStyle(ConsoleButtonStyle())
            Text(showArguments
                ? "ALL KEYS / VALUES // STRINGS ESCAPED // NUMERIC TOKENS PRESERVED"
                : "COMPLETE UTF-8 WIRE // CONTROL / BIDI / QUOTES / BACKSLASHES ESCAPED")
                .foregroundStyle(DesignTokens.textDim)
            if let issue = selection.document.issue {
                Text(issue).foregroundStyle(DesignTokens.red)
            }
            BridgeInspectionTextView(
                text: showArguments ? selection.document.allArguments : selection.document.escapedWire,
                key: selection.pending.approval, showArguments: showArguments
            )
                .overlay { Rectangle().strokeBorder(DesignTokens.slateBorderLight, lineWidth: 1) }
            Text("READ ONLY // NO EXECUTION // NO GRANT CONTROL // WIRE BYTES ARE AUTHORITATIVE")
                .foregroundStyle(DesignTokens.textMuted)
        }
        .font(DesignTokens.Font.labelMd)
        .monospacedDigit()
        .foregroundStyle(DesignTokens.textReadout)
        .padding(20)
        .frame(width: 900, height: 660)
        .background(DesignTokens.cockpitDark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frozen request inspection. Read only. Escaped display; no command execution.")
    }
}

@MainActor
private struct BridgeInspectionTextView: NSViewRepresentable {
    let text: String
    let key: BridgeApprovalKey
    let showArguments: Bool

    @MainActor
    final class Coordinator {
        var key: BridgeApprovalKey?
        var showArguments: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 340))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 10)
        // Never substitute a system face if the startup font contract is broken.
        guard let font = NSFont(name: "JetBrainsMono-Regular", size: 11) else {
            scroll.setAccessibilityLabel("FONT UNAVAILABLE. Request inspection blocked; no substitute font.")
            return scroll
        }
        view.font = font
        view.textColor = NSColor(srgbRed: 223.0 / 255, green: 226.0 / 255, blue: 240.0 / 255, alpha: 1)
        view.backgroundColor = NSColor(srgbRed: 4.0 / 255, green: 6.0 / 255, blue: 12.0 / 255, alpha: 1)
        view.string = text
        context.coordinator.key = key
        context.coordinator.showArguments = showArguments
        view.setAccessibilityLabel("Complete escaped request text. Select and copy with native text commands.")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let view = nsView.documentView as? NSTextView,
              context.coordinator.key != key || context.coordinator.showArguments != showArguments else { return }
        view.string = text
        context.coordinator.key = key
        context.coordinator.showArguments = showArguments
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
