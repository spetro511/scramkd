import Foundation
import XCTest
@testable import TacticalVirtualization

final class RFBStreamDecoderTests: XCTestCase {
    func testHandshakeAtEveryByteAndNoncanonicalTrueColor() throws {
        let input = FrameFixtures.version + Data([1, 1, 0, 0, 0, 0]) + FrameFixtures.serverInit()
        var decoder = RFBStreamDecoder()
        var writes: [Data] = []
        var initialized = 0
        for byte in input {
            for event in try decoder.consume(Data([byte])) {
                switch event {
                case .send(let data): writes.append(data)
                case .initialized(let width, let height):
                    initialized += 1; XCTAssertEqual(width, 2); XCTAssertEqual(height, 1)
                case .update: XCTFail("Unsolicited frame")
                }
            }
        }
        XCTAssertEqual(initialized, 1)
        XCTAssertEqual(writes, [FrameFixtures.version, Data([1]), Data([1]), RFBStreamDecoder.pixelFormatAndEncodings])
        XCTAssertEqual(try decoder.requestFullUpdate(), Data([3, 0, 0, 0, 0, 0, 0, 2, 0, 1]))
        XCTAssertThrowsError(try decoder.requestFullUpdate())
    }

    func testRawSplitEveryByteIsAtomicRGBAAndOpaque() throws {
        var decoder = try FrameFixtures.initializedDecoder()
        _ = try decoder.requestFullUpdate()
        let wire = FrameFixtures.update()
        for byte in wire.dropLast() {
            XCTAssertTrue(try decoder.consume(Data([byte])).isEmpty)
        }
        let last = try XCTUnwrap(wire.last)
        let events = try decoder.consume(Data([last]))
        XCTAssertEqual(events.count, 1)
        guard case .update(let pixels)? = events.first else { return XCTFail("Missing complete update") }
        XCTAssertEqual(pixels, Data([3, 2, 1, 255, 6, 5, 4, 255]))
        XCTAssertFalse(decoder.outstandingUpdate)
    }

    func testTiledRectanglesProduceOneFullFrame() throws {
        var decoder = try FrameFixtures.initializedDecoder()
        _ = try decoder.requestFullUpdate()
        let left = FrameFixtures.rect(width: 1, pixels: Data([1, 2, 3, 0]))
        let right = FrameFixtures.rect(x: 1, width: 1, pixels: Data([4, 5, 6, 0]))
        XCTAssertTrue(try decoder.consume(Data([0, 0, 0, 2]) + left).isEmpty)
        let events = try decoder.consume(right)
        guard case .update(let pixels)? = events.first else { return XCTFail("Missing complete tiles") }
        XCTAssertEqual(pixels, Data([3, 2, 1, 255, 6, 5, 4, 255]))
    }

    func testPartialCoverageNeverPublishes() throws {
        var decoder = try FrameFixtures.initializedDecoder()
        _ = try decoder.requestFullUpdate()
        XCTAssertThrowsError(try decoder.consume(FrameFixtures.update(FrameFixtures.rect(width: 1, pixels: Data([0, 0, 0, 0]))))) {
            XCTAssertEqual($0 as? FrameError, .protocolViolation(.incompleteFramebuffer))
        }
    }

