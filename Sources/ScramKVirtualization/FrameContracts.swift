import Foundation

public enum FrameColorEncoding: String, Sendable, Equatable {
    /// RFB did not supply an ICC profile. This is an interpretation, not proof.
    case assumedSRGB
}

/// Complete top-left-origin, tightly packed, opaque RGBA8 pixels. Local receive
/// time is not a guest capture timestamp. This value owns no Metal resource.
public struct RGBAFrame: Sendable, Equatable {
    public let generation: UUID
    public let sequence: UInt64
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixels: Data
    public let receivedAt: ContinuousClock.Instant
    public let colorEncoding: FrameColorEncoding

    public init(generation: UUID, sequence: UInt64, width: Int, height: Int,
                bytesPerRow: Int, pixels: Data, receivedAt: ContinuousClock.Instant,
                colorEncoding: FrameColorEncoding = .assumedSRGB) throws {
        let byteCount = try FrameLimits.frameBytes(width: width, height: height)
        guard sequence > 0, bytesPerRow == width * 4, pixels.count == byteCount else {
            throw FrameError.protocolViolation(.invalidFrame)
        }
        guard stride(from: 3, to: pixels.count, by: 4).allSatisfy({ pixels[pixels.startIndex + $0] == 255 }) else {
            throw FrameError.protocolViolation(.invalidAlpha)
        }
        self.generation = generation
        self.sequence = sequence
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.receivedAt = receivedAt
        self.colorEncoding = colorEncoding
    }
}

public enum FrameConnectionState: String, Sendable, Equatable {
    case detached, connecting, negotiating, connected, disconnecting, failed
}

public enum FrameDeadlineStage: String, Sendable, Equatable {
    case connect, handshake, write, update, cleanup
}

public enum FrameLimit: String, Sendable, Equatable {
    case dimensions, pixels, bufferBytes, messageBytes, updateBytes, rectangles
    case serverNameBytes, clipboardBytes, controls, observers, counter
}

public enum FrameProtocolViolation: String, Sendable, Equatable {
    case httpHeaders, httpStatus, webSocketAccept, webSocketExtensions, webSocketSubprotocol
    case webSocketFrame, webSocketLength, webSocketFragmentation, webSocketText, webSocketClose
    case rfbVersion, pixelFormat, serverNameUTF8, serverMessage, unsolicitedUpdate
    case rectangleBounds, incompleteFramebuffer, invalidFrame, invalidAlpha, truncated
}

/// No associated string contains server names, clipboard content, or pixel data.
public enum FrameError: Error, Sendable, Equatable {
    case busy, staleGeneration, cancelled, endOfStream, transportFailure
    case timedOut(FrameDeadlineStage)
    case systemCall(code: Int32)
    case randomUnavailable
    case httpRejected(status: Int)
    case protocolViolation(FrameProtocolViolation)
    case unsupportedVersion
    case unsupportedSecurity([UInt8])
    case securityRejected
    case unsupportedEncoding(Int32)
    case limitExceeded(FrameLimit)
}

/// revision is lifetime-monotonic, including clears and replacement sessions.
/// nil frame is an explicit retirement/standby signal, not a black guest frame.
public struct FrameDelivery: Sendable {
    public let revision: UInt64
    public let generation: UUID?
    public let frame: RGBAFrame?
}

public struct FrameObservation: Sendable {
    public let id: UUID
    public let current: FrameDelivery
    public let updates: AsyncStream<FrameDelivery>
}

/// Binary-message payload counters exclude HTTP, RFC6455 headers and controls.
/// Source frame counts do not measure guest capture, GPU draws or presentation.
public struct FrameStatistics: Sendable, Equatable {
    public internal(set) var startedAt: ContinuousClock.Instant?
    public internal(set) var sampledAt: ContinuousClock.Instant?
    public internal(set) var receivedBinaryPayloadBytes: UInt64 = 0
    public internal(set) var receivedBinaryMessages: UInt64 = 0
    public internal(set) var completedUpdates: UInt64 = 0
    public internal(set) var noChangeUpdates: UInt64 = 0
    public internal(set) var publishedFrames: UInt64 = 0
    public internal(set) var replacedFrameDeliveries: UInt64 = 0

