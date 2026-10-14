import XCTest
import TacticalCore
@testable import TacticalAudioSVS

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

        await commander.evaluateTacticalTokens("SYSTEM ARM")
        let armedStatus = await gate.currentStatus
        XCTAssertEqual(armedStatus, .armed)

        await commander.evaluateTacticalTokens("REQUEST GRANT")
        let permissiveStatus = await gate.currentStatus
        XCTAssertEqual(permissiveStatus, .permissiveGranted)

        await commander.evaluateTacticalTokens("EMERGENCY ABORT")
        let abortStatus = await gate.currentStatus
        XCTAssertEqual(abortStatus, .emergencyAbort)
    }
}
