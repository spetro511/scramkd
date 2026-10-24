import Darwin
import Foundation
import os
import XCTest
@testable import ScramKVirtualization

final class FrameWebSocketTests: XCTestCase {
    func testRFCHandshakeAcceptAndFixedRequest() throws {
        let nonce = "dGhlIHNhbXBsZSBub25jZQ=="
        XCTAssertEqual(FrameHTTPUpgrade.accept(for: nonce), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        try FrameHTTPUpgrade.validate(FrameFixtures.response(nonce: nonce), nonce: nonce)
        let request = try XCTUnwrap(String(data: FrameHTTPUpgrade.request(nonce: nonce), encoding: .ascii))
        XCTAssertTrue(request.hasPrefix("GET /websockify HTTP/1.1\r\nHost: 127.0.0.1:7860\r\n"))
        XCTAssertFalse(request.contains("CONNECT"))
        XCTAssertFalse(request.contains("Authorization"))
        XCTAssertFalse(request.contains("Sec-WebSocket-Extensions"))
        XCTAssertFalse(request.contains("Sec-WebSocket-Protocol"))
        // Proxy environment is neither read nor changed by this contract.
    }

    func testBadAcceptRedirectProtocolAndExtensionsFail() throws {
        let nonce = "fixture"
        for data in [FrameFixtures.response(nonce: nonce, status: 301, extra: "Location: http://example.invalid/\r\n"),
                     FrameFixtures.response(nonce: nonce, status: 407),
                     FrameFixtures.response(nonce: nonce, accept: "wrong"),
                     FrameFixtures.response(nonce: nonce, extra: "Sec-WebSocket-Extensions: permessage-deflate\r\n"),
                     FrameFixtures.response(nonce: nonce, extra: "Sec-WebSocket-Protocol: binary\r\n"),
                     FrameFixtures.response(nonce: nonce, extra: "Sec-WebSocket-Accept: duplicate\r\n"),
                     FrameFixtures.response(nonce: nonce, extra: "Transfer-Encoding: chunked\r\n")] {
            XCTAssertThrowsError(try FrameHTTPUpgrade.validate(data, nonce: nonce))
        }
    }

    func testSplitBinaryAndFragmentationWithInterleavedPing() throws {
        var codec = FrameWebSocketCodec()
        let wire = FrameFixtures.serverFrame(final: false, payload: Data([1, 2])) +
            FrameFixtures.serverFrame(opcode: 9, payload: Data([7])) +
            FrameFixtures.serverFrame(opcode: 0, payload: Data([3, 4]))
        var events: [FrameWebSocketEvent] = []
        for byte in wire {
            try codec.append(Data([byte]))
            while let event = try codec.next() { events.append(event) }
        }
        XCTAssertEqual(events, [.ping(Data([7])), .binary(Data([1, 2, 3, 4]))])
    }

    func testFrameRulesRejectMaskRSVTextControlAndLengths() throws {
        let invalid: [Data] = [
            Data([0x82, 0x80, 0, 0, 0, 0]), // Server masking.
            Data([0xc2, 0]), // RSV bit.
            Data([0x81, 0]), // Text.
            Data([0x09, 0]), // Fragmented control.
            Data([0x89, 126, 0, 126]), // Oversized control (payload not needed to reject).
            Data([0x82, 126, 0, 1]), // Noncanonical extended length.
            Data([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]), // Signed length.
            Data([0x80, 0]), // Continuation without an open message.
            Data([0x82, 127, 0, 0, 0, 0, 4, 0, 0, 1]) // >64 MiB.
        ]
        for wire in invalid {
            var codec = FrameWebSocketCodec()
            try codec.append(wire)
            XCTAssertThrowsError(try codec.next(), "\(wire as NSData)")
        }
        var overlapping = FrameWebSocketCodec()
        try overlapping.append(FrameFixtures.serverFrame(final: false, payload: Data()) +
                               FrameFixtures.serverFrame(payload: Data()))
        XCTAssertThrowsError(try overlapping.next())
    }

    func testCloseValidationAndTruncatedEOF() throws {
        for payload in [Data([1]), Data([3, 237]), Data([3, 232, 0xff])] {
            XCTAssertThrowsError(try FrameWebSocketCodec.validateClose(payload))
        }
        try FrameWebSocketCodec.validateClose(Data([3, 232]))
        var codec = FrameWebSocketCodec()
        try codec.append(Data([0x82, 4, 1]))
        XCTAssertNil(try codec.next())
        XCTAssertThrowsError(try codec.endOfStream())
        var closed = FrameWebSocketCodec()
        try closed.append(FrameFixtures.serverFrame(opcode: 8, payload: Data([3, 232])))
        XCTAssertEqual(try closed.next(), .close(Data([3, 232])))
        XCTAssertThrowsError(try closed.append(Data([0x82, 0])))
    }

    func testAggregateFragmentLimitRejectsHeaderBeforeAllocatingPayload() throws {
        var codec = FrameWebSocketCodec()
        try codec.append(FrameFixtures.serverFrame(final: false, payload: Data([1])))
        XCTAssertNil(try codec.next())
        // Continuation declares exactly 64 MiB, which would exceed the aggregate
        // by one byte; no 64-MiB test allocation is needed.
        try codec.append(Data([0x80, 127, 0, 0, 0, 0, 4, 0, 0, 0]))
        XCTAssertThrowsError(try codec.next()) { XCTAssertEqual($0 as? FrameError, .limitExceeded(.messageBytes)) }
    }

    func testClientMaskingAndPayloadRoundTrip() throws {
        let mask = Data([1, 2, 3, 4]), payload = Data([3, 0, 0, 0, 0, 0, 0, 2, 0, 1])
        let frame = try FrameWebSocketCodec.clientFrame(opcode: 2, payload: payload, mask: mask)
        XCTAssertEqual(frame[0], 0x82); XCTAssertEqual(frame[1], 0x8a)
        XCTAssertEqual(frame.subdata(in: 2..<6), mask)
        let decoded = Data(frame.dropFirst(6).enumerated().map { $0.element ^ mask[$0.offset & 3] })
        XCTAssertEqual(decoded, payload)
        XCTAssertThrowsError(try FrameWebSocketCodec.clientFrame(opcode: 1, payload: payload, mask: mask))
    }

    func testHTTPPartialHeadersPreserveCoalescedBinaryAndPing() async throws {
        let pair = try FrameSocketPair()
        let nonce = Data(repeating: 7, count: 16).base64EncodedString()
        let headers = FrameFixtures.response(nonce: nonce)
        let chunks = FrameReadScript([
            Data(headers.prefix(7)), Data(headers.dropFirst(7)) +
                FrameFixtures.serverFrame(opcode: 9, payload: Data([42])) +
                FrameFixtures.serverFrame(payload: FrameFixtures.version)
        ])
        let writes = FrameWriteScript()
        let wouldBlock = OSAllocatedUnfairLock(initialState: true)
        var calls = pair.calls
        calls.read = { _, _ in chunks.next() }
        calls.write = { _, data, offset in
            let blocked = wouldBlock.withLock { state in let old = state; state = false; return old }
            if blocked { return nil }
            return writes.write(data, offset: offset, maximum: 3)
        }
        let socket = FrameSocketIO(calls: calls)
        let transport = FrameWebSocketTransport(socket: socket, random: { Data(repeating: 7, count: $0) })
        let lifecycle = FrameTestSession(release: { transport.retire() }, cleanup: {
            try await transport.close(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        })
        try await lifecycle.run { _ in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            try await transport.open(deadline: deadline)
            let banner = try await transport.receiveBinary(deadline: deadline, stage: .handshake)
            XCTAssertEqual(banner, FrameFixtures.version)
            let request = FrameHTTPUpgrade.request(nonce: nonce)
            XCTAssertEqual(writes.data.prefix(request.count), request)
            let pong = try FrameWebSocketCodec.clientFrame(opcode: 10, payload: Data([42]), mask: Data(repeating: 7, count: 4))
            XCTAssertEqual(writes.data.dropFirst(request.count), pong)
            try await transport.close(deadline: deadline)
        }
        XCTAssertEqual(pair.closeCount, 1)
        XCTAssertEqual(lifecycle.ownedTaskCount, 0)
    }

    func testActualDeadlinePreventsAnyOpenSyscall() async throws {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var calls = FrameSocketSyscalls.live
        calls.open = { counter.withLock { $0 += 1 }; throw FrameError.systemCall(code: EIO) }
        let io = FrameSocketIO(calls: calls)
        try await FrameTestSession(release: { io.beginClose() }, cleanup: {
            try await io.close(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        }).run { _ in
            do {
                try await io.connect(deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
                XCTFail("Expired operation opened an FD")
            } catch { XCTAssertEqual(error as? FrameError, .timedOut(.connect)) }
            XCTAssertEqual(counter.withLock { $0 }, 0)
            try await io.close(deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        }
    }

    func testConnectChecksSOErrorAndClosesOwnedFDOnce() async throws {
        let pair = try FrameSocketPair()
        var calls = pair.calls
        calls.connect = { _ in false } // Exercise writable readiness before SO_ERROR.
        calls.checkConnect = { _ in throw FrameError.systemCall(code: ECONNREFUSED) }
        let io = FrameSocketIO(calls: calls)
        try await FrameTestSession(release: { io.beginClose() }, cleanup: {
            try await io.close(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        }).run { _ in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            do { try await io.connect(deadline: deadline); XCTFail("Ignored SO_ERROR") }
            catch { XCTAssertEqual(error as? FrameError, .systemCall(code: ECONNREFUSED)) }
            try await io.close(deadline: deadline)
            try await io.close(deadline: deadline)
        }
        XCTAssertEqual(pair.closeCount, 1)
    }

    func testCancelReadAndQuiescentCloseNeverUsesClosedFD() async throws {
        let pair = try FrameSocketPair()
        let readEntered = FrameCompletion<Void>()
        let violations = OSAllocatedUnfairLock(initialState: 0)
        var calls = pair.calls
        let liveRead = calls.read
        calls.read = { fd, count in
            if pair.closeCount > 0 { violations.withLock { $0 += 1 } }
            readEntered.finish(.success(()))
            return try liveRead(fd, count)
        }
        let io = FrameSocketIO(calls: calls)
        let lifecycle = FrameTestSession(release: { io.beginClose() }, cleanup: {
            try await io.close(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        })
        try await lifecycle.run { session in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            try await io.connect(deadline: deadline)
            let read = try session.spawn(label: "socket read") {
                do { return try await io.read(deadline: deadline, stage: .update) }
                catch {
                    // Failure before entering recv must also release its barrier.
                    readEntered.finish(.failure(frameError(error)))
                    throw error
                }
            }
            try await session.wait(readEntered, label: "recv entered")
            read.cancel()
            try await io.close(deadline: deadline)
            do { _ = try await read.value(); XCTFail("Cancelled read succeeded") }
            catch { XCTAssertTrue(error is CancellationError || error as? FrameError == .cancelled) }
        }
        XCTAssertEqual(pair.closeCount, 1)
        XCTAssertEqual(violations.withLock { $0 }, 0)
        XCTAssertEqual(lifecycle.ownedTaskCount, 0)
    }

    func testReadChecksActualDeadlineAfterSyscallWithoutTimerRace() async throws {
        let pair = try FrameSocketPair()
        let clock = FrameTestClock()
        var calls = pair.calls
        calls.read = { _, _ in clock.advance(.seconds(2)); return Data([42]) }
        let io = FrameSocketIO(calls: calls, timing: clock.timing)
        try await FrameTestSession(clock: clock, release: { io.beginClose() }, cleanup: {
            try await io.close(deadline: clock.now.advanced(by: .seconds(1)))
        }).run { _ in
            try await io.connect(deadline: clock.now.advanced(by: .seconds(1)))
            do {
                _ = try await io.read(deadline: clock.now.advanced(by: .seconds(1)), stage: .update)
                XCTFail("Accepted late bytes")
            } catch { XCTAssertEqual(error as? FrameError, .timedOut(.update)) }
            try await io.close(deadline: clock.now.advanced(by: .seconds(1)))
        }
        XCTAssertEqual(pair.closeCount, 1)
    }

    func testCloseFailureIsReportedAndNeverRetriesDescriptorNumber() async throws {
        let pair = try FrameSocketPair()
        var calls = pair.calls
        let close = calls.close
        calls.close = { fd in _ = close(fd); return EIO }
        let io = FrameSocketIO(calls: calls)
        try await FrameTestSession(release: { io.beginClose() }, cleanup: {
            do {
                try await io.close(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
                XCTFail("Expected retained close failure during cleanup")
            } catch {
                guard error as? FrameError == .systemCall(code: EIO) else { throw error }
            }
        }).run { _ in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            try await io.connect(deadline: deadline)
            for _ in 0..<2 {
                do { try await io.close(deadline: deadline); XCTFail("Suppressed close failure") }
                catch { XCTAssertEqual(error as? FrameError, .systemCall(code: EIO)) }
            }
        }
        XCTAssertEqual(pair.closeCount, 1)
    }
}

/// AF_UNIX socketpair is offline; the fixture never contacts a network target.
private final class FrameSocketPair: Sendable {
    let owned: Int32
    let peer: Int32
    private let closes = OSAllocatedUnfairLock(initialState: 0)
    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw FrameError.systemCall(code: errno)
        }
        owned = descriptors[0]; peer = descriptors[1]
        guard fcntl(owned, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno; _ = Darwin.close(owned); _ = Darwin.close(peer)
            throw FrameError.systemCall(code: code)
        }
    }
    deinit {
        if closeCount == 0 { _ = Darwin.close(owned) }
        _ = Darwin.close(peer)
    }
    var closeCount: Int { closes.withLock { $0 } }
    var calls: FrameSocketSyscalls {
        var calls = FrameSocketSyscalls.live
        calls.open = { [self] in owned }
        calls.connect = { _ in true }
        calls.checkConnect = { _ in }
        calls.close = { [self] fd in
            closes.withLock { $0 += 1 }
            return Darwin.close(fd) == 0 ? nil : errno
        }
        return calls
    }
}

private final class FrameReadScript: Sendable {
    private let chunks: OSAllocatedUnfairLock<[Data]>
    init(_ chunks: [Data]) { self.chunks = OSAllocatedUnfairLock(initialState: chunks) }
    func next() -> Data { chunks.withLock { $0.isEmpty ? Data() : $0.removeFirst() } }
}

private final class FrameWriteScript: Sendable {
    private let bytes = OSAllocatedUnfairLock(initialState: Data())
    var data: Data { bytes.withLock { $0 } }
    func write(_ data: Data, offset: Int, maximum: Int) -> Int {
        let count = min(maximum, data.count - offset)
        bytes.withLock { $0.append(data.subdata(in: offset..<(offset + count))) }
        return count
    }
}
