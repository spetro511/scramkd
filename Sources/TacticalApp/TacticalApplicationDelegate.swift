import AppKit
import SwiftUI
import TacticalCore
import TacticalUI
import TacticalVirtualization
import os

@MainActor
final class TacticalApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSMenuDelegate, NSMenuItemValidation
{
    private let controller: ConsoleStateController
    private var consoleWindow: NSWindow?
    private var keyboardMonitor: Any?
    private var lastMenuKeyEquivalentID: ConsoleMenuKeySnapshot.Identity?
    private var lastBridgeKeyEquivalentID: ConsoleMenuKeySnapshot.Identity?
    private var lifecycleTask: Task<Void, Never>?
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var bridgeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeBridgeOperation: (id: UUID, command: ConsoleBridgeMenuCommand)?
    private var toolRequestSheet: BridgeToolRequestSheet?
    private var bridgeResponseSheet: BridgeResponseSheet?
    private var windowGeneration: UInt64 = 0
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var resourcesReady = false
    private var isTerminating = false
    private var terminationReplyPending = false

    override init() {
        // One shared gate. Construction does not attach, launch a child process,
        // connect to a service, or enable audio/microphone/VM capabilities.
        let gate = HardwareInterlockGate()
        let bridge = ContainerSocketBridge(interlockGate: gate)
        let framebufferClient = FramebufferClient()
        self.controller = ConsoleStateController(
            interlockGate: gate, bridge: bridge, framebufferClient: framebufferClient
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try TacticalDesignResources.registerFonts()
            resourcesReady = true
        } catch {
            let diagnostic = String(describing: error)
            Logger(subsystem: "MOSDEF.TacticalApp", category: "startup")
                .error("Font registration failed: \(diagnostic, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "CONSOLE STARTUP BLOCKED"
            alert.informativeText = diagnostic
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        configureMenus()
        showConsole()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConsole()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Reopen the same gate; closing a presentation does not reset safety state.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        terminationReplyPending = true
        dismissBridgeSheets()
        if let window = consoleWindow {
            consoleWindow = nil
            window.delegate = nil
            window.contentView = nil
            window.orderOut(nil)
        }
        stopPresentation(replyToTermination: true)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normal termination reached here only after the asynchronous stop reply.
        removeKeyboardMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === consoleWindow else { return }
        dismissBridgeSheets()
        consoleWindow = nil
        // Release the hosting hierarchy even if AppKit retains the closed window.
        // This also tears down its Metal container and view-owned command tasks.
        window.contentView = nil
        window.delegate = nil
        stopPresentation(replyToTermination: false)
    }

    private func showConsole() {
        guard !isTerminating, resourcesReady else { return }
        if let window = consoleWindow {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        windowGeneration &+= 1
        let generation = windowGeneration
        let window = TacticalConsoleWindow(controller: controller)
        window.delegate = self
        consoleWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        installKeyboardMonitor()

        let previous = lifecycleTask
        lifecycleTask = Task { @MainActor [weak self, controller] in
            // Close/reopen cannot let an old stop tear down a newer subscription.
            await previous?.value
            guard !Task.isCancelled,
                  let self,
                  !self.isTerminating,
                  self.windowGeneration == generation,
                  self.consoleWindow != nil
            else { return }
            await controller.start()
        }
    }

    private func stopPresentation(replyToTermination: Bool) {
        windowGeneration &+= 1
        removeKeyboardMonitor()
        trackingMenus.removeAll()
        lastMenuKeyEquivalentID = nil
        lastBridgeKeyEquivalentID = nil
        dismissBridgeSheets()
        let previous = lifecycleTask
        previous?.cancel()
        let commands = Array(commandTasks.values)
        commandTasks.removeAll()
        for task in commands {
            task.cancel()
        }
        let bridgeWork = Array(bridgeTasks.values)
        bridgeTasks.removeAll()
        activeBridgeOperation = nil
        for task in bridgeWork { task.cancel() }

        lifecycleTask = Task { @MainActor [weak self, controller] in
            // Controller stop owns admission revocation and bridge/frame cleanup.
            // Never wait on an approval/response task before requesting teardown.
            await controller.stop()
            await previous?.value
            for task in commands {
                await task.value
            }
            for task in bridgeWork { await task.value }
            // Settle any older bootstrap that was already in progress at close.
            await controller.stop()
            guard replyToTermination, let self, self.terminationReplyPending else { return }
            self.terminationReplyPending = false
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
    }

    private func dispatch(_ command: ConsoleCommand) {
        guard canDispatchCommands else { return }
        let id = UUID()
        let generation = windowGeneration
        let request = controller.commandRequest(command)
        // Every command owns an independent task. Esc never waits in a grant queue.
        commandTasks[id] = Task { @MainActor [weak self, controller] in
            guard let self else { return }
            defer { self.commandTasks.removeValue(forKey: id) }
            guard !Task.isCancelled,
                  self.windowGeneration == generation,
                  self.canDispatchCommands
            else { return }
            await controller.perform(request)
        }
    }

    private var canDispatchCommands: Bool {
        guard !isTerminating, controller.isObserving, let window = consoleWindow else { return false }
        return NSApplication.shared.isActive
            && NSApplication.shared.keyWindow === window
            && window.isVisible
            && window.attachedSheet == nil
            && NSApplication.shared.modalWindow == nil
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers a local event monitor synchronously on the main thread.
            // Keep NSEvent inside that boundary; do not send it through a Task.
            let consumed = MainActor.assumeIsolated {
                self?.routeKeyDown(event) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        guard let monitor = keyboardMonitor else { return }
        NSEvent.removeMonitor(monitor)
        keyboardMonitor = nil
    }

    private func routeKeyDown(_ event: NSEvent) -> Bool {
        let snapshot = ConsoleMenuKeySnapshot(event: event)
        guard let context = routingContext(snapshot: snapshot) else { return false }
        if context.isApplicationActive,
           context.isConsoleKeyWindow,
           context.eventBelongsToConsoleWindow,
           ConsoleMenuRoutingPolicy.shortcutCommand(characters: snapshot.characters, modifiers: context.modifiers) == .armGate,
           context.isTextEntryFocused || validatedSelectAllTarget(action: #selector(NSText.selectAll(_:))) != nil {
            // Bookkeeping only: let native Edit > Select All handle Cmd+A. If
            // AppKit retries this same event after selection focus changes, it
            // still must not become an Arm command. No menu command dispatch here.
            lastMenuKeyEquivalentID = snapshot.identity
        }
        if let command = ConsoleKeyboardPolicy.command(for: context) {
            dispatch(command)
            return true
        }
        return ConsoleKeyboardPolicy.suppressesRepeatedShortcut(context)
    }

    private func routingContext(snapshot: ConsoleMenuKeySnapshot?) -> ConsoleKeyboardContext? {
        guard let window = consoleWindow else { return nil }
        return ConsoleKeyboardContext(
            keyCode: snapshot?.keyCode ?? 0,
            modifiers: Self.routingModifiers(.init(rawValue: snapshot?.modifierFlags ?? 0)),
            isRepeat: snapshot?.isRepeat ?? false,
            isApplicationActive: NSApplication.shared.isActive,
            isConsoleKeyWindow: NSApplication.shared.keyWindow === window && window.isVisible,
            eventBelongsToConsoleWindow: snapshot?.windowID == ObjectIdentifier(window),
            hasAttachedSheet: window.attachedSheet != nil,
            hasModalWindow: NSApplication.shared.modalWindow != nil,
            isMenuTracking: !trackingMenus.isEmpty,
            isTextEntryFocused: Self.isTextEntry(window.firstResponder),
            isAcceptingCommands: !isTerminating && controller.isObserving,
            currentStatus: controller.currentStatus,
            isBridgeConfigured: controller.isBridgeConfigured,
            hasPendingApproval: controller.pendingIntercept?.phase == .awaitingApproval
        )
    }

    private func routeMenuKeyEquivalent(_ snapshot: ConsoleMenuKeySnapshot) -> Bool? {
        guard snapshot.isKeyDown, let context = routingContext(snapshot: snapshot) else { return nil }
        let selectAll = #selector(NSText.selectAll(_:))
        // Ask the actual responder chain, including SwiftUI's native selection
        // bridge. Do not assume that only an NSTextView can own Select All.
        let selectAllTarget = validatedSelectAllTarget(action: selectAll)
        let route = ConsoleMenuRoutingPolicy.keyEquivalentRoute(
            characters: snapshot.characters,
            context: context,
            hasSelectAllResponder: selectAllTarget != nil,
            isDuplicateInvocation: lastMenuKeyEquivalentID == snapshot.identity
        )
        if route != .unhandled { lastMenuKeyEquivalentID = snapshot.identity }
        switch route {
        case .unhandled:
            return nil
        case .selectAll:
            // Consume even if delivery fails: never fall through to Arm Gate.
            _ = NSApplication.shared.sendAction(selectAll, to: selectAllTarget, from: nil)
            return true
        case .command(let command):
            dispatch(command)
            return true
        case .consume:
            return true
        }
    }

    private func validatedSelectAllTarget(action: Selector) -> Any? {
        guard let target = NSApplication.shared.target(forAction: action, to: nil, from: nil) else { return nil }
        let item = NSMenuItem(title: "Select All", action: action, keyEquivalent: "a")
        // NSHostingView implements NSUserInterfaceValidations. Respect its
        // actual selection availability, not merely responds(to: selectAll:).
        if let validator = target as? NSMenuItemValidation {
            guard validator.validateMenuItem(item) else { return nil }
        } else if let validator = target as? NSUserInterfaceValidations {
            guard validator.validateUserInterfaceItem(item) else { return nil }
        }
        return target
    }

    private func dispatchMenuCommand(_ command: ConsoleCommand) {
        let snapshot = NSApplication.shared.currentEvent.map { ConsoleMenuKeySnapshot(event: $0) }
        if let snapshot, snapshot.isKeyDown {
            guard !snapshot.isRepeat else { return }
            if let equivalent = ConsoleMenuRoutingPolicy.shortcutCommand(
                characters: snapshot.characters,
                modifiers: Self.routingModifiers(.init(rawValue: snapshot.modifierFlags))
            ) {
                guard equivalent == command else { return }
                // Native menu actions recheck text priority and duplicate Cmd+A
                // even if AppKit's cached enabled state is no longer current.
                _ = routeMenuKeyEquivalent(snapshot)
                return
            }
        }
        guard let context = routingContext(snapshot: snapshot),
              ConsoleMenuRoutingPolicy.isAvailable(
                command, context: context,
                hasSelectAllResponder: validatedSelectAllTarget(action: #selector(NSText.selectAll(_:))) != nil
              )
        else { return }
        dispatch(command)
    }

    private static func routingModifiers(_ flags: NSEvent.ModifierFlags) -> ConsoleKeyboardContext.Modifiers {
        var modifiers: ConsoleKeyboardContext.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.function) { modifiers.insert(.function) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        return modifiers
    }

    private static func isTextEntry(_ responder: NSResponder?) -> Bool {
        // NSTextView includes the field editor and selectable audit text. Preserve
        // Space/Esc there rather than treating ordinary text interaction as consent.
        responder is NSTextView || responder is NSTextField || responder is NSComboBox
    }

    private func configureMenus() {
        let mainMenu = makeMenu(title: "")
        let appMenu = makeMenu(title: "TacticalApp")
        appMenu.addItem(withTitle: "Quit TacticalApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = makeMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let gateMenu = makeMenu(title: "Interlock")
        let arm = gateMenu.addItem(withTitle: "Arm Gate", action: #selector(armGate(_:)), keyEquivalent: "a")
        arm.target = self
        arm.keyEquivalentModifierMask = [.command]
        let grant = gateMenu.addItem(withTitle: "Grant Permissive", action: #selector(grantPermissive(_:)), keyEquivalent: "g")
        grant.target = self
        grant.keyEquivalentModifierMask = [.command, .shift]
        let abort = gateMenu.addItem(withTitle: "Emergency Abort", action: #selector(emergencyAbort(_:)), keyEquivalent: ".")
        abort.target = self
        abort.keyEquivalentModifierMask = [.command]
        let reset = gateMenu.addItem(withTitle: "Reset Abort", action: #selector(resetAbort(_:)), keyEquivalent: "r")
        reset.target = self
        reset.keyEquivalentModifierMask = [.command]
        addSubmenu(gateMenu, to: mainMenu)

        let virtualizationMenu = makeMenu(title: "Virtualization")
        let attach = virtualizationMenu.addItem(
            withTitle: "Attach ScreenEnv Bridge", action: #selector(attachScreenEnvBridge(_:)), keyEquivalent: "a"
        )
        attach.target = self
        attach.keyEquivalentModifierMask = [.command, .option]
        let detach = virtualizationMenu.addItem(
            withTitle: "Detach Bridge", action: #selector(detachScreenEnvBridge(_:)), keyEquivalent: "d"
        )
        detach.target = self
        detach.keyEquivalentModifierMask = [.command, .option]
        detach.toolTip = "Option-Command-D may be reserved by the system Dock shortcut. Use this menu item directly if preempted."
        virtualizationMenu.addItem(.separator())
        let list = virtualizationMenu.addItem(
            withTitle: "List MCP Tools", action: #selector(listMCPTools(_:)), keyEquivalent: ""
        )
        list.target = self
        list.toolTip = "App-owned tools/list metadata only. External client traffic is not intercepted."
        let submit = virtualizationMenu.addItem(
            withTitle: "Submit MCP Tool Request…", action: #selector(submitMCPToolRequest(_:)), keyEquivalent: ""
        )
        submit.target = self
        submit.toolTip = "Attach, then arm manually before opening. Every tool request needs its own approval."
        addSubmenu(virtualizationMenu, to: mainMenu)

        let windowMenu = makeMenu(title: "Window")
        let show = windowMenu.addItem(withTitle: "Show Console", action: #selector(showConsoleFromMenu(_:)), keyEquivalent: "")
        show.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(windowMenu, to: mainMenu)
        NSApplication.shared.windowsMenu = windowMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func makeMenu(title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        return menu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func armGate(_ sender: NSMenuItem) {
        dispatchMenuCommand(.armGate)
    }

    @objc private func grantPermissive(_ sender: NSMenuItem) {
        dispatchMenuCommand(.grantPermissive)
    }

    @objc private func emergencyAbort(_ sender: NSMenuItem) {
        dispatchMenuCommand(.emergencyAbort)
    }

    @objc private func resetAbort(_ sender: NSMenuItem) {
        dispatchMenuCommand(.resetEmergencyAbort)
    }

    @objc private func showConsoleFromMenu(_ sender: NSMenuItem) {
        showConsole()
    }

    @objc private func attachScreenEnvBridge(_ sender: NSMenuItem) { handleBridgeMenu(.attach) }
    @objc private func detachScreenEnvBridge(_ sender: NSMenuItem) { handleBridgeMenu(.detach) }
    @objc private func listMCPTools(_ sender: NSMenuItem) { handleBridgeMenu(.listTools) }
    @objc private func submitMCPToolRequest(_ sender: NSMenuItem) { handleBridgeMenu(.submitTool) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(armGate(_:)):
            return menuCommandAvailable(.armGate)
        case #selector(grantPermissive(_:)):
            return menuCommandAvailable(.grantPermissive)
        case #selector(emergencyAbort(_:)):
            return menuCommandAvailable(.emergencyAbort)
        case #selector(resetAbort(_:)):
            return menuCommandAvailable(.resetEmergencyAbort)
        case #selector(showConsoleFromMenu(_:)):
            return !isTerminating
        case #selector(attachScreenEnvBridge(_:)):
            return bridgeMenuAvailable(.attach)
        case #selector(detachScreenEnvBridge(_:)):
            return bridgeMenuAvailable(.detach)
        case #selector(listMCPTools(_:)):
            return bridgeMenuAvailable(.listTools)
        case #selector(submitMCPToolRequest(_:)):
            return bridgeMenuAvailable(.submitTool)
        default:
            return true
        }
    }

    private func menuCommandAvailable(_ command: ConsoleCommand) -> Bool {
        let snapshot = NSApplication.shared.currentEvent.map { ConsoleMenuKeySnapshot(event: $0) }
        guard let context = routingContext(snapshot: snapshot) else { return false }
        // Native Edit > Select All keeps Cmd+A while text/selection owns it.
        // Disable Arm itself in that context, so a duplicate native key equivalent
        // cannot fall through to Arm even when Select All has no enabled target.
        return ConsoleMenuRoutingPolicy.isAvailable(
            command, context: context,
            hasSelectAllResponder: validatedSelectAllTarget(action: #selector(NSText.selectAll(_:))) != nil
        )
    }

    private func bridgeMenuContext(snapshot: ConsoleMenuKeySnapshot?) -> ConsoleBridgeMenuContext? {
        guard let keyboard = routingContext(snapshot: snapshot) else { return nil }
        return ConsoleBridgeMenuContext(
            keyboard: keyboard, connectionState: controller.bridgeConnectionState,
            isBridgeConfigured: controller.isBridgeConfigured,
            hasPendingIntercept: controller.pendingIntercept != nil,
            activeOperation: activeBridgeOperation?.command
        )
    }

    private func bridgeMenuAvailable(_ command: ConsoleBridgeMenuCommand) -> Bool {
        let snapshot = NSApplication.shared.currentEvent.map { ConsoleMenuKeySnapshot(event: $0) }
        guard let context = bridgeMenuContext(snapshot: snapshot) else { return false }
        return ConsoleBridgeMenuPolicy.isAvailable(command, context: context)
    }

    private func handleBridgeMenu(_ command: ConsoleBridgeMenuCommand) {
        let snapshot = NSApplication.shared.currentEvent.map { ConsoleMenuKeySnapshot(event: $0) }
        guard let context = bridgeMenuContext(snapshot: snapshot),
              ConsoleBridgeMenuPolicy.isAvailable(command, context: context)
        else { return }
        if let snapshot, snapshot.isKeyDown {
            guard !snapshot.isRepeat else { return }
            if let equivalent = ConsoleBridgeMenuPolicy.shortcutCommand(
                characters: snapshot.characters, modifiers: context.keyboard.modifiers
            ) {
                guard equivalent == command,
                      ConsoleBridgeMenuPolicy.keyEquivalentCommand(
                        characters: snapshot.characters, context: context,
                        isDuplicateInvocation: lastBridgeKeyEquivalentID == snapshot.identity
                      ) == command
                else { return }
                lastBridgeKeyEquivalentID = snapshot.identity
            }
        }
        if command == .submitTool {
            presentToolRequestForm()
        } else {
            startBridgeOperation(command, submission: nil)
        }
    }

    private func presentToolRequestForm() {
        guard let window = consoleWindow, toolRequestSheet == nil, bridgeResponseSheet == nil else { return }
        let generation = windowGeneration
        let connection = controller.bridgeSnapshot?.generation
        let sheet = BridgeToolRequestSheet()
        toolRequestSheet = sheet
        sheet.present(on: window) { [weak self] submission in
            guard let self else { return }
            self.toolRequestSheet = nil
            guard let submission, self.windowGeneration == generation,
                  self.controller.bridgeSnapshot?.generation == connection,
                  self.consoleWindow === window, self.canDispatchCommands
            else { return }
            guard self.bridgeMenuAvailable(.submitTool) else {
                self.presentBridgeResponse(
                    title: "REQUEST NOT DISPATCHED", summary: "Gate, bridge or request availability changed.", data: nil
                )
                return
            }
            self.startBridgeOperation(.submitTool, submission: submission)
        }
    }

    private func startBridgeOperation(_ command: ConsoleBridgeMenuCommand, submission: BridgeToolSubmission?) {
        guard bridgeMenuAvailable(command) else { return }
        if command == .detach {
            // Cancel without waiting; controller detach must revoke admission
            // independently of an older approval/response or attach operation.
            for task in bridgeTasks.values { task.cancel() }
        }
        let id = UUID()
        let generation = windowGeneration
        let connection = controller.bridgeSnapshot?.generation
        activeBridgeOperation = (id, command)
        bridgeTasks[id] = Task { @MainActor [weak self, controller] in
            guard let self else { return }
            defer {
                self.bridgeTasks.removeValue(forKey: id)
                if self.activeBridgeOperation?.id == id { self.activeBridgeOperation = nil }
            }
            guard !Task.isCancelled, self.windowGeneration == generation,
                  self.activeBridgeOperation?.id == id, self.canDispatchCommands
            else { return }
            do {
                let data: Data?
                let title: String
                let summary: String
                switch command {
                case .attach:
                    try await controller.attachBridge()
                    data = nil
                    title = "BRIDGE ATTACH RESULT"
                    summary = self.observedBridgeSummary()
                case .detach:
                    await controller.detachBridge()
                    data = nil
                    title = "BRIDGE DETACH RESULT"
                    summary = self.observedBridgeSummary()
                case .listTools:
                    let request: [String: Any] = [
                        "jsonrpc": "2.0", "id": UUID().uuidString,
                        "method": "tools/list", "params": [String: String]()
                    ]
                    let payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
                    data = try await controller.dispatchMCPCommand(payload)
                    title = "MCP TOOLS // CORRELATED METADATA RESPONSE"
                    summary = "App-owned tools/list. Application PID \(ProcessInfo.processInfo.processIdentifier). External client traffic is not intercepted."
                case .submitTool:
                    guard let submission else { return }
                    let result = try await controller.submitTool(name: submission.name, argumentsJSON: submission.argumentsJSON)
                    data = result.rawResponseData
                    title = "MCP TOOL // PROTOCOL RESPONSE"
                    let receipt = result.receipt
                    summary = "Request \(receipt.requestID). Transmission \(receipt.transmissionStage.rawValue). "
                        + "Written \(receipt.bytesWritten) bytes / \(receipt.writeChunks) chunks; "
                        + "observed stdout \(receipt.bytesRead) bytes / \(receipt.readChunks) chunks; "
                        + "elapsed \(receipt.elapsedNanoseconds) ns. Correlated response: \(receipt.hasCorrelatedResponse). "
                        + "Outcome: \(String(describing: receipt.outcome)). No independent external-effect verification."
                }
                guard self.acceptsBridgeCompletion(id: id, generation: generation, command: command, connection: connection) else { return }
                self.presentBridgeResponse(title: title, summary: summary, data: data)
            } catch {
                guard self.acceptsBridgeCompletion(id: id, generation: generation, command: command, connection: connection) else { return }
                self.presentBridgeResponse(
                    title: "BRIDGE OPERATION ERROR",
                    summary: "\(command) rejected or failed. The controller owns the audited outcome; external effects are not inferred.",
                    data: Data(String(describing: error).utf8)
                )
            }
        }
    }

    private func acceptsBridgeCompletion(
        id: UUID, generation: UInt64, command: ConsoleBridgeMenuCommand, connection: UUID?
    ) -> Bool {
        guard !Task.isCancelled, !isTerminating, windowGeneration == generation,
              activeBridgeOperation?.id == id, canDispatchCommands
        else { return false }
        if command == .listTools || command == .submitTool {
            return controller.bridgeSnapshot?.generation == connection
        }
        return true
    }

    private func observedBridgeSummary() -> String {
        var summary = "Observed connection state: \(controller.bridgeConnectionState.rawValue). App-owned client only. "
            + "No container destruction or external client protection is asserted."
        if let server = controller.serverInfo {
            summary += " Advertised server: \(server.advertisedName) / \(server.advertisedVersion); protocol \(server.protocolVersion). Advertised values are not peer authentication."
        }
        return summary
    }

    private func presentBridgeResponse(title: String, summary: String, data: Data?) {
        guard canDispatchCommands, let window = consoleWindow,
              bridgeResponseSheet == nil, toolRequestSheet == nil
        else { return }
        let generation = windowGeneration
        let sheet = BridgeResponseSheet(title: title, summary: summary, data: data)
        bridgeResponseSheet = sheet
        sheet.present(on: window) { [weak self] in
            guard let self, self.windowGeneration == generation else { return }
            self.bridgeResponseSheet = nil
        }
    }

    private func dismissBridgeSheets() {
        toolRequestSheet?.dismiss()
        toolRequestSheet = nil
        bridgeResponseSheet?.dismiss()
        bridgeResponseSheet = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackingMenus.insert(ObjectIdentifier(menu))
    }

    func menuDidClose(_ menu: NSMenu) {
        trackingMenus.remove(ObjectIdentifier(menu))
    }
}

/// Values copied inside main-actor AppKit actions. No event/window reference
/// escapes into an asynchronous command task or a retained deduplication cache.
private struct ConsoleMenuKeySnapshot: Sendable {
    struct Identity: Sendable, Equatable {
        let object: ObjectIdentifier
        let timestamp: TimeInterval
    }

    let identity: Identity
    let windowID: ObjectIdentifier?
    let isKeyDown: Bool
    let keyCode: UInt16
    let modifierFlags: UInt
    let isRepeat: Bool
    let characters: String

    init(event: NSEvent) {
        identity = Identity(object: ObjectIdentifier(event), timestamp: event.timestamp)
        windowID = event.window.map { ObjectIdentifier($0) }
        isKeyDown = event.type == .keyDown
        // Menu validation also runs for mouse events. Key-only NSEvent accessors
        // are valid only after the keyDown type check.
        keyCode = isKeyDown ? event.keyCode : 0
        modifierFlags = event.modifierFlags.rawValue
        isRepeat = isKeyDown && event.isARepeat
        characters = isKeyDown ? (event.charactersIgnoringModifiers ?? "") : ""
    }
}
