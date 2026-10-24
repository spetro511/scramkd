import Foundation

enum RFBEvent: Sendable {
    case send(Data)
    case initialized(width: Int, height: Int)
    /// nil is a completed zero-rectangle response, not an inferred static desktop.
    case update(pixels: Data?)
}

/// RFB 3.8 / offered None / shared / canonical 32-bit LE true-color / RAW only.
/// WS messages are arbitrary pieces of this byte stream, not RFB boundaries.
struct RFBStreamDecoder {
    private enum Phase {
        case version, securityCount, securityTypes(Int), securityResult, serverInit
        case serverName(Int), message, updateHeader, rectangle, raw(Int, Int, Int, Int)
        case cutHeader, cutBody(Int)
    }
    private var phase: Phase = .version
    private var bytes = FrameByteQueue()
    private(set) var width = 0
    private(set) var height = 0
    private(set) var initialized = false
    private(set) var outstandingUpdate = false
    private var remainingRectangles = 0
    private var updateBytes = 0
    private var staging: [UInt8] = []
    private var coverage: [UInt8] = []
    private var coveredPixels = 0
    private var bells = 0
    private var cutTexts = 0
    private let updateByteLimit: Int

    /// Internal lower-only limit permits small deterministic budget fixtures.
    init(updateByteLimit: Int = FrameLimits.bytes) {
        self.updateByteLimit = min(FrameLimits.bytes, max(0, updateByteLimit))
    }

    mutating func requestFullUpdate() throws -> Data {
        guard initialized, !outstandingUpdate else { throw FrameError.busy }
        outstandingUpdate = true
        updateBytes = 0
        bells = 0
        cutTexts = 0
        return Data([3, 0, 0, 0, 0, 0,
                     UInt8(width >> 8), UInt8(width & 255),
                     UInt8(height >> 8), UInt8(height & 255)])
    }

