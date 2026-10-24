import XCTest
@testable import ScramKCore

final class TelemetryFrameTests: XCTestCase {
    func testTelemetryFrameEncodingAndDecoding() throws {
        let frame = TelemetryFrame(
            timestampNanoseconds: 123456789,
            sequenceNumber: 42,
            subsystem: .interlock,
            health: .nominal,
            interlockState: .permissiveGranted,
            payloadSize: 256
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TelemetryFrame.self, from: data)

        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.subsystem, .interlock)
        XCTAssertEqual(decoded.health, .nominal)
        XCTAssertEqual(decoded.interlockState, .permissiveGranted)
    }

    func testSubsystemIdentifierDescriptions() {
        XCTAssertEqual(SubsystemIdentifier.core.description, "CORE")
        XCTAssertEqual(SubsystemIdentifier.interlock.description, "INTERLOCK")
        XCTAssertEqual(SubsystemIdentifier.audioSVS.description, "AUDIO_SVS")
        XCTAssertEqual(SubsystemIdentifier.virtualization.description, "VIRT")
        XCTAssertEqual(SubsystemIdentifier.ui.description, "UI")
    }
}
