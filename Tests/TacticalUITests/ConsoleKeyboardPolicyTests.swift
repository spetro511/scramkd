import XCTest
import TacticalCore
import TacticalVirtualization
@testable import TacticalUI

final class ConsoleKeyboardPolicyTests: XCTestCase {
    private let shortcutKeyCodes: [UInt16] = [49, 53, 111]

    func testExactPhysicalKeyCodesRouteToDistinctCommands() {
        assertCommand(context(keyCode: 49), is: .grantPermissive)
        assertCommand(context(keyCode: 53), is: .emergencyAbort)
        assertCommand(context(keyCode: 111), is: .forceAirgapDump)
    }

    func testOtherKeyCodesNeverRoute() {
        for keyCode in UInt16(0)...UInt16(127) where ![49, 53, 111].contains(keyCode) {
            assertCommand(context(keyCode: keyCode), is: nil)
        }
    }

    func testEveryCommandControlOptionShiftCombinationBlocksShortcuts() {
        for rawValue in UInt8(1)...UInt8(15) {
            for keyCode in shortcutKeyCodes {
                var input = context(keyCode: keyCode)
                input.modifiers = .init(rawValue: rawValue)
                assertCommand(input, is: nil)
            }
        }
    }

    func testCapsLockFunctionAndNumericPadFlagsDoNotMakeF12Unavailable() {
        for rawValue in UInt8(0)...UInt8(7) {
            var input = context(keyCode: 111)
            input.modifiers = .init(rawValue: rawValue << 4)
            assertCommand(input, is: .forceAirgapDump)
        }
    }