    mutating func consume(_ data: Data, check: () throws -> Void = {}) throws -> [RFBEvent] {
        try check()
        try bytes.append(data)
        var events: [RFBEvent] = []
        while true {
            try check()
            switch phase {
            case .version:
                guard bytes.count >= 12 else { return events }
                guard bytes.take(12) == Data("RFB 003.008\n".utf8) else {
                    throw FrameError.unsupportedVersion
                }
                events.append(.send(Data("RFB 003.008\n".utf8)))
                phase = .securityCount
            case .securityCount:
                guard bytes.count >= 1 else { return events }
                let count = Int(bytes[0]); bytes.drop(1)
                guard count > 0 else { throw FrameError.securityRejected }
                phase = .securityTypes(count)
            case .securityTypes(let count):
                guard bytes.count >= count else { return events }
                let offered = Array(bytes.take(count))
                guard offered.contains(1) else { throw FrameError.unsupportedSecurity(offered) }
                events.append(.send(Data([1])))
                phase = .securityResult
            case .securityResult:
                guard bytes.count >= 4 else { return events }
                guard bytes.u32(0) == 0 else { throw FrameError.securityRejected }
                bytes.drop(4)
                events.append(.send(Data([1]))) // ClientInit shared; never exclusive.
                phase = .serverInit
            case .serverInit:
                guard bytes.count >= 24 else { return events }
                width = bytes.u16(0); height = bytes.u16(2)
                _ = try FrameLimits.frameBytes(width: width, height: height)
                guard bytes[4] == 32, bytes[5] == 24, bytes[6] == 0, bytes[7] != 0,
                      bytes.u16(8) == 255, bytes.u16(10) == 255, bytes.u16(12) == 255,
                      bytes[14] == 16, bytes[15] == 8, bytes[16] == 0 else {
                    throw FrameError.protocolViolation(.pixelFormat)
                }
                let length = Int(bytes.u32(20))
                guard length <= FrameLimits.serverName else { throw FrameError.limitExceeded(.serverNameBytes) }
                bytes.drop(24)
                phase = .serverName(length)
            case .serverName(let length):
                guard bytes.count >= length else { return events }
                guard String(data: bytes.take(length), encoding: .utf8) != nil else {
                    throw FrameError.protocolViolation(.serverNameUTF8)
                }
                // Never retain or publish the untrusted desktop name.
                initialized = true
                phase = .message
                events.append(.send(Self.pixelFormatAndEncodings))
                events.append(.initialized(width: width, height: height))
            case .message:
                guard bytes.count >= 1 else { return events }
                let type = bytes[0]; bytes.drop(1)
                switch type {
                case 0:
                    guard outstandingUpdate else { throw FrameError.protocolViolation(.unsolicitedUpdate) }
                    try charge(1)
                    phase = .updateHeader
                case 2:
                    bells += 1
                    guard bells <= 16 else { throw FrameError.limitExceeded(.controls) }
                case 3:
                    cutTexts += 1
                    guard cutTexts <= 4 else { throw FrameError.limitExceeded(.controls) }
                    phase = .cutHeader
                default:
                    // Palette changes, extensions and resize messages are unsupported.
                    throw FrameError.protocolViolation(.serverMessage)
                }
            case .updateHeader:
                guard bytes.count >= 3 else { return events }
                remainingRectangles = bytes.u16(1); bytes.drop(3)
                try charge(3)
                guard remainingRectangles <= FrameLimits.rectangles else { throw FrameError.limitExceeded(.rectangles) }
                if remainingRectangles == 0 {
                    outstandingUpdate = false
                    phase = .message
                    events.append(.update(pixels: nil))
                } else {
                    let count = try FrameLimits.frameBytes(width: width, height: height)
                    staging = [UInt8](repeating: 0, count: count)
                    coverage = [UInt8](repeating: 0, count: (count / 4 + 7) / 8)
                    coveredPixels = 0
                    phase = .rectangle
                }
            case .rectangle:
                guard bytes.count >= 12 else { return events }
                let x = bytes.u16(0), y = bytes.u16(2)
                let w = bytes.u16(4), h = bytes.u16(6)
                let encoding = Int32(bitPattern: bytes.u32(8))
                guard encoding == 0 else { throw FrameError.unsupportedEncoding(encoding) }
                guard w > 0, h > 0, x <= width, y <= height,
                      w <= width - x, h <= height - y else {
                    throw FrameError.protocolViolation(.rectangleBounds)
                }
                let count = try FrameLimits.frameBytes(width: w, height: h)
                try charge(12)
                try charge(count) // Aggregate overlap traffic is bounded before accepting pixels.
                bytes.drop(12)
                phase = .raw(x, y, w, h)
            case .raw(let x, let y, let w, let h):
                let count = try FrameLimits.frameBytes(width: w, height: h)
                guard bytes.count >= count else { return events }
                for row in 0..<h {
                    try check()
                    for column in 0..<w {
                        let source = (row * w + column) * 4
                        let pixel = (y + row) * width + x + column
                        let destination = pixel * 4
                        staging[destination] = bytes[source + 2]
                        staging[destination + 1] = bytes[source + 1]
                        staging[destination + 2] = bytes[source]
                        staging[destination + 3] = 255 // X is not alpha.
                        let mask = UInt8(1 << (pixel & 7))
                        if coverage[pixel >> 3] & mask == 0 {
                            coverage[pixel >> 3] |= mask
                            coveredPixels += 1
                        }
                    }
                }
                bytes.drop(count)
                remainingRectangles -= 1
                if remainingRectangles == 0 {
                    guard coveredPixels == width * height else {
                        throw FrameError.protocolViolation(.incompleteFramebuffer)
                    }
                    try check()
                    let pixels = Data(staging)
                    staging.removeAll(keepingCapacity: false)
                    coverage.removeAll(keepingCapacity: false)
                    outstandingUpdate = false
                    phase = .message
                    events.append(.update(pixels: pixels))
                } else { phase = .rectangle }
            case .cutHeader:
                guard bytes.count >= 7 else { return events }
                let count = Int(bytes.u32(3))
                guard count <= FrameLimits.clipboard else { throw FrameError.limitExceeded(.clipboardBytes) }
                bytes.drop(7)
                phase = .cutBody(count)
            case .cutBody(let count):
                // Discard incrementally; never materialize a clipboard String/Data.
                let discarded = min(count, bytes.count)
                bytes.drop(discarded)
                if discarded < count { phase = .cutBody(count - discarded); return events }
                phase = .message
            }
        }
    }

    func endOfStream() throws {
        // A pending request with no response bytes is EOF, not a truncated RFB
        // message. A partially received header/body remains a distinct violation.
        guard initialized, bytes.count == 0,
              case .message = phase else { throw FrameError.protocolViolation(.truncated) }
        throw FrameError.endOfStream
    }

    private mutating func charge(_ count: Int) throws {
        guard count <= updateByteLimit, updateBytes <= updateByteLimit - count else {
            throw FrameError.limitExceeded(.updateBytes)
        }
        updateBytes += count
    }

    static let pixelFormatAndEncodings = Data([
        0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
        2, 0, 0, 1, 0, 0, 0, 0 // SetEncodings: exactly RAW(0).
    ])
}
