import XCTest
import ScramKCore
@testable import ScramKAudio

final class LocalVoiceCommanderTests: XCTestCase {

    func testVoiceCommanderInitializationSafety() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let commander = LocalVoiceCommander(interlockGate: gate)

        let status = await gate.currentStatus
        XCTAssertEqual(status, .locked)

        // Ensure clean stop on dormant engine produces no side-effects or errors
        await commander.stopPTT()
        let postStatus = await gate.currentStatus
        XCTAssertEqual(postStatus, .locked)
    }

    func testDeterministicTokenEvaluationTransitionsGate() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let commander = LocalVoiceCommander(interlockGate: gate)

        await commander.evaluateScramKTokens("SYSTEM ARM")
        let armedStatus = await gate.currentStatus
        XCTAssertEqual(armedStatus, .armed)

        await commander.evaluateScramKTokens("REQUEST GRANT")
        let permissiveStatus = await gate.currentStatus
        XCTAssertEqual(permissiveStatus, .permissiveGranted)

        await commander.evaluateScramKTokens("EMERGENCY ABORT")
        let abortStatus = await gate.currentStatus
        XCTAssertEqual(abortStatus, .emergencyAbort)
    }

    // MARK: - SYS-04: Negation Phrase Filtering

    func testVoiceCommanderNegationPhraseFiltering() async throws {
        let gate = HardwareInterlockGate(initialStatus: .locked)
        let commander = LocalVoiceCommander(interlockGate: gate)

        // 1. Negated ARM commands must not arm the gate
        await commander.evaluateScramKTokens("DO NOT ARM")
        var status = await gate.currentStatus
        XCTAssertEqual(status, .locked)

        await commander.evaluateScramKTokens("NEVER ARM")
        status = await gate.currentStatus
        XCTAssertEqual(status, .locked)

        await commander.evaluateScramKTokens("DONT ARM")
        status = await gate.currentStatus
        XCTAssertEqual(status, .locked)

        await commander.evaluateScramKTokens("CANCEL ARM")
        status = await gate.currentStatus
        XCTAssertEqual(status, .locked)

        // 2. Legitimate ARM command succeeds
        await commander.evaluateScramKTokens("SUPERVISOR ARM")
        status = await gate.currentStatus
        XCTAssertEqual(status, .armed)

        // 3. Negated GRANT commands must not grant permissive
        await commander.evaluateScramKTokens("DO NOT GRANT")
        status = await gate.currentStatus
        XCTAssertEqual(status, .armed)

        await commander.evaluateScramKTokens("NEVER GRANT")
        status = await gate.currentStatus
        XCTAssertEqual(status, .armed)

        await commander.evaluateScramKTokens("STOP GRANT")
        status = await gate.currentStatus
        XCTAssertEqual(status, .armed)

        // 4. Legitimate GRANT succeeds
        await commander.evaluateScramKTokens("REQUEST GRANT")
        status = await gate.currentStatus
        XCTAssertEqual(status, .permissiveGranted)

        // 5. Emergency ABORT always trips fail-safe
        await commander.evaluateScramKTokens("EMERGENCY ABORT")
        status = await gate.currentStatus
        XCTAssertEqual(status, .emergencyAbort)
    }
}