    func testBoundsUnsupportedEncodingAndUnsolicitedUpdate() throws {
        for rect in [FrameFixtures.rect(x: 65_535), FrameFixtures.rect(width: 65_535),
                     FrameFixtures.rect(height: 0), FrameFixtures.rect(encoding: -223),
                     FrameFixtures.rect(encoding: 5)] {
            var decoder = try FrameFixtures.initializedDecoder()
            _ = try decoder.requestFullUpdate()
            XCTAssertThrowsError(try decoder.consume(FrameFixtures.update(rect)))
        }
        var decoder = try FrameFixtures.initializedDecoder()
        XCTAssertThrowsError(try decoder.consume(Data([0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? FrameError, .protocolViolation(.unsolicitedUpdate))
        }
    }

    func testSecurityVersionDimensionsAndNameFailTyped() throws {
        var version = RFBStreamDecoder()
        XCTAssertThrowsError(try version.consume(Data("RFB 003.003\n".utf8))) {
            XCTAssertEqual($0 as? FrameError, .unsupportedVersion)
        }
        var auth = RFBStreamDecoder()
        XCTAssertThrowsError(try auth.consume(FrameFixtures.version + Data([2, 2, 19]))) {
            XCTAssertEqual($0 as? FrameError, .unsupportedSecurity([2, 19]))
        }
        var rejected = RFBStreamDecoder()
        XCTAssertThrowsError(try rejected.consume(FrameFixtures.version + Data([1, 1, 0, 0, 0, 1]))) {
            XCTAssertEqual($0 as? FrameError, .securityRejected)
        }
        for server in [FrameFixtures.serverInit(width: 0), FrameFixtures.serverInit(width: 4097),
                       FrameFixtures.serverInit(width: 4096, height: 4096),
                       FrameFixtures.serverInit(trueColor: 0),
                       FrameFixtures.serverInit(name: Data([0xff])),
                       FrameFixtures.serverInit(name: Data(repeating: 65, count: 4097))] {
            var decoder = RFBStreamDecoder()
            XCTAssertThrowsError(try decoder.consume(FrameFixtures.version + Data([1, 1, 0, 0, 0, 0]) + server))
        }
    }

    func testClipboardDiscardBellBoundsAndEmptyResponse() throws {
        var decoder = try FrameFixtures.initializedDecoder()
        _ = try decoder.requestFullUpdate()
        let clipboard = Data([3, 0, 0, 0, 0, 0, 0, 3, 0xff, 0, 42])
        XCTAssertTrue(try decoder.consume(Data([2]) + clipboard).isEmpty)
        let events = try decoder.consume(Data([0, 0, 0, 0]))
        guard case .update(let pixels)? = events.first else { return XCTFail("Missing empty response") }
        XCTAssertNil(pixels)
        _ = try decoder.requestFullUpdate()
        XCTAssertThrowsError(try decoder.consume(Data(repeating: 2, count: 17)))
        var oversized = try FrameFixtures.initializedDecoder()
        XCTAssertThrowsError(try oversized.consume(Data([3, 0, 0, 0]) + FrameFixtures.u32(65_537))) {
            XCTAssertEqual($0 as? FrameError, .limitExceeded(.clipboardBytes))
        }
    }

    func testRectangleCountEOFAndCancellation() throws {
        var decoder = try FrameFixtures.initializedDecoder()
        _ = try decoder.requestFullUpdate()
        XCTAssertThrowsError(try decoder.consume(Data([0, 0, 4, 1]))) {
            XCTAssertEqual($0 as? FrameError, .limitExceeded(.rectangles))
        }
        var truncated = try FrameFixtures.initializedDecoder()
        _ = try truncated.requestFullUpdate()
        _ = try truncated.consume(Data([0, 0]))
        XCTAssertThrowsError(try truncated.endOfStream()) {
            XCTAssertEqual($0 as? FrameError, .protocolViolation(.truncated))
        }
        var cancelled = try FrameFixtures.initializedDecoder()
        _ = try cancelled.requestFullUpdate()
        XCTAssertThrowsError(try cancelled.consume(FrameFixtures.update()) { throw FrameError.cancelled })
    }

    func testRGBAInitializerRejectsStrideAlphaAndAllocationOverflow() throws {
        let generation = UUID(), now = ContinuousClock.now
        let valid = try RGBAFrame(generation: generation, sequence: 1, width: 1, height: 1,
            bytesPerRow: 4, pixels: Data([1, 2, 3, 255]), receivedAt: now)
        XCTAssertEqual(valid.colorEncoding, .assumedSRGB)
        XCTAssertThrowsError(try RGBAFrame(generation: generation, sequence: 0, width: 1, height: 1,
            bytesPerRow: 4, pixels: valid.pixels, receivedAt: now))
        XCTAssertThrowsError(try RGBAFrame(generation: generation, sequence: 1, width: 1, height: 1,
            bytesPerRow: 8, pixels: valid.pixels, receivedAt: now))
        XCTAssertThrowsError(try RGBAFrame(generation: generation, sequence: 1, width: 1, height: 1,
            bytesPerRow: 4, pixels: Data([1, 2, 3, 0]), receivedAt: now))
        XCTAssertThrowsError(try FrameLimits.frameBytes(width: Int.max, height: Int.max))
    }

    func testAggregateBudgetAndByteQueueRejectBeforeGrowing() throws {
        var decoder = RFBStreamDecoder(updateByteLimit: 20)
        _ = try decoder.consume(FrameFixtures.version + Data([1, 1, 0, 0, 0, 0]) + FrameFixtures.serverInit())
        _ = try decoder.requestFullUpdate()
        XCTAssertThrowsError(try decoder.consume(FrameFixtures.update())) {
            XCTAssertEqual($0 as? FrameError, .limitExceeded(.updateBytes))
        }
        var bytes = FrameByteQueue()
        try bytes.append(Data([1, 2, 3]), limit: 4)
        XCTAssertThrowsError(try bytes.append(Data([4, 5]), limit: 4))
        XCTAssertEqual(bytes.count, 3)
    }

    func testEOFWithoutResponseDiffersFromPartialMessage() throws {
        var decoder = try FrameFixtures.initializedDecoder()
        _ = try decoder.requestFullUpdate()
        XCTAssertThrowsError(try decoder.endOfStream()) { XCTAssertEqual($0 as? FrameError, .endOfStream) }
        _ = try decoder.consume(Data([0]))
        XCTAssertThrowsError(try decoder.endOfStream()) {
            XCTAssertEqual($0 as? FrameError, .protocolViolation(.truncated))
        }
    }
}
