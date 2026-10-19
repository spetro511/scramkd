import TacticalCore
import TacticalVirtualization

/// Pure routing inputs. AppKit event/window objects remain in the composition root.
public struct ConsoleKeyboardContext: Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let command = Self(rawValue: 1 << 0)
        public static let control = Self(rawValue: 1 << 1)
        public static let option = Self(rawValue: 1 << 2)
        public static let shift = Self(rawValue: 1 << 3)
        public static let capsLock = Self(rawValue: 1 << 4)
        public static let function = Self(rawValue: 1 << 5)
        public static let numericPad = Self(rawValue: 1 << 6)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var isRepeat: Bool
    public var isApplicationActive: Bool
    public var isConsoleKeyWindow: Bool
    public var eventBelongsToConsoleWindow: Bool
    public var hasAttachedSheet: Bool
    public var hasModalWindow: Bool
    public var isMenuTracking: Bool
    public var isTextEntryFocused: Bool
    public var isAcceptingCommands: Bool
    public var currentStatus: InterlockStatus
    public var isBridgeConfigured: Bool
    public var hasPendingApproval: Bool

    public init(
        keyCode: UInt16,
        modifiers: Modifiers,
        isRepeat: Bool,
        isApplicationActive: Bool,
        isConsoleKeyWindow: Bool,
        eventBelongsToConsoleWindow: Bool,
        hasAttachedSheet: Bool,
        hasModalWindow: Bool,
        isMenuTracking: Bool,
        isTextEntryFocused: Bool,
        isAcceptingCommands: Bool,
        currentStatus: InterlockStatus = .locked,
        isBridgeConfigured: Bool = false,
        hasPendingApproval: Bool = false
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.isApplicationActive = isApplicationActive
        self.isConsoleKeyWindow = isConsoleKeyWindow
        self.eventBelongsToConsoleWindow = eventBelongsToConsoleWindow
        self.hasAttachedSheet = hasAttachedSheet
        self.hasModalWindow = hasModalWindow
        self.isMenuTracking = isMenuTracking
        self.isTextEntryFocused = isTextEntryFocused
        self.isAcceptingCommands = isAcceptingCommands
        self.currentStatus = currentStatus
        self.isBridgeConfigured = isBridgeConfigured
        self.hasPendingApproval = hasPendingApproval
    }
}

/// App-owned bridge actions only; never an authorization or risk-classification contract.
public enum ConsoleBridgeMenuCommand: Sendable, Equatable {
    case attach
    case detach
    case listTools
    case submitTool
}

public struct ConsoleBridgeMenuContext: Sendable {
    public var keyboard: ConsoleKeyboardContext
    public var connectionState: BridgeConnectionState
    public var isBridgeConfigured: Bool
    public var hasPendingIntercept: Bool
    public var activeOperation: ConsoleBridgeMenuCommand?

    public init(
        keyboard: ConsoleKeyboardContext,
        connectionState: BridgeConnectionState,
        isBridgeConfigured: Bool,
        hasPendingIntercept: Bool,
        activeOperation: ConsoleBridgeMenuCommand? = nil
    ) {
        self.keyboard = keyboard
        self.connectionState = connectionState
        self.isBridgeConfigured = isBridgeConfigured
        self.hasPendingIntercept = hasPendingIntercept
        self.activeOperation = activeOperation
    }
}

public enum ConsoleBridgeMenuPolicy {
    public static func isAvailable(_ command: ConsoleBridgeMenuCommand, context: ConsoleBridgeMenuContext) -> Bool {
        let keyboard = context.keyboard
        guard context.isBridgeConfigured,
              keyboard.isApplicationActive,
              keyboard.isConsoleKeyWindow,
              keyboard.isAcceptingCommands,
              !keyboard.hasAttachedSheet,
              !keyboard.hasModalWindow
        else { return false }
        switch command {
        case .attach:
            return (context.connectionState == .detached || context.connectionState == .failed)
                && keyboard.currentStatus == .locked
                && context.activeOperation == nil
                && !context.hasPendingIntercept
        case .detach:
            // Detach must not queue behind an attach or an approval/response wait.
            return context.connectionState != .detaching
                && context.activeOperation != .detach
                && (context.connectionState != .detached || context.activeOperation == .attach)
        case .listTools:
            return context.connectionState == .attached
                && context.activeOperation == nil
                && !context.hasPendingIntercept
                && keyboard.currentStatus != .emergencyAbort
        case .submitTool:
            return context.connectionState == .attached
                && context.activeOperation == nil
                && !context.hasPendingIntercept
                && keyboard.currentStatus == .armed
        }
    }

    public static func shortcutCommand(
        characters: String,
        modifiers: ConsoleKeyboardContext.Modifiers
    ) -> ConsoleBridgeMenuCommand? {
        let significant: ConsoleKeyboardContext.Modifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(significant) == [.command, .option] else { return nil }
        switch characters.lowercased() {
        case "a": return .attach
        case "d": return .detach
        default: return nil
        }
    }