    func testActiveOwnKeyWindowAndMatchingEventAreAllRequired() {
        let required: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [
            \.isApplicationActive,
            \.isConsoleKeyWindow,
            \.eventBelongsToConsoleWindow,
            \.isAcceptingCommands
        ]
        for field in required {
            for keyCode in shortcutKeyCodes {
                var input = context(keyCode: keyCode)
                input[keyPath: field] = false
                assertCommand(input, is: nil)
                input.isRepeat = true
                XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(input))
            }
        }
    }

    func testSheetsModalWindowsMenusAndTextFocusPreserveTheirOwnKeys() {
        let blockers: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [
            \.hasAttachedSheet,
            \.hasModalWindow,
            \.isMenuTracking,
            \.isTextEntryFocused
        ]
        for field in blockers {
            for keyCode in shortcutKeyCodes {
                var input = context(keyCode: keyCode)
                input[keyPath: field] = true
                assertCommand(input, is: nil)
                input.isRepeat = true
                XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(input))
            }
        }
    }

    func testAllShortcutRepeatsIncludingEscAreConsumedWithoutAnotherCommand() {
        for keyCode in shortcutKeyCodes {
            var input = context(keyCode: keyCode)
            XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(input))
            input.isRepeat = true
            assertCommand(input, is: nil)
            XCTAssertTrue(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(input))
        }
    }

    func testUnrelatedAndModifiedRepeatsRemainAvailableToAppKit() {
        var unrelated = context(keyCode: 36)
        unrelated.isRepeat = true
        XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(unrelated))

        for keyCode in shortcutKeyCodes {
            var modified = context(keyCode: keyCode)
            modified.isRepeat = true
            modified.modifiers = [.command]
            XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(modified))
        }
    }

    func testLocalMonitorNeverInventsArmOrResetShortcuts() {
        for keyCode in UInt16(0)...UInt16(127) {
            let result = ConsoleKeyboardPolicy.command(for: context(keyCode: keyCode))
            if case .armGate? = result { XCTFail("Arm must remain an explicit menu action") }
            if case .resetEmergencyAbort? = result { XCTFail("Reset must remain an explicit menu action") }
        }
    }

    func testSpaceRequiresArmedButEscAndF12RemainIndependent() {
        for status in statuses {
            assertCommand(context(keyCode: 49, status: status), is: status == .armed ? .grantPermissive : nil)
            assertCommand(context(keyCode: 53, status: status), is: .emergencyAbort)
            assertCommand(context(keyCode: 111, status: status), is: .forceAirgapDump)
        }
    }

    func testOmittedStatusDefaultsLockedAndCannotGrant() {
        let input = ConsoleKeyboardContext(
            keyCode: 49, modifiers: [], isRepeat: false,
            isApplicationActive: true, isConsoleKeyWindow: true,
            eventBelongsToConsoleWindow: true, hasAttachedSheet: false,
            hasModalWindow: false, isMenuTracking: false,
            isTextEntryFocused: false, isAcceptingCommands: true
        )
        XCTAssertEqual(input.currentStatus, .locked)
        assertCommand(input, is: nil)
    }

    func testNativeMenuShortcutCharactersAndModifiersAreExact() {
        for (characters, modifiers, expected) in menuShortcuts {
            XCTAssertEqual(
                ConsoleMenuRoutingPolicy.shortcutCommand(characters: characters, modifiers: modifiers), expected
            )
            XCTAssertEqual(
                ConsoleMenuRoutingPolicy.shortcutCommand(characters: characters.uppercased(), modifiers: modifiers), expected
            )
            for extra in [ConsoleKeyboardContext.Modifiers.option, .control] {
                XCTAssertNil(ConsoleMenuRoutingPolicy.shortcutCommand(
                    characters: characters, modifiers: modifiers.union(extra)
                ))
            }
        }
        XCTAssertNil(ConsoleMenuRoutingPolicy.shortcutCommand(characters: "g", modifiers: [.command]))
        XCTAssertNil(ConsoleMenuRoutingPolicy.shortcutCommand(characters: "a", modifiers: [.command, .shift]))
        XCTAssertNil(ConsoleMenuRoutingPolicy.shortcutCommand(characters: "a", modifiers: []))
    }

    func testMenuAvailabilityMatchesEveryObservedGateState() {
        for status in statuses {
            let input = context(keyCode: 0, status: status)
            XCTAssertEqual(ConsoleMenuRoutingPolicy.isAvailable(.armGate, context: input), status == .locked)
            XCTAssertEqual(ConsoleMenuRoutingPolicy.isAvailable(.grantPermissive, context: input), status == .armed)
            XCTAssertEqual(ConsoleMenuRoutingPolicy.isAvailable(.emergencyAbort, context: input), status != .emergencyAbort)
            XCTAssertEqual(ConsoleMenuRoutingPolicy.isAvailable(.resetEmergencyAbort, context: input), status == .emergencyAbort)
        }
    }

    func testMenuAvailabilityRequiresActiveOwnWindowAndObservation() {
        let required: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [
            \.isApplicationActive, \.isConsoleKeyWindow, \.isAcceptingCommands
        ]
        for (_, _, command) in menuShortcuts {
            for field in required {
                var input = context(keyCode: 0, status: availableStatus(for: command))
                input[keyPath: field] = false
                XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(command, context: input))
            }
        }
    }

    func testCmdASelectAllResponderAlwaysPrecedesArmIncludingWhenNotObserving() {
        for status in statuses {
            for repeatKey in [false, true] {
                for observing in [false, true] {
                    var input = context(keyCode: 0, status: status)
                    input.modifiers = [.command]
                    input.isRepeat = repeatKey
                    input.isAcceptingCommands = observing
                    // SwiftUI's selection bridge may resolve without an NSTextView
                    // first responder. A native Select All target still wins.
                    XCTAssertEqual(menuRoute("a", input, hasSelectAllResponder: true), .selectAll)
                    input.isTextEntryFocused = true
                    // Even a missing target must not turn known text focus into Arm.
                    XCTAssertEqual(menuRoute("a", input, hasSelectAllResponder: false), .selectAll)
                }
            }
        }
    }

    func testCmdAWithoutTextOrSelectAllTargetArmsOnlyLocked() {
        for status in statuses {
            var input = context(keyCode: 0, status: status)
            input.modifiers = [.command]
            XCTAssertEqual(menuRoute("a", input), status == .locked ? .command(.armGate) : .consume)
        }
    }

    func testAllMenuEquivalentRepeatsConsumeWithoutAnotherCommand() {
        for (characters, modifiers, command) in menuShortcuts {
            var input = context(keyCode: 0, status: availableStatus(for: command))
            input.modifiers = modifiers
            XCTAssertEqual(menuRoute(characters, input), .command(command))
            input.isRepeat = true
            XCTAssertEqual(menuRoute(characters, input), .consume)
        }
    }

    func testDuplicateEquivalentInvocationNeverDispatchesAgain() {
        for (characters, modifiers, command) in menuShortcuts {
            var input = context(keyCode: 0, status: availableStatus(for: command))
            input.modifiers = modifiers
            XCTAssertEqual(ConsoleMenuRoutingPolicy.keyEquivalentRoute(
                characters: characters, context: input, hasSelectAllResponder: false,
                isDuplicateInvocation: true
            ), .consume)
        }
    }

    func testSameCmdAInvocationCannotArmAfterSelectionFocusChanges() {
        var input = context(keyCode: 0, status: .locked)
        input.modifiers = [.command]
        input.isTextEntryFocused = true
        XCTAssertEqual(menuRoute("a", input, hasSelectAllResponder: true), .selectAll)

        input.isTextEntryFocused = false
        XCTAssertEqual(ConsoleMenuRoutingPolicy.keyEquivalentRoute(
            characters: "a", context: input, hasSelectAllResponder: false,
            isDuplicateInvocation: true
        ), .consume)
    }

    func testNativeArmItemYieldsToSelectAllAndKnownTextFocus() {
        var input = context(keyCode: 0, status: .locked)
        XCTAssertTrue(ConsoleMenuRoutingPolicy.isAvailable(.armGate, context: input))
        XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(
            .armGate, context: input, hasSelectAllResponder: true
        ))
        input.isTextEntryFocused = true
        XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(
            .armGate, context: input, hasSelectAllResponder: false
        ))
    }

    func testMenuEquivalentStateNeverRelaxesWindowSheetModalOrObservationChecks() {
        let required: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [
            \.isApplicationActive, \.isConsoleKeyWindow,
            \.eventBelongsToConsoleWindow, \.isAcceptingCommands
        ]
        let prohibited: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [\.hasAttachedSheet, \.hasModalWindow]
        for (characters, modifiers, command) in menuShortcuts {
            for field in required {
                var input = context(keyCode: 0, status: availableStatus(for: command))
                input.modifiers = modifiers
                input[keyPath: field] = false
                XCTAssertEqual(menuRoute(characters, input), .consume)
            }
            for field in prohibited {
                var input = context(keyCode: 0, status: availableStatus(for: command))
                input.modifiers = modifiers
                input[keyPath: field] = true
                XCTAssertEqual(menuRoute(characters, input), .consume)
                XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(command, context: input))
            }
        }
    }

    func testExplicitOpenMenuActionsRemainAvailableWithoutBypassingWindowChecks() {
        for (_, _, command) in menuShortcuts {
            var input = context(keyCode: 0, status: availableStatus(for: command))
            input.isMenuTracking = true
            input.isTextEntryFocused = true
            // Other explicit menu actions remain available. Arm must also yield
            // while text owns Cmd+A, even if native Select All is disabled.
            XCTAssertEqual(ConsoleMenuRoutingPolicy.isAvailable(command, context: input), command != .armGate)
            input.isConsoleKeyWindow = false
            XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(command, context: input))
        }
    }

    func testOtherMenuShortcutsDoNotRunDuringTextFocus() {
        for (characters, modifiers, command) in menuShortcuts where command != .armGate {
            var input = context(keyCode: 0, status: availableStatus(for: command))
            input.modifiers = modifiers
            input.isTextEntryFocused = true
            XCTAssertEqual(menuRoute(characters, input), .consume)
        }
    }

    func testMenuEquivalentsNeverAlsoDispatchThroughLocalMonitor() {
        for (_, modifiers, _) in menuShortcuts {
            for keyCode in shortcutKeyCodes {
                var input = context(keyCode: keyCode)
                input.modifiers = modifiers
                assertCommand(input, is: nil)
                input.isRepeat = true
                XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(input))
            }
        }
    }

    func testBridgeAttachRequiresLockedDetachedOrFailedState() {
        for state in bridgeStates {
            for status in statuses {
                let input = bridgeContext(state: state, status: status)
                XCTAssertEqual(
                    ConsoleBridgeMenuPolicy.isAvailable(.attach, context: input),
                    status == .locked && (state == .detached || state == .failed)
                )
            }
        }
    }

    func testBridgeAttachDoesNotQueueBehindOperationsOrPendingIntercepts() {
        var input = bridgeContext(state: .detached, status: .locked)
        for operation in bridgeCommands {
            input.activeOperation = operation
            XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.attach, context: input))
        }
        input.activeOperation = nil
        input.hasPendingIntercept = true
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.attach, context: input))
    }

    func testBridgeDetachRemainsIndependentOfToolOrAttachWaits() {
        for operation in [ConsoleBridgeMenuCommand.attach, .listTools, .submitTool] {
            var input = bridgeContext(state: .attached, status: .emergencyAbort)
            input.activeOperation = operation
            input.hasPendingIntercept = true
            XCTAssertTrue(ConsoleBridgeMenuPolicy.isAvailable(.detach, context: input))
        }
        var notYetStarted = bridgeContext(state: .detached, status: .locked)
        notYetStarted.activeOperation = .attach
        XCTAssertTrue(ConsoleBridgeMenuPolicy.isAvailable(.detach, context: notYetStarted))
        notYetStarted.activeOperation = nil
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.detach, context: notYetStarted))
    }

    func testBridgeDetachCannotRepeatWhileAlreadyDetaching() {
        var input = bridgeContext(state: .detaching, status: .locked)
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.detach, context: input))
        input.connectionState = .attached
        input.activeOperation = .detach
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.detach, context: input))
    }

    func testBridgeToolSubmissionRequiresFreshManualArmAndIdleAttachedClient() {
        for state in bridgeStates {
            for status in statuses {
                let input = bridgeContext(state: state, status: status)
                XCTAssertEqual(ConsoleBridgeMenuPolicy.isAvailable(.submitTool, context: input), state == .attached && status == .armed)
            }
        }
        var input = bridgeContext(state: .attached, status: .armed)
        input.hasPendingIntercept = true
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.submitTool, context: input))
        input.hasPendingIntercept = false
        input.activeOperation = .listTools
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.submitTool, context: input))
    }

    func testBridgeMetadataListingDoesNotRequireAnArmedGate() {
        var input = bridgeContext(state: .attached, status: .locked)
        XCTAssertTrue(ConsoleBridgeMenuPolicy.isAvailable(.listTools, context: input))
        input.connectionState = .detached
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.listTools, context: input))
        input.connectionState = .attached
        input.hasPendingIntercept = true
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.listTools, context: input))
        input.hasPendingIntercept = false
        input.keyboard.currentStatus = .emergencyAbort
        XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(.listTools, context: input))
    }

    func testBridgeMenuAvailabilityPreservesActiveWindowObservationAndSheetBoundaries() {
        let required: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [
            \.isApplicationActive, \.isConsoleKeyWindow, \.isAcceptingCommands
        ]
        let blockers: [WritableKeyPath<ConsoleKeyboardContext, Bool>] = [\.hasAttachedSheet, \.hasModalWindow]
        for command in bridgeCommands {
            let initial = availableBridgeContext(command)
            for field in required {
                var input = initial
                input.keyboard[keyPath: field] = false
                XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(command, context: input))
            }
            for field in blockers {
                var input = initial
                input.keyboard[keyPath: field] = true
                XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(command, context: input))
            }
            var unconfigured = initial
            unconfigured.isBridgeConfigured = false
            XCTAssertFalse(ConsoleBridgeMenuPolicy.isAvailable(command, context: unconfigured))
        }
    }

    func testBridgeShortcutsRequireExactOptionCommandModifiers() {
        for rawValue in UInt8(0)...UInt8(15) {
            let modifiers = ConsoleKeyboardContext.Modifiers(rawValue: rawValue)
            let matches = modifiers == [.option, .command]
            XCTAssertEqual(ConsoleBridgeMenuPolicy.shortcutCommand(characters: "a", modifiers: modifiers), matches ? .attach : nil)
            XCTAssertEqual(ConsoleBridgeMenuPolicy.shortcutCommand(characters: "d", modifiers: modifiers), matches ? .detach : nil)
        }
        XCTAssertEqual(ConsoleBridgeMenuPolicy.shortcutCommand(characters: "A", modifiers: [.option, .command, .capsLock]), .attach)
        XCTAssertNil(ConsoleBridgeMenuPolicy.shortcutCommand(characters: "g", modifiers: [.option, .command]))
        XCTAssertNil(ConsoleMenuRoutingPolicy.shortcutCommand(characters: "a", modifiers: [.option, .command]))
    }

    func testBridgeEquivalentRepeatsAndDuplicateDeliveryDoNotDispatch() {
        for (characters, command) in [("a", ConsoleBridgeMenuCommand.attach), ("d", .detach)] {
            var input = availableBridgeContext(command)
            input.keyboard.modifiers = [.command, .option]
            XCTAssertEqual(ConsoleBridgeMenuPolicy.keyEquivalentCommand(
                characters: characters, context: input, isDuplicateInvocation: false
            ), command)
            input.keyboard.isRepeat = true
            XCTAssertNil(ConsoleBridgeMenuPolicy.keyEquivalentCommand(
                characters: characters, context: input, isDuplicateInvocation: false
            ))
            input.keyboard.isRepeat = false
            XCTAssertNil(ConsoleBridgeMenuPolicy.keyEquivalentCommand(
                characters: characters, context: input, isDuplicateInvocation: true
            ))
        }
    }

    func testBridgeShortcutCannotRelaxEventWindowOrTextFocusChecks() {
        for (characters, command) in [("a", ConsoleBridgeMenuCommand.attach), ("d", .detach)] {
            var input = availableBridgeContext(command)
            input.keyboard.modifiers = [.command, .option]
            input.keyboard.eventBelongsToConsoleWindow = false
            XCTAssertNil(ConsoleBridgeMenuPolicy.keyEquivalentCommand(
                characters: characters, context: input, isDuplicateInvocation: false
            ))
            input.keyboard.eventBelongsToConsoleWindow = true
            input.keyboard.isTextEntryFocused = true
            XCTAssertNil(ConsoleBridgeMenuPolicy.keyEquivalentCommand(
                characters: characters, context: input, isDuplicateInvocation: false
            ))
        }
    }

    func testOpenBridgeMenuAllowsExplicitActionsButPreservesTextShortcutExclusion() {
        for command in bridgeCommands {
            var input = availableBridgeContext(command)
            input.keyboard.isMenuTracking = true
            input.keyboard.isTextEntryFocused = true
            XCTAssertTrue(ConsoleBridgeMenuPolicy.isAvailable(command, context: input))
        }
    }

    func testBridgeShortcutsNeverAlsoDispatchThroughLocalKeyMonitor() {
        for keyCode in shortcutKeyCodes {
            var input = context(keyCode: keyCode)
            input.modifiers = [.option, .command]
            assertCommand(input, is: nil)
            input.isRepeat = true
            XCTAssertFalse(ConsoleKeyboardPolicy.suppressesRepeatedShortcut(input))
        }
    }

    func testConfiguredBridgeGrantRequiresAnAwaitingApprovalIntercept() {
        var input = context(keyCode: 49, status: .armed)
        input.isBridgeConfigured = true
        input.hasPendingApproval = false
        assertCommand(input, is: nil)
        XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(.grantPermissive, context: input))
        input.hasPendingApproval = true
        assertCommand(input, is: .grantPermissive)
        XCTAssertTrue(ConsoleMenuRoutingPolicy.isAvailable(.grantPermissive, context: input))
        input.isTextEntryFocused = true
        assertCommand(input, is: nil)
        input.isTextEntryFocused = false
        input.isConsoleKeyWindow = false
        assertCommand(input, is: nil)
        XCTAssertFalse(ConsoleMenuRoutingPolicy.isAvailable(.grantPermissive, context: input))
    }

    private var bridgeStates: [BridgeConnectionState] { [.detached, .attaching, .attached, .detaching, .failed] }
    private var bridgeCommands: [ConsoleBridgeMenuCommand] { [.attach, .detach, .listTools, .submitTool] }

    private func bridgeContext(state: BridgeConnectionState, status: InterlockStatus) -> ConsoleBridgeMenuContext {
        ConsoleBridgeMenuContext(
            keyboard: context(keyCode: 0, status: status), connectionState: state,
            isBridgeConfigured: true, hasPendingIntercept: false
        )
    }

    private func availableBridgeContext(_ command: ConsoleBridgeMenuCommand) -> ConsoleBridgeMenuContext {
        switch command {
        case .attach: return bridgeContext(state: .detached, status: .locked)
        case .submitTool: return bridgeContext(state: .attached, status: .armed)
        case .detach, .listTools: return bridgeContext(state: .attached, status: .locked)
        }
    }

    private var statuses: [InterlockStatus] { [.locked, .armed, .permissiveGranted, .emergencyAbort] }

    private var menuShortcuts: [(String, ConsoleKeyboardContext.Modifiers, ConsoleCommand)] {
        [
            ("a", [.command], .armGate),
            ("g", [.command, .shift], .grantPermissive),
            (".", [.command], .emergencyAbort),
            ("r", [.command], .resetEmergencyAbort)
        ]
    }

    private func availableStatus(for command: ConsoleCommand) -> InterlockStatus {
        switch command {
        case .grantPermissive: return .armed
        case .resetEmergencyAbort: return .emergencyAbort
        default: return .locked
        }
    }

    private func menuRoute(
        _ characters: String,
        _ input: ConsoleKeyboardContext,
        hasSelectAllResponder: Bool = false
    ) -> ConsoleMenuKeyRoute {
        ConsoleMenuRoutingPolicy.keyEquivalentRoute(
            characters: characters, context: input, hasSelectAllResponder: hasSelectAllResponder
        )
    }

    private func context(keyCode: UInt16, status: InterlockStatus = .armed) -> ConsoleKeyboardContext {
        ConsoleKeyboardContext(
            keyCode: keyCode,
            modifiers: [],
            isRepeat: false,
            isApplicationActive: true,
            isConsoleKeyWindow: true,
            eventBelongsToConsoleWindow: true,
            hasAttachedSheet: false,
            hasModalWindow: false,
            isMenuTracking: false,
            isTextEntryFocused: false,
            isAcceptingCommands: true,
            currentStatus: status
        )
    }

    private func assertCommand(
        _ input: ConsoleKeyboardContext,
        is expected: ConsoleCommand?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            ConsoleKeyboardPolicy.command(for: input), expected,
            "keyCode=\(input.keyCode)", file: file, line: line
        )
    }
}
