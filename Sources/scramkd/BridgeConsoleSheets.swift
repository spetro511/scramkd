import AppKit
import Foundation

struct BridgeToolSubmission: Sendable {
    let name: String
    let argumentsJSON: Data
}

/// App-only input collection. Parsing, classification, framing and authorization
/// remain backend responsibilities; this form never executes its text.
@MainActor
final class BridgeToolRequestSheet: NSObject, NSTextViewDelegate {
    static let maximumInputBytes = 1_048_576
    private static let maximumNameBytes = 256

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    private let nameInput = BridgeSheetLayout.plainText(editable: true)
    private let argumentsInput = BridgeSheetLayout.plainText(editable: true)
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private weak var parent: NSWindow?
    private var submission: BridgeToolSubmission?
    private var completion: (@MainActor (BridgeToolSubmission?) -> Void)?

    override init() {
        super.init()
        panel.title = "SUBMIT MCP TOOL REQUEST // APP-OWNED CLIENT"
        panel.isReleasedWhenClosed = false
        nameInput.delegate = self
        argumentsInput.delegate = self
        nameInput.setAccessibilityLabel("MCP tool name. Maximum 256 UTF-8 bytes")
        argumentsInput.setAccessibilityLabel("MCP tool arguments as a JSON object. Combined input limit one mebibyte")
        argumentsInput.string = "{}"

        let instructions = NSTextField(wrappingLabelWithString:
            "Arm the gate manually before opening this form. Submit closes the sheet before dispatch. "
            + "Then review the pending request and grant within its five-second approval window, or abort. "
            + "Every tool call needs its own approval; full transmission relocks the gate. "
            + "Only this app's requests are intercepted. External direct Docker traffic is unchanged and unprotected."
        )
        let limits = NSTextField(wrappingLabelWithString:
            "Name + arguments: at most 1 MiB of UTF-8. The backend separately validates JSON, tool names, "
            + "and the complete framed request size. Origin is this application process, not an authenticated agent."
        )
        let submit = NSButton(title: "Submit Request", target: self, action: #selector(submitRequest(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRequest(_:)))
        cancel.keyEquivalent = "\u{1b}"
        validationLabel.textColor = .systemRed
        let buttons = NSStackView(views: [cancel, submit])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = BridgeSheetLayout.stack(in: panel)
        stack.addArrangedSubview(instructions)
        stack.addArrangedSubview(NSTextField(labelWithString: "TOOL NAME"))
        stack.addArrangedSubview(BridgeSheetLayout.scroll(nameInput, height: 30))
        stack.addArrangedSubview(NSTextField(labelWithString: "ARGUMENTS JSON // NO HOST EXECUTION"))
        stack.addArrangedSubview(BridgeSheetLayout.scroll(argumentsInput, height: 190))
        stack.addArrangedSubview(limits)
        stack.addArrangedSubview(validationLabel)
        stack.addArrangedSubview(buttons)
        BridgeSheetLayout.constrainWidths(in: stack)
    }

    func present(on parent: NSWindow, completion: @escaping @MainActor (BridgeToolSubmission?) -> Void) {
        self.parent = parent
        self.completion = completion
        parent.beginSheet(panel) { [weak self] response in
            guard let self else { return }
            self.panel.orderOut(nil)
            let value = response == .OK ? self.submission : nil
            let callback = self.completion
            self.completion = nil
            self.submission = nil
            callback?(value)
        }
        panel.makeFirstResponder(nameInput)
    }

    func dismiss() {
        // Closing/rebinding the console must not dispatch an unfinished form.
        completion = nil
        submission = nil
        if panel.sheetParent != nil { parent?.endSheet(panel, returnCode: .cancel) }
        panel.orderOut(nil)
    }

    @objc private func submitRequest(_ sender: NSButton) {
        let name = nameInput.string
        let arguments = argumentsInput.string
        guard !name.isEmpty, name.utf8.count <= Self.maximumNameBytes else {
            validationLabel.stringValue = "Tool name required; maximum 256 UTF-8 bytes."
            return
        }
        guard name.utf8.count + arguments.utf8.count <= Self.maximumInputBytes else {
            validationLabel.stringValue = "Combined UTF-8 input exceeds 1 MiB."
            return
        }
        submission = BridgeToolSubmission(name: name, argumentsJSON: Data(arguments.utf8))
        // No network work starts here. Dispatch is owned by the app only after
        // the sheet completion, when the main console can receive grant/abort.
        parent?.endSheet(panel, returnCode: .OK)
    }

    @objc private func cancelRequest(_ sender: NSButton) {
        parent?.endSheet(panel, returnCode: .cancel)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let limit = textView === nameInput ? Self.maximumNameBytes : Self.maximumInputBytes
        guard replacementString.utf8.prefix(limit + 1).count <= limit else {
            validationLabel.stringValue = "Input byte limit exceeded."
            return false
        }
        if textView === nameInput, replacementString.contains(where: \.isNewline) {
            validationLabel.stringValue = "Tool name must be one line."
            return false
        }
        let current = textView.string as NSString
        guard affectedCharRange.location <= current.length,
              affectedCharRange.length <= current.length - affectedCharRange.location
        else { return false }
        let removedBytes = current.substring(with: affectedCharRange).utf8.count
        let resultingBytes = textView.string.utf8.count - removedBytes + replacementString.utf8.count
        let otherBytes = textView === nameInput ? argumentsInput.string.utf8.count : nameInput.string.utf8.count
        guard resultingBytes <= limit, resultingBytes + otherBytes <= Self.maximumInputBytes else {
            validationLabel.stringValue = "Combined UTF-8 input exceeds its limit."
            return false
        }
        validationLabel.stringValue = ""
        return true
    }
}

/// A bounded, read-only plaintext view. It never interprets remote content as
/// HTML, links, rich text, shell commands or instructions to the application.
@MainActor
final class BridgeResponseSheet: NSObject {
    static let displayLimit = 65_536
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    private weak var parent: NSWindow?
    private var completion: (@MainActor () -> Void)?