    public static func keyEquivalentCommand(
        characters: String,
        context: ConsoleBridgeMenuContext,
        isDuplicateInvocation: Bool
    ) -> ConsoleBridgeMenuCommand? {
        let keyboard = context.keyboard
        guard !keyboard.isRepeat,
              !isDuplicateInvocation,
              keyboard.eventBelongsToConsoleWindow,
              !keyboard.isTextEntryFocused,
              let command = shortcutCommand(characters: characters, modifiers: keyboard.modifiers),
              isAvailable(command, context: context)
        else { return nil }
        return command
    }
}

public enum ConsoleKeyboardPolicy {
    public static func command(for context: ConsoleKeyboardContext) -> ConsoleCommand? {
        guard isEligible(context), !context.isRepeat else { return nil }
        switch context.keyCode {
        case 49:
            return context.currentStatus == .armed && (!context.isBridgeConfigured || context.hasPendingApproval)
                ? .grantPermissive : nil
        case 53: return .emergencyAbort
        case 111: return .forceAirgapDump
        default: return nil
        }
    }

    /// Consume eligible repeated shortcuts rather than forwarding them to a focused button.
    /// Esc, like Space and F12, dispatches only on the initial key-down.
    public static func suppressesRepeatedShortcut(_ context: ConsoleKeyboardContext) -> Bool {
        guard isEligible(context), context.isRepeat else { return false }
        return context.keyCode == 49 || context.keyCode == 53 || context.keyCode == 111
    }

    private static func isEligible(_ context: ConsoleKeyboardContext) -> Bool {
        let prohibited: ConsoleKeyboardContext.Modifiers = [.command, .control, .option, .shift]
        return context.isApplicationActive
            && context.isConsoleKeyWindow
            && context.eventBelongsToConsoleWindow
            && context.isAcceptingCommands
            && !context.hasAttachedSheet
            && !context.hasModalWindow
            && !context.isMenuTracking
            && !context.isTextEntryFocused
            && context.modifiers.intersection(prohibited).isEmpty
    }
}

/// Native menu equivalents are separate from the unmodified local-event monitor.
public enum ConsoleMenuKeyRoute: Sendable, Equatable {
    case unhandled
    case selectAll
    case command(ConsoleCommand)
    case consume
}

public enum ConsoleMenuRoutingPolicy {
    /// Explicit menu selection is permitted while menus track. Arm yields to text
    /// selection so native Cmd+A cannot fall through from Edit > Select All.
    public static func isAvailable(
        _ command: ConsoleCommand,
        context: ConsoleKeyboardContext,
        hasSelectAllResponder: Bool = false
    ) -> Bool {
        guard context.isApplicationActive,
              context.isConsoleKeyWindow,
              context.isAcceptingCommands,
              !context.hasAttachedSheet,
              !context.hasModalWindow
        else { return false }
        switch command {
        case .armGate:
            return context.currentStatus == .locked
                && !context.isTextEntryFocused
                && !hasSelectAllResponder
        case .grantPermissive:
            return context.currentStatus == .armed && (!context.isBridgeConfigured || context.hasPendingApproval)
        case .emergencyAbort: return context.currentStatus != .emergencyAbort
        case .resetEmergencyAbort: return context.currentStatus == .emergencyAbort
        case .forceAirgapDump: return true
        }
    }

    public static func shortcutCommand(
        characters: String,
        modifiers: ConsoleKeyboardContext.Modifiers
    ) -> ConsoleCommand? {
        let significant: ConsoleKeyboardContext.Modifiers = [.command, .control, .option, .shift]
        let keys = modifiers.intersection(significant)
        switch characters.lowercased() {
        case "a" where keys == [.command]: return .armGate
        case "g" where keys == [.command, .shift]: return .grantPermissive
        case "." where keys == [.command]: return .emergencyAbort
        case "r" where keys == [.command]: return .resetEmergencyAbort
        default: return nil
        }
    }

    public static func keyEquivalentRoute(
        characters: String,
        context: ConsoleKeyboardContext,
        hasSelectAllResponder: Bool,
        isDuplicateInvocation: Bool = false
    ) -> ConsoleMenuKeyRoute {
        guard let command = shortcutCommand(characters: characters, modifiers: context.modifiers) else {
            return .unhandled
        }
        // Select All precedes gate state, observing state, and repeat checks. A
        // known text focus with no resolved target must still never fall into Arm.
        if command == .armGate, context.isTextEntryFocused || hasSelectAllResponder {
            return .selectAll
        }
        // A recognized but unavailable equivalent cannot fall through to the
        // duplicate native Cmd+A item. Unrelated equivalents still use AppKit.
        guard context.isApplicationActive,
              context.isConsoleKeyWindow,
              context.eventBelongsToConsoleWindow,
              !context.hasAttachedSheet,
              !context.hasModalWindow
        else { return .consume }
        guard !context.isRepeat,
              !isDuplicateInvocation,
              !context.isTextEntryFocused,
              isAvailable(command, context: context)
        else { return .consume }
        return .command(command)
    }
}
