import Foundation

enum BridgeLimits {
    static let requestBytes = 1_048_576
    static let responseBytes = 8_388_608
    static let jsonDepth = 32
    static let toolNameBytes = 256
    static let cursorBytes = 1_024
    static let pendingRequests = 8
    static let eventRetention = 256
    static let observationBuffer = 128
    static let stderrBytes = 65_536
    static let diagnosticBytes = 1_024
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
}

indirect enum MCPJSONValue: Sendable, Equatable {
    case object([String: MCPJSONValue])
    case array([MCPJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var object: [String: MCPJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [MCPJSONValue]? { if case .array(let value) = self { value } else { nil } }
}

enum MCPRequestID: Sendable, Hashable {
    case string(String)
    case integer(Int64)

    init(_ value: MCPJSONValue) throws {
        switch value {
        case .string(let string) where string.utf8.count <= 256: self = .string(string)
        case .number(let raw):
            guard let number = Int64(raw), number >= -9_007_199_254_740_991,
                  number <= 9_007_199_254_740_991 else { throw BridgeError.malformedRequest }
            self = .integer(number)
        default: throw BridgeError.malformedRequest
        }
    }
}

enum MCPPublicRequest: Sendable, Equatable {
    case ping
    case listTools(cursor: String?)
    case tool(name: String, arguments: MCPJSONValue)
}

/// Strict UTF-8 JSON scanner. Keys are decoded before duplicate detection, including
/// escaped discriminators. Depth/size checks precede Foundation string decoding.
enum MCPJSONCodec {
    static func decode(_ data: Data, maximumBytes: Int = BridgeLimits.responseBytes) throws -> MCPJSONValue {
        guard data.count <= maximumBytes else { throw BridgeError.limitExceeded(.lineBytes) }
        guard String(data: data, encoding: .utf8) != nil else { throw BridgeError.malformedRequest }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw BridgeError.malformedRequest }
        return value
    }

    static func publicRequest(_ data: Data) throws -> MCPPublicRequest {
        guard data.count < BridgeLimits.requestBytes else { throw BridgeError.limitExceeded(.requestBytes) }
        guard let object = try decode(data, maximumBytes: BridgeLimits.requestBytes).object,
              Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              object["jsonrpc"] == .string("2.0"), let id = object["id"],
              let method = object["method"]?.string else { throw BridgeError.malformedRequest }
        _ = try MCPRequestID(id)
        switch method {
        case "ping":
            guard object["params"] == nil || object["params"] == .object([:]) else { throw BridgeError.malformedRequest }
            return .ping
        case "tools/list":
            guard let params = object["params"] else { return .listTools(cursor: nil) }
            guard let values = params.object, Set(values.keys).isSubset(of: ["cursor"]) else { throw BridgeError.malformedRequest }
            guard let cursorValue = values["cursor"] else { return .listTools(cursor: nil) }
            guard let cursor = cursorValue.string else { throw BridgeError.malformedRequest }
            guard cursor.utf8.count <= BridgeLimits.cursorBytes else { throw BridgeError.limitExceeded(.cursorBytes) }
            return .listTools(cursor: cursor)
        case "tools/call":
            guard let params = object["params"]?.object,
                  Set(params.keys).isSubset(of: ["name", "arguments"]),
                  let name = params["name"]?.string,
                  let arguments = params["arguments"], arguments.object != nil else { throw BridgeError.malformedRequest }
            try validateToolName(name)
            return .tool(name: name, arguments: arguments)
        default:
            let bounded = String(decoding: method.utf8.prefix(BridgeLimits.diagnosticBytes - 3), as: UTF8.self)
            var diagnostic = ""
            for scalar in bounded.unicodeScalars {
                if CharacterSet.controlCharacters.contains(scalar) { diagnostic.append("?") }
                else { diagnostic.unicodeScalars.append(scalar) }
            }
            throw BridgeError.unsupportedMethod(diagnostic)
        }
    }

    static func validateToolName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= BridgeLimits.toolNameBytes,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BridgeError.limitExceeded(.toolNameBytes)
        }
    }

    static func frame(id: UUID?, method: String, params: MCPJSONValue?) throws -> Data {
        var object: [String: MCPJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { object["id"] = .string(id.uuidString) }
        if let params { object["params"] = params }
        var data = try encode(.object(object))
        guard data.count < BridgeLimits.requestBytes else { throw BridgeError.limitExceeded(.requestBytes) }
        data.append(0x0A)
        return data
    }

    static func encode(_ value: MCPJSONValue) throws -> Data {
        var result = Data()
        try append(value, to: &result)
        return result
    }

    private static func append(_ value: MCPJSONValue, to data: inout Data) throws {
        switch value {
        case .object(let object):
            data.append(0x7B)
            for (offset, key) in object.keys.sorted().enumerated() {
                if offset > 0 { data.append(0x2C) }
                data.append(try JSONEncoder().encode(key))
                data.append(0x3A)
                if let child = object[key] { try append(child, to: &data) }
            }
            data.append(0x7D)
        case .array(let array):
            data.append(0x5B)
            for (offset, child) in array.enumerated() {
                if offset > 0 { data.append(0x2C) }
                try append(child, to: &data)
            }
            data.append(0x5D)
        case .string(let string): data.append(try JSONEncoder().encode(string))
        case .number(let raw): data.append(contentsOf: raw.utf8)
        case .bool(let bool): data.append(contentsOf: (bool ? "true" : "false").utf8)
        case .null: data.append(contentsOf: "null".utf8)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func whitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> MCPJSONValue {
            guard depth <= BridgeLimits.jsonDepth else { throw BridgeError.limitExceeded(.jsonDepth) }
            whitespace()
            guard index < bytes.count else { throw BridgeError.malformedRequest }
            switch bytes[index] {
            case 0x7B:
                guard depth < BridgeLimits.jsonDepth else { throw BridgeError.limitExceeded(.jsonDepth) }
                index += 1
                whitespace()
                var object: [String: MCPJSONValue] = [:]
                if consume(0x7D) { return .object(object) }
                while true {
                    whitespace()
                    let key = try string()
                    guard object[key] == nil else { throw BridgeError.malformedRequest }
                    whitespace()
                    guard consume(0x3A) else { throw BridgeError.malformedRequest }
                    object[key] = try value(depth: depth + 1)
                    whitespace()
                    if consume(0x7D) { return .object(object) }
                    guard consume(0x2C) else { throw BridgeError.malformedRequest }
                }
            case 0x5B:
                guard depth < BridgeLimits.jsonDepth else { throw BridgeError.limitExceeded(.jsonDepth) }
                index += 1
                whitespace()
                var array: [MCPJSONValue] = []
                if consume(0x5D) { return .array(array) }
                while true {
                    array.append(try value(depth: depth + 1))
                    whitespace()
                    if consume(0x5D) { return .array(array) }
                    guard consume(0x2C) else { throw BridgeError.malformedRequest }
                }
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            case 0x2D, 0x30...0x39: return .number(try number())
            default: throw BridgeError.malformedRequest
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func literal(_ string: String) throws {
            for byte in string.utf8 {
                guard consume(byte) else { throw BridgeError.malformedRequest }
            }
        }

        mutating func string() throws -> String {
            let start = index
            guard consume(0x22) else { throw BridgeError.malformedRequest }
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false; continue }
                if byte == 0x5C { escaped = true; continue }
                if byte == 0x22 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw BridgeError.malformedRequest }
                }
                guard byte >= 0x20 else { throw BridgeError.malformedRequest }
            }
            throw BridgeError.malformedRequest
        }

        mutating func number() throws -> String {
            let start = index
            _ = consume(0x2D)
            if !consume(0x30) {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { throw BridgeError.malformedRequest }
                digits()
            }
            if consume(0x2E) {
                let first = index
                digits()
                guard index > first else { throw BridgeError.malformedRequest }
            }
            if consume(0x65) || consume(0x45) {
                if !consume(0x2B) { _ = consume(0x2D) }
                let first = index
                digits()
                guard index > first else { throw BridgeError.malformedRequest }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func digits() {
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
    }
}

struct MCPLineFramer: Sendable {
    private var pending = Data()

    mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        for index in chunk.indices where chunk[index] == 0x0A {
            guard lines.count < 256, pending.count <= BridgeLimits.responseBytes - (index - start) - 1 else {
                throw BridgeError.limitExceeded(.lineBytes)
            }
            pending.append(chunk[start..<index])
            guard !pending.isEmpty else { throw BridgeError.malformedRequest }
            lines.append(pending)
            pending = Data()
            start = index + 1
        }
        guard pending.count <= BridgeLimits.responseBytes - (chunk.endIndex - start) else {
            throw BridgeError.limitExceeded(.lineBytes)
        }
        pending.append(chunk[start..<chunk.endIndex])
        return lines
    }

    var hasPartialLine: Bool { !pending.isEmpty }
}