    init(title: String, summary: String, data: Data?) {
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        let text = BridgeSheetLayout.plainText(editable: false)
        text.setAccessibilityLabel("Untrusted bridge response. Read only")
        let summaryLimit = 4_096
        let summaryRendering = BridgeReadOnlyText.render(summary.utf8, limit: summaryLimit)
        let responseText: String
        let truncation: String
        if let data {
            let rendering = BridgeReadOnlyText.render(data, limit: Self.displayLimit)
            responseText = rendering.text
            truncation = rendering.notice(label: "RESPONSE", limit: Self.displayLimit, totalSourceBytes: data.count)
        } else {
            responseText = "UNAVAILABLE // LOCAL STATE SUMMARY ONLY"
            truncation = "No raw response body is exposed for this state summary; no transfer byte count is inferred."
        }
        text.string = "LOCAL SUMMARY // ESCAPED\n\(summaryRendering.text)\n\nRESPONSE PLAINTEXT // ESCAPED\n"
            + responseText
        let summaryNotice = summaryRendering.notice(label: "SUMMARY", limit: summaryLimit)
        let notice = NSTextField(wrappingLabelWithString:
            "\(truncation)\n\(summaryNotice) "
            + "Escaped plaintext, not original wire bytes. LF/tab preserved; controls and invisible formatting escaped. "
            + "Remote content is untrusted; protocol results do not independently verify external effects."
        )
        let close = NSButton(title: "Close", target: self, action: #selector(closeResponse(_:)))
        close.keyEquivalent = "\u{1b}"
        let stack = BridgeSheetLayout.stack(in: panel)
        stack.addArrangedSubview(notice)
        stack.addArrangedSubview(BridgeSheetLayout.scroll(text, height: 350, width: 720))
        stack.addArrangedSubview(close)
        BridgeSheetLayout.constrainWidths(in: stack)
    }

    func present(on parent: NSWindow, completion: @escaping @MainActor () -> Void) {
        self.parent = parent
        self.completion = completion
        parent.beginSheet(panel) { [weak self] _ in
            guard let self else { return }
            self.panel.orderOut(nil)
            let callback = self.completion
            self.completion = nil
            callback?()
        }
    }

    func dismiss() {
        completion = nil
        if panel.sheetParent != nil { parent?.endSheet(panel, returnCode: .cancel) }
        panel.orderOut(nil)
    }

    @objc private func closeResponse(_ sender: NSButton) {
        parent?.endSheet(panel, returnCode: .cancel)
    }
}

/// Pure, bounded preview rendering. No JSON parse and no replacement decoding.
/// Every output token is at least as long in UTF-8 as its source scalar, so the
/// scanner examines at most limit + 4 source bytes and allocates O(limit) space.
/// A truncated suffix is deliberately not claimed to be validated UTF-8.
/// Static review fixtures (expected behavior, not executed test evidence):
/// - ESC + "[31m" -> "\\u{001B}[31m"; U+202E/U+200B -> visible scalar escapes.
/// - "a" + U+1F600 needs five display bytes; a four-byte cap yields "a", truncated.
/// - C0 AF, ED A0 80, F4 90 80 80, and incomplete E2 82 -> NON_UTF8.
/// - 8193 NUL bytes at a 65536-byte cap -> 8192 complete eight-byte escapes.
private enum BridgeReadOnlyText: Sendable {
    struct Rendering: Sendable {
        let text: String
        let displayBytes: Int
        let renderedSourceBytes: Int
        let isTruncated: Bool
        let invalidSequenceOffset: Int?