    public init() {}
}

/// Coarse status intentionally contains no full-image Data.
public struct FrameSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let generation: UUID?
    public let state: FrameConnectionState
    public let width: Int?
    public let height: Int?
    public let lastTrafficAt: ContinuousClock.Instant?
    public let lastFrameAt: ContinuousClock.Instant?
    public let statistics: FrameStatistics
    public let failure: FrameError?
}

public struct FrameStateObservation: Sendable {
    public let id: UUID
    public let snapshot: FrameSnapshot
    public let updates: AsyncStream<FrameSnapshot>
}

enum FrameLimits {
    static let dimension = 4096
    static let pixels = 8_388_608
    static let bytes = 64 * 1024 * 1024
    static let rectangles = 1024
    static let serverName = 4096
    static let clipboard = 64 * 1024
    static let httpHeaders = 16 * 1024
    static let socketChunk = 64 * 1024
    static let stateObservers = 4

    // These are individual storage/traffic bounds, NOT a process RSS ceiling.
    // RFB staging <=32 MiB + coverage <=1 MiB; byte queue <=64 MiB;
    // WS reassembly <=64 MiB; current/queued/consumer COW images can coexist.
    // Extraction/publication can temporarily duplicate Data backing storage;
    // the combined peak can be several hundred MiB at the maximum settings.
    // Consumer-held value copies are outside the client's retention policy.
    static func frameBytes(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0, width <= dimension, height <= dimension else {
            throw FrameError.limitExceeded(.dimensions)
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count <= pixels else { throw FrameError.limitExceeded(.pixels) }
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !byteOverflow, bytes <= self.bytes else { throw FrameError.limitExceeded(.pixels) }
        return bytes
    }
}

struct FrameTiming: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
        try await ContinuousClock().sleep(until: $0)
    }
    var connectBudget: Duration = .seconds(5)
    var updateBudget: Duration = .seconds(10)
    var cleanupBudget: Duration = .seconds(2)
    // Ten requested full updates/s at most by default; absolute floor is 34 ms.
    var requestInterval: Duration = .milliseconds(100)

    func check(_ deadline: ContinuousClock.Instant, stage: FrameDeadlineStage) throws {
        try Task.checkCancellation()
        guard now() < deadline else { throw FrameError.timedOut(stage) }
    }
}

func frameError(_ error: any Error) -> FrameError {
    if let error = error as? FrameError { return error }
    if error is CancellationError { return .cancelled }
    return .transportFailure
}

/// A bounded queue with a read cursor; no repeated removeFirst per byte.
struct FrameByteQueue {
    private var storage = Data()
    private var offset = 0
    var count: Int { storage.count - offset }

    mutating func append(_ data: Data, limit: Int = FrameLimits.bytes) throws {
        guard data.count <= limit, count <= limit - data.count else {
            throw FrameError.limitExceeded(.bufferBytes)
        }
        if offset > 0 && (offset >= storage.count / 2 || storage.count > limit - data.count) {
            storage = storage.subdata(in: offset..<storage.count)
            offset = 0
        }
        storage.append(data)
    }

    subscript(_ index: Int) -> UInt8 { storage[offset + index] }
    func u16(_ index: Int) -> Int { Int(self[index]) << 8 | Int(self[index + 1]) }
    func u32(_ index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 |
        UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
    mutating func take(_ count: Int) -> Data {
        let data = storage.subdata(in: offset..<(offset + count))
        drop(count)
        return data
    }
    mutating func drop(_ count: Int) {
        offset += count
        if offset == storage.count { storage.removeAll(keepingCapacity: false); offset = 0 }
    }
}
