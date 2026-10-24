import Foundation
import XCTest
@testable import ScramKVirtualization

final class MCPJSONCodecTests: XCTestCase {
    func testExactMetadataAllowlist() throws {
        XCTAssertEqual(try MCPJSONCodec.publicRequest(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)), .ping)
        XCTAssertEqual(try MCPJSONCodec.publicRequest(Data(#"{"jsonrpc":"2.0","id":"p","method":"ping","params":{}}"#.utf8)), .ping)
        XCTAssertEqual(try MCPJSONCodec.publicRequest(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"next"}}"#.utf8)), .listTools(cursor: "next"))
    }

    func testAllToolCallsArePrivilegedRegardlessOfName() throws {
        for name in ["screenshot", "get_screen_size", "click", "run_command", "unknown"] {
            let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":{}}}"
            XCTAssertEqual(try MCPJSONCodec.publicRequest(Data(payload.utf8)), .tool(name: name, arguments: .object([:])))
        }
    }

    func testForgedClassificationAndOriginAreRejected() {
        let values = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping","isHighRiskAction":false}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"ping","originPID":1}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"method":"click"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":{},"originPID":1}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click","arguments":{},"isHighRiskAction":false}}"#
        ]
        for value in values { XCTAssertThrowsError(try MCPJSONCodec.publicRequest(Data(value.utf8))) }
    }

    func testDuplicateKeysIncludingEscapedDiscriminatorsAreRejected() {
        let values = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/call"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"ping","\u006dethod":"tools/call"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click","arguments":{"x":1,"\u0078":2}}}"#,
            #"{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}"#
        ]
        for value in values { XCTAssertThrowsError(try MCPJSONCodec.publicRequest(Data(value.utf8))) }
    }

    func testBatchesNotificationsBootstrapAndNewlineSmugglingAreRejected() {
        let values = [
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
            #"{"jsonrpc":"2.0","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/call"}"#
        ]
        for value in values { XCTAssertThrowsError(try MCPJSONCodec.publicRequest(Data(value.utf8))) }
    }

    func testInvalidIDsMalformedNumbersAndUTF8AreRejected() {
        for id in ["null", "true", "[]", "{}", "1.5", "1e2", "9007199254740992", "01"] {
            let payload = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}"
            XCTAssertThrowsError(try MCPJSONCodec.publicRequest(Data(payload.utf8)))
        }
        XCTAssertThrowsError(try MCPJSONCodec.decode(Data([0xFF])))
        XCTAssertThrowsError(try MCPJSONCodec.decode(Data(#"{"x":"\uD800"}"#.utf8)))
    }

    func testLimitsBeforeForwarding() throws {
        let cursor = String(repeating: "a", count: BridgeLimits.cursorBytes + 1)
        let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"cursor\":\"\(cursor)\"}}"
        XCTAssertThrowsError(try MCPJSONCodec.publicRequest(Data(payload.utf8)))
        XCTAssertThrowsError(try MCPJSONCodec.validateToolName(String(repeating: "x", count: 257)))
        XCTAssertThrowsError(try MCPJSONCodec.publicRequest(Data(repeating: 0x20, count: BridgeLimits.requestBytes)))
        let nested = String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)
        XCTAssertThrowsError(try MCPJSONCodec.decode(Data(nested.utf8)))
        let exact = String(repeating: "[", count: 32) + String(repeating: "]", count: 32)
        XCTAssertNoThrow(try MCPJSONCodec.decode(Data(exact.utf8)))
        let tooDeep = String(repeating: "[", count: 33) + String(repeating: "]", count: 33)
        XCTAssertThrowsError(try MCPJSONCodec.decode(Data(tooDeep.utf8)))
    }

    func testCompactFrozenFrameEscapesTextAndEndsInOneLF() throws {
        let id = UUID()
        let args: MCPJSONValue = .object(["text": .string("first\nsecond\"\\😀")])
        let frame = try MCPJSONCodec.frame(id: id, method: "tools/call", params: .object(["name": .string("type"), "arguments": args]))
        XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(frame.last, 0x0A)
        let object = try XCTUnwrap(try MCPJSONCodec.decode(Data(frame.dropLast())).object)
        XCTAssertEqual(object["id"], .string(id.uuidString))
        XCTAssertEqual(object["params"]?.object?["arguments"], args)
        XCTAssertEqual(frame, try MCPJSONCodec.frame(id: id, method: "tools/call", params: .object(["arguments": args, "name": .string("type")])))
    }

    func testFragmentsCoalescedLinesAndUTF8ByteBoundaries() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":"😀","result":{}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
        let wire = first + Data([0x0A]) + second + Data([0x0A])
        var framer = MCPLineFramer()
        var lines: [Data] = []
        for byte in wire { lines.append(contentsOf: try framer.append(Data([byte]))) }
        XCTAssertEqual(lines, [first, second])
        XCTAssertFalse(framer.hasPartialLine)
        var coalesced = MCPLineFramer()
        XCTAssertEqual(try coalesced.append(wire), [first, second])
    }

    func testLineLimitAndEmptyFramesFailClosed() {
        var framer = MCPLineFramer()
        XCTAssertThrowsError(try framer.append(Data([0x0A])))
        var bounded = MCPLineFramer()
        XCTAssertThrowsError(try bounded.append(Data(repeating: 0x41, count: BridgeLimits.responseBytes + 1)))
        var notifications = MCPLineFramer()
        XCTAssertThrowsError(try notifications.append(Data(String(repeating: "{}\n", count: 257).utf8)))
    }
}