        func notice(label: String, limit: Int, totalSourceBytes: Int? = nil) -> String {
            if let offset = invalidSequenceOffset {
                return "\(label) NON_UTF8: invalid sequence at zero-based source byte \(offset). Content withheld; no replacement characters inserted."
            }
            let source = totalSourceBytes.map { "\(renderedSourceBytes) of \($0) source bytes rendered" }
                ?? "\(renderedSourceBytes) source bytes rendered"
            if isTruncated {
                return "\(label) DISPLAY TRUNCATED: \(displayBytes)/\(limit) escaped UTF-8 bytes; \(source). Remaining suffix not validated or rendered by this preview."
            }
            return "\(label): \(displayBytes)/\(limit) escaped UTF-8 bytes; \(source). Strict UTF-8 validated."
        }
    }

    private struct DecodedScalar: Sendable {
        let scalar: Unicode.Scalar
        let byteCount: Int
    }

    static func render<Bytes: Collection>(_ bytes: Bytes, limit: Int) -> Rendering where Bytes.Element == UInt8 {
        let budget = max(0, limit)
        var output = ""
        output.reserveCapacity(budget)
        var displayBytes = 0
        var sourceBytes = 0
        var cursor = bytes.startIndex

        while cursor != bytes.endIndex {
            guard displayBytes < budget else {
                return Rendering(text: output, displayBytes: displayBytes, renderedSourceBytes: sourceBytes,
                                 isTruncated: true, invalidSequenceOffset: nil)
            }
            var next = cursor
            guard let decoded = decodeScalar(bytes, cursor: &next) else {
                // Discard any already-rendered prefix rather than disguising a
                // malformed examined sequence as valid text or display truncation.
                let diagnostic = "NON_UTF8 // Invalid UTF-8 sequence at source byte \(sourceBytes) (zero-based). Content not rendered."
                let safeDiagnostic = String(diagnostic.prefix(budget)) // Trusted ASCII only.
                return Rendering(text: safeDiagnostic, displayBytes: safeDiagnostic.utf8.count, renderedSourceBytes: 0,
                                 isTruncated: false, invalidSequenceOffset: sourceBytes)
            }
            let token = escaped(decoded.scalar)
            let tokenBytes = token.utf8.count // At most ten bytes per scalar.
            guard tokenBytes <= budget - displayBytes else {
                // Neither a UTF-8 scalar nor a visible escape token is split.
                return Rendering(text: output, displayBytes: displayBytes, renderedSourceBytes: sourceBytes,
                                 isTruncated: true, invalidSequenceOffset: nil)
            }
            output.append(contentsOf: token)
            displayBytes += tokenBytes
            sourceBytes += decoded.byteCount
            cursor = next
        }
        return Rendering(text: output, displayBytes: displayBytes, renderedSourceBytes: sourceBytes,
                         isTruncated: false, invalidSequenceOffset: nil)
    }

