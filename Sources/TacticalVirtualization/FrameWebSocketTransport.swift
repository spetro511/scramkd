import CryptoKit
import Foundation
import Security

protocol FrameWireTransport: Sendable {
    func open(deadline: ContinuousClock.Instant) async throws
    func sendBinary(_ data: Data, deadline: ContinuousClock.Instant) async throws
    func receiveBinary(deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) async throws -> Data?
    func retire()
    func close(deadline: ContinuousClock.Instant) async throws
}

enum FrameHTTPUpgrade {
    static func request(nonce: String) -> Data {
        Data(("GET /websockify HTTP/1.1\r\n" +
              "Host: 127.0.0.1:7860\r\n" +
              "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
              "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(nonce)\r\n\r\n").utf8)
    }

    static func accept(for nonce: String) -> String {
        let bytes = Data((nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        // SHA-1 is required by RFC6455's handshake, NOT used for authentication.
        return Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
    }

    static func validate(_ data: Data, nonce: String) throws {
        guard data.count <= FrameLimits.httpHeaders,
              data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: data, encoding: .ascii), text.hasSuffix("\r\n\r\n") else {
            throw FrameError.protocolViolation(.httpHeaders)
        }
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "")
        guard !unfolded.contains("\r"), !unfolded.contains("\n") else {
            throw FrameError.protocolViolation(.httpHeaders)
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw FrameError.protocolViolation(.httpStatus) }
        let status = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1].count == 3,
              status[1].allSatisfy({ $0.isASCII && $0.isNumber }), let code = Int(status[1]) else {
            throw FrameError.protocolViolation(.httpStatus)
        }
        guard code == 101 else { throw FrameError.httpRejected(status: code) } // Never follow 3xx.
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw FrameError.protocolViolation(.httpHeaders)
            }
            let name = String(line[..<colon]).lowercased()
            let tokenCharacters = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
            guard name.allSatisfy({ tokenCharacters.contains($0) }), headers[name] == nil else {
                throw FrameError.protocolViolation(.httpHeaders)
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func tokens(_ name: String) -> [String] {
            (headers[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        guard tokens("upgrade") == ["websocket"], tokens("connection").contains("upgrade") else {
            throw FrameError.protocolViolation(.httpHeaders)
        }
        guard headers["sec-websocket-accept"] == accept(for: nonce) else {
            throw FrameError.protocolViolation(.webSocketAccept)
        }
        guard headers["sec-websocket-extensions"] == nil else {
            throw FrameError.protocolViolation(.webSocketExtensions)
        }
        guard headers["sec-websocket-protocol"] == nil else {
            throw FrameError.protocolViolation(.webSocketSubprotocol)
        }
        guard headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else {
            throw FrameError.protocolViolation(.httpHeaders)
        }
    }
}

enum FrameWebSocketEvent: Equatable {
    case binary(Data), ping(Data), pong, close(Data)
}

/// Private RFC6455 subset. No extensions, text, compression or subprotocols.
struct FrameWebSocketCodec {
    private var bytes = FrameByteQueue()
    private var fragment: Data?
    private var fragments = 0
    private(set) var sawClose = false

    mutating func append(_ data: Data) throws {
        guard !sawClose else { throw FrameError.protocolViolation(.webSocketClose) }
        // Header allowance is separate from the 64-MiB reassembled-message cap.
        try bytes.append(data, limit: FrameLimits.bytes + 14 + FrameLimits.socketChunk)
    }

    mutating func next() throws -> FrameWebSocketEvent? {
        while bytes.count >= 2 {
            let first = bytes[0], second = bytes[1]
            let final = first & 0x80 != 0, opcode = first & 0x0f
            guard first & 0x70 == 0, second & 0x80 == 0 else {
                throw FrameError.protocolViolation(.webSocketFrame)
            }
            guard [UInt8(0), 1, 2, 8, 9, 10].contains(opcode) else {
                throw FrameError.protocolViolation(.webSocketFrame)
            }
            var header = 2
            var length = UInt64(second & 0x7f)
            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = UInt64(bytes.u16(2)); header = 4
                guard length >= 126 else { throw FrameError.protocolViolation(.webSocketLength) }
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                guard bytes[2] & 0x80 == 0 else { throw FrameError.protocolViolation(.webSocketLength) }
                length = UInt64(bytes.u32(2)) << 32 | UInt64(bytes.u32(6)); header = 10
                guard length >= 65_536 else { throw FrameError.protocolViolation(.webSocketLength) }
            }
            let control = opcode >= 8
            guard !control || (final && length <= 125) else {
                throw FrameError.protocolViolation(.webSocketFrame)
            }
            guard length <= UInt64(FrameLimits.bytes) else { throw FrameError.limitExceeded(.messageBytes) }
            let count = Int(length)
            if opcode == 1 { throw FrameError.protocolViolation(.webSocketText) }
            if opcode == 0 {
                guard let fragment else { throw FrameError.protocolViolation(.webSocketFragmentation) }
                guard fragments < 1024, fragment.count <= FrameLimits.bytes - count else {
                    throw FrameError.limitExceeded(.messageBytes)
                }
            } else if opcode == 2, fragment != nil {
                throw FrameError.protocolViolation(.webSocketFragmentation)
            }
            guard bytes.count >= header + count else { return nil }
            bytes.drop(header)
            let payload = bytes.take(count)
            switch opcode {
            case 0:
                guard var accumulated = fragment else { throw FrameError.protocolViolation(.webSocketFragmentation) }
                fragments += 1
                guard fragments <= 1024, accumulated.count <= FrameLimits.bytes - count else {
                    throw FrameError.limitExceeded(.messageBytes)
                }
                // Release the stored COW reference before appending.
                fragment = nil
                accumulated.append(payload)
                if final { fragments = 0; return .binary(accumulated) }
                fragment = accumulated
            case 1: throw FrameError.protocolViolation(.webSocketText)
            case 2:
                guard fragment == nil else { throw FrameError.protocolViolation(.webSocketFragmentation) }
                if final { return .binary(payload) }
                fragment = payload; fragments = 1
            case 8:
                try Self.validateClose(payload)
                sawClose = true
                fragment = nil
                return .close(payload)
            case 9: return .ping(payload)
            case 10: return .pong
            default: throw FrameError.protocolViolation(.webSocketFrame)
            }
        }
        return nil
    }

    func endOfStream() throws {
        guard bytes.count == 0, fragment == nil else { throw FrameError.protocolViolation(.truncated) }
    }

    static func validateClose(_ data: Data) throws {
        guard data.count != 1 else { throw FrameError.protocolViolation(.webSocketClose) }
        guard data.count >= 2 else { return }
        let code = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let standard = (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code)
        guard standard || (3000...4999).contains(code),
              String(data: data.dropFirst(2), encoding: .utf8) != nil else {
            throw FrameError.protocolViolation(.webSocketClose)
        }
    }

    static func clientFrame(opcode: UInt8, payload: Data, mask: Data) throws -> Data {
        guard [UInt8(2), 8, 10].contains(opcode), mask.count == 4,
              payload.count <= 512, opcode == 2 || payload.count <= 125 else {
            throw FrameError.protocolViolation(.webSocketFrame)
        }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else { frame.append(contentsOf: [0xfe, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        frame.append(mask)
        for (index, byte) in payload.enumerated() { frame.append(byte ^ mask[mask.startIndex + (index & 3)]) }
        return frame
    }
}

func frameRandomBytes(_ count: Int) throws -> Data {
    var data = Data(count: count)
    let result = data.withUnsafeMutableBytes { buffer -> OSStatus in
        guard let base = buffer.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, count, base)
    }
    guard result == errSecSuccess else { throw FrameError.randomUnavailable }
    return data
}

/// One instance per generation. All client application/control writes use one
/// partial-write serializer in FrameSocketIO. retire is synchronous and does not
/// queue behind a suspended actor read. Explicit retirement closes locally;
/// it does not claim a peer close handshake or remote effect.
actor FrameWebSocketTransport: FrameWireTransport {
    private nonisolated let socket: FrameSocketIO
    private let timing: FrameTiming
    private let random: @Sendable (Int) throws -> Data
    private var codec = FrameWebSocketCodec()
    private var opened = false

    init(socket: FrameSocketIO? = nil, timing: FrameTiming = FrameTiming(),
         random: @escaping @Sendable (Int) throws -> Data = frameRandomBytes) {
        self.socket = socket ?? FrameSocketIO(timing: timing)
        self.timing = timing
        self.random = random
    }

    func open(deadline: ContinuousClock.Instant) async throws {
        guard !opened else { throw FrameError.busy }
        try await socket.connect(deadline: deadline)
        let nonceBytes = try random(16)
        guard nonceBytes.count == 16 else { throw FrameError.randomUnavailable }
        let nonce = nonceBytes.base64EncodedString()
        try await socket.writeAll(FrameHTTPUpgrade.request(nonce: nonce), deadline: deadline)
        var received = Data()
        let terminator = Data([13, 10, 13, 10])
        while true {
            try timing.check(deadline, stage: .handshake)
            let chunk = try await socket.read(deadline: deadline, stage: .handshake)
            guard !chunk.isEmpty else { throw FrameError.protocolViolation(.truncated) }
            // At most 16 KiB headers plus one bounded read's coalesced RFB bytes.
            guard received.count <= FrameLimits.httpHeaders + FrameLimits.socketChunk - chunk.count else {
                throw FrameError.limitExceeded(.bufferBytes)
            }
            received.append(chunk)
            if let range = received.range(of: terminator) {
                let end = range.upperBound
                guard end <= FrameLimits.httpHeaders else { throw FrameError.limitExceeded(.bufferBytes) }
                try FrameHTTPUpgrade.validate(received.subdata(in: 0..<end), nonce: nonce)
                try codec.append(received.subdata(in: end..<received.count))
                try timing.check(deadline, stage: .handshake)
                guard !socket.isRetired else { throw FrameError.cancelled }
                opened = true
                return
            }
            guard received.count <= FrameLimits.httpHeaders else { throw FrameError.limitExceeded(.bufferBytes) }
        }
    }

    func sendBinary(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        guard opened else { throw FrameError.cancelled }
        try await send(opcode: 2, data: data, deadline: deadline)
    }

    func receiveBinary(deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) async throws -> Data? {
        guard opened else { throw FrameError.cancelled }
        var controls = 0
        while true {
            try timing.check(deadline, stage: stage)
            guard !socket.isRetired else { throw FrameError.cancelled }
            if let event = try codec.next() {
                switch event {
                case .binary(let data): return data
                case .ping(let data):
                    controls += 1
                    guard controls <= 128 else { throw FrameError.limitExceeded(.controls) }
                    try await send(opcode: 10, data: data, deadline: deadline)
                case .pong:
                    controls += 1
                    guard controls <= 128 else { throw FrameError.limitExceeded(.controls) }
                case .close(let payload):
                    try await send(opcode: 8, data: payload, deadline: deadline)
                    socket.beginClose()
                    return nil
                }
                continue
            }
            let data = try await socket.read(deadline: deadline, stage: stage)
            if data.isEmpty { try codec.endOfStream(); return nil }
            try codec.append(data)
        }
    }

    nonisolated func retire() { socket.beginClose() }
    nonisolated func close(deadline: ContinuousClock.Instant) async throws { try await socket.close(deadline: deadline) }

    private func send(opcode: UInt8, data: Data, deadline: ContinuousClock.Instant) async throws {
        try timing.check(deadline, stage: .write)
        let mask = try random(4)
        let frame = try FrameWebSocketCodec.clientFrame(opcode: opcode, payload: data, mask: mask)
        try await socket.writeAll(frame, deadline: deadline)
    }
}
