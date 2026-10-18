import XCTest
import TacticalCore
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