    /// Strict RFC 3629 scalar decoding: rejects overlong forms, surrogate code
    /// points, out-of-range values, stray continuations and incomplete sequences.
    private static func decodeScalar<Bytes: Collection>(
        _ bytes: Bytes, cursor: inout Bytes.Index
    ) -> DecodedScalar? where Bytes.Element == UInt8 {
        guard let first = takeByte(bytes, cursor: &cursor) else { return nil }
        if first <= 0x7F {
            guard let scalar = Unicode.Scalar(UInt32(first)) else { return nil }
            return DecodedScalar(scalar: scalar, byteCount: 1)
        }
        let length: Int
        let secondMinimum: UInt8
        let secondMaximum: UInt8
        var value: UInt32
        switch first {
        case 0xC2...0xDF:
            length = 2
            value = UInt32(first & 0x1F)
            secondMinimum = 0x80
            secondMaximum = 0xBF
        case 0xE0...0xEF:
            length = 3
            value = UInt32(first & 0x0F)
            secondMinimum = first == 0xE0 ? 0xA0 : 0x80
            secondMaximum = first == 0xED ? 0x9F : 0xBF
        case 0xF0...0xF4:
            length = 4
            value = UInt32(first & 0x07)
            secondMinimum = first == 0xF0 ? 0x90 : 0x80
            secondMaximum = first == 0xF4 ? 0x8F : 0xBF
        default:
            return nil
        }
        guard let second = takeByte(bytes, cursor: &cursor),
              second >= secondMinimum, second <= secondMaximum else { return nil }
        value = (value << 6) | UInt32(second & 0x3F)
        for _ in 2..<length {
            guard let continuation = takeByte(bytes, cursor: &cursor),
                  continuation >= 0x80, continuation <= 0xBF else { return nil }
            value = (value << 6) | UInt32(continuation & 0x3F)
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return DecodedScalar(scalar: scalar, byteCount: length)
    }

    private static func takeByte<Bytes: Collection>(_ bytes: Bytes, cursor: inout Bytes.Index) -> UInt8?
    where Bytes.Element == UInt8 {
        guard cursor != bytes.endIndex else { return nil }
        let value = bytes[cursor]
        bytes.formIndex(after: &cursor)
        return value
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x0A: return "\n"
        case 0x09: return "\t"
        case 0x5C: return "\\\\" // Distinguish source backslashes from generated escapes.
        default: break
        }
        let properties = scalar.properties
        let categoryIsInvisible: Bool
        switch properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .nonspacingMark, .enclosingMark, .privateUse, .unassigned:
            categoryIsInvisible = true
        case .spaceSeparator:
            categoryIsInvisible = scalar.value != 0x20
        default:
            categoryIsInvisible = false
        }
        // Escape a genuinely encoded U+FFFD too, distinguishing it from repair
        // characters that this strict renderer never inserts for invalid bytes.
        if categoryIsInvisible || properties.isBidiControl || properties.isDefaultIgnorableCodePoint
            || scalar.value == 0x2800 || scalar.value == 0xFFFD {
            let hex = String(scalar.value, radix: 16, uppercase: true)
            return "\\u{" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "}"
        }
        return String(scalar)
    }
}

@MainActor
private enum BridgeSheetLayout {
    static func plainText(editable: Bool) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        return view
    }

    static func scroll(_ text: NSTextView, height: CGFloat, width: CGFloat = 680) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        text.frame = scroll.contentView.bounds
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        return scroll
    }

    static func stack(in panel: NSPanel) -> NSStackView {
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = container
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])
        return stack
    }

    static func constrainWidths(in stack: NSStackView) {
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
    }
}
