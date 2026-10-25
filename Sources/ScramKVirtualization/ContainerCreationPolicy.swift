import CoreFoundation
import Foundation

/// Security posture profile applied when inspecting container creation payloads.
public enum ContainerSecurityProfile: String, Sendable, Hashable, Codable {
    case strictAirgap = "STRICT_AIRGAP"
    case loopbackFramebuffer = "LOOPBACK_FB"
}

/// Errors thrown by `ContainerCreationPolicy` during fail-closed payload validation.
public enum ContainerCreationPolicyError: Error, Sendable, Equatable {
    case emptyPayload
    case invalidJSON
    case rootNotJSONObject
    case nestingDepthExceeded(maxDepth: Int)
    case duplicateCanonicalKey(String)
    case forbiddenDirective(key: String, detail: String)
    case missingRequiredDirective(key: String)
}

/// Fail-closed structural JSON inspector for Docker/Containerd `/containers/create` payloads.
public struct ContainerCreationPolicy: Sendable {
    public static let maxNestingDepth: Int = 32

    public init() {}

    public func inspectContainerCreatePayload(
        _ data: Data,
        profile: ContainerSecurityProfile = .strictAirgap
    ) throws {
        try Self.inspectContainerCreatePayload(data, profile: profile)
    }

    public static func inspectContainerCreatePayload(
        _ data: Data,
        profile: ContainerSecurityProfile = .strictAirgap
    ) throws {
        if data.isEmpty || data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            throw ContainerCreationPolicyError.emptyPayload
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            if exceedsNestingDepth(data, maxDepth: maxNestingDepth) {
                throw ContainerCreationPolicyError.nestingDepthExceeded(maxDepth: maxNestingDepth)
            }
            throw ContainerCreationPolicyError.invalidJSON
        }

        guard let rootObject = parsed as? [String: Any] else {
            throw ContainerCreationPolicyError.rootNotJSONObject
        }

        try scanRawJSONStructureAndDuplicateKeys(data, maxDepth: maxNestingDepth)

        var state = ValidationState(profile: profile)
        try inspectObject(rootObject, depth: 1, isRoot: true, isHostConfig: false, state: &state)

        if profile == .strictAirgap && !state.sawHostConfigNetworkModeNone {
            throw ContainerCreationPolicyError.missingRequiredDirective(key: "networkmode")
        }
    }

    private struct ValidationState {
        let profile: ContainerSecurityProfile
        var sawHostConfigNetworkModeNone: Bool = false
    }

    private static func inspectObject(
        _ object: [String: Any],
        depth: Int,
        isRoot: Bool,
        isHostConfig: Bool,
        state: inout ValidationState
    ) throws {
        if depth > maxNestingDepth {
            throw ContainerCreationPolicyError.nestingDepthExceeded(maxDepth: maxNestingDepth)
        }

        var seenCanonicalKeys = Set<String>()
        for (rawKey, value) in object {
            let canonical = canonicalKey(rawKey)
            guard !canonical.isEmpty else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: rawKey,
                    detail: "Keys must contain alphanumeric characters"
                )
            }
            if !seenCanonicalKeys.insert(canonical).inserted {
                throw ContainerCreationPolicyError.duplicateCanonicalKey(canonical)
            }

            try validateDirective(
                canonicalKey: canonical,
                rawKey: rawKey,
                value: value,
                isRoot: isRoot,
                isHostConfig: isHostConfig,
                state: &state
            )

            if canonical != "portbindings" && canonical != "exposedports" {
                try inspectNestedValue(
                    value,
                    depth: depth,
                    childIsHostConfig: canonical == "hostconfig",
                    state: &state
                )
            }
        }
    }

    private static func inspectNestedValue(
        _ value: Any,
        depth: Int,
        childIsHostConfig: Bool,
        state: inout ValidationState
    ) throws {
        if let nestedObject = value as? [String: Any] {
            try inspectObject(
                nestedObject,
                depth: depth + 1,
                isRoot: false,
                isHostConfig: childIsHostConfig,
                state: &state
            )
        } else if let nestedArray = value as? [Any] {
            if depth + 1 > maxNestingDepth {
                throw ContainerCreationPolicyError.nestingDepthExceeded(maxDepth: maxNestingDepth)
            }
            for element in nestedArray {
                try inspectNestedValue(
                    element,
                    depth: depth + 1,
                    childIsHostConfig: false,
                    state: &state
                )
            }
        }
    }

    private static func validateDirective(
        canonicalKey canonical: String,
        rawKey: String,
        value: Any,
        isRoot: Bool,
        isHostConfig: Bool,
        state: inout ValidationState
    ) throws {
        switch canonical {
        case "hostconfig", "networkingconfig":
            if !(value is [String: Any]) && !(value is NSNull) {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: canonical,
                    detail: "\(rawKey) must be a JSON object"
                )
            }

        case "privileged":
            guard let flag = exactBool(value), flag == false else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "privileged",
                    detail: "Privileged container execution is forbidden."
                )
            }

        case "readonlyrootfs":
            guard let flag = exactBool(value), flag == true else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "readonlyrootfs",
                    detail: "ReadonlyRootfs must be true when specified"
                )
            }

        case "publishallports":
            guard let flag = exactBool(value), flag == false else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "publishallports",
                    detail: "PublishAllPorts is forbidden"
                )
            }

        case "capadd", "binds", "mounts", "volumesfrom", "devices", "extrahosts", "maskedpaths", "readonlypaths":
            if value is NSNull {
                return
            }
            if let array = value as? [Any], array.isEmpty {
                return
            }
            if let dict = value as? [String: Any], dict.isEmpty {
                return
            }
            throw ContainerCreationPolicyError.forbiddenDirective(
                key: canonical,
                detail: "Non-empty \(rawKey) directive is forbidden"
            )

        case "pidmode", "ipcmode", "utsmode", "usernsmode", "cgroupnsmode":
            if value is NSNull {
                return
            }
            guard let mode = value as? String else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: canonical,
                    detail: "\(rawKey) must be empty or 'private'"
                )
            }
            let normalized = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.isEmpty || normalized == "private" else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: canonical,
                    detail: "Namespace mode '\(mode)' is forbidden for \(rawKey)"
                )
            }

        case "securityopt":
            if value is NSNull {
                return
            }
            guard let options = value as? [Any] else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "securityopt",
                    detail: "SecurityOpt must be an array of strings"
                )
            }
            for option in options {
                guard let optionString = option as? String else {
                    throw ContainerCreationPolicyError.forbiddenDirective(
                        key: "securityopt",
                        detail: "SecurityOpt entries must be strings"
                    )
                }
                let lowered = optionString.lowercased()
                if lowered.contains("unconfined") || lowered.contains("disable") {
                    throw ContainerCreationPolicyError.forbiddenDirective(
                        key: "securityopt",
                        detail: "SecurityOpt entry '\(optionString)' weakens confinement"
                    )
                }
            }

        case "networkmode":
            guard let rawMode = value as? String else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "networkmode",
                    detail: "NetworkMode must be a string"
                )
            }
            let mode = rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if mode == "host" || mode.hasPrefix("container:") {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "networkmode",
                    detail: "NetworkMode '\(rawMode)' is forbidden"
                )
            }
            switch state.profile {
            case .strictAirgap:
                guard mode == "none" else {
                    throw ContainerCreationPolicyError.forbiddenDirective(
                        key: "networkmode",
                        detail: "Strict airgap profile requires NetworkMode 'none', got '\(rawMode)'"
                    )
                }
                if isHostConfig {
                    state.sawHostConfigNetworkModeNone = true
                }
            case .loopbackFramebuffer:
                let allowedModes: Set<String> = ["none", "bridge", "default"]
                guard allowedModes.contains(mode) else {
                    throw ContainerCreationPolicyError.forbiddenDirective(
                        key: "networkmode",
                        detail: "Loopback framebuffer profile forbids NetworkMode '\(rawMode)'"
                    )
                }
            }

        case "exposedports":
            if value is NSNull {
                return
            }
            guard let ports = value as? [String: Any] else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "exposedports",
                    detail: "ExposedPorts must be a JSON object"
                )
            }
            switch state.profile {
            case .strictAirgap:
                if !ports.isEmpty {
                    throw ContainerCreationPolicyError.forbiddenDirective(
                        key: "exposedports",
                        detail: "ExposedPorts are forbidden under strict airgap profile"
                    )
                }
            case .loopbackFramebuffer:
                for (portKey, portVal) in ports {
                    guard portKey.lowercased() == "7860/tcp", portVal is [String: Any] else {
                        throw ContainerCreationPolicyError.forbiddenDirective(
                            key: "exposedports",
                            detail: "Only 7860/tcp may be exposed under loopback framebuffer profile"
                        )
                    }
                }
            }

        case "portbindings":
            if value is NSNull {
                return
            }
            guard let bindingsMap = value as? [String: Any] else {
                throw ContainerCreationPolicyError.forbiddenDirective(
                    key: "portbindings",
                    detail: "PortBindings must be a JSON object"
                )
            }
            switch state.profile {
            case .strictAirgap:
                if !bindingsMap.isEmpty {
                    throw ContainerCreationPolicyError.forbiddenDirective(
                        key: "portbindings",
                        detail: "PortBindings are forbidden under strict airgap profile"
                    )
                }
            case .loopbackFramebuffer:
                for (portKey, rawBindings) in bindingsMap {
                    guard portKey.lowercased() == "7860/tcp" else {
                        throw ContainerCreationPolicyError.forbiddenDirective(
                            key: "portbindings",
                            detail: "PortBindings key '\(portKey)' is forbidden; only '7860/tcp' is permitted"
                        )
                    }
                    guard let bindingList = rawBindings as? [[String: Any]], !bindingList.isEmpty else {
                        throw ContainerCreationPolicyError.forbiddenDirective(
                            key: "portbindings",
                            detail: "PortBindings for '7860/tcp' must be a non-empty array of binding objects"
                        )
                    }
                    for binding in bindingList {
                        var hostIPValue: String?
                        var hostPortValue: String?
                        for (bKey, bVal) in binding {
                            let cKey = canonicalKey(bKey)
                            switch cKey {
                            case "hostip":
                                guard let str = bVal as? String else {
                                    throw ContainerCreationPolicyError.forbiddenDirective(
                                        key: "portbindings",
                                        detail: "HostIp must be a string"
                                    )
                                }
                                hostIPValue = str
                            case "hostport":
                                guard let str = bVal as? String else {
                                    throw ContainerCreationPolicyError.forbiddenDirective(
                                        key: "portbindings",
                                        detail: "HostPort must be a string"
                                    )
                                }
                                hostPortValue = str
                            default:
                                throw ContainerCreationPolicyError.forbiddenDirective(
                                    key: "portbindings",
                                    detail: "Unexpected key '\(bKey)' in PortBindings entry"
                                )
                            }
                        }
                        guard hostIPValue == "127.0.0.1", hostPortValue == "7860" else {
                            throw ContainerCreationPolicyError.forbiddenDirective(
                                key: "portbindings",
                                detail: "PortBindings for '7860/tcp' must bind strictly to 127.0.0.1:7860"
                            )
                        }
                    }
                }
            }

        default:
            break
        }
    }

    private static func exactBool(_ value: Any) -> Bool? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFBooleanGetTypeID() else {
            return nil
        }
        return value as? Bool
    }

    public static func canonicalKey(_ raw: String) -> String {
        var result = String()
        result.reserveCapacity(raw.utf8.count)
        for scalar in raw.lowercased().unicodeScalars {
            if (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private enum ContainerScope {
        case object(seenCanonicalKeys: Set<String>, expectingKey: Bool)
        case array
    }

    private static func scanRawJSONStructureAndDuplicateKeys(_ data: Data, maxDepth: Int) throws {
        let bytes = [UInt8](data)
        var stack: [ContainerScope] = []
        var index = 0
        let count = bytes.count

        while index < count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1

            case 0x7B: // '{'
                stack.append(.object(seenCanonicalKeys: [], expectingKey: true))
                if stack.count > maxDepth {
                    throw ContainerCreationPolicyError.nestingDepthExceeded(maxDepth: maxDepth)
                }
                index += 1

            case 0x5B: // '['
                stack.append(.array)
                if stack.count > maxDepth {
                    throw ContainerCreationPolicyError.nestingDepthExceeded(maxDepth: maxDepth)
                }
                index += 1

            case 0x7D, 0x5D: // '}', ']'
                if !stack.isEmpty {
                    stack.removeLast()
                }
                index += 1

            case 0x2C: // ','
                if let lastIndex = stack.indices.last,
                   case .object(let seen, _) = stack[lastIndex]
                {
                    stack[lastIndex] = .object(seenCanonicalKeys: seen, expectingKey: true)
                }
                index += 1

            case 0x22: // '"'
                let start = index
                index += 1
                while index < count {
                    let current = bytes[index]
                    if current == 0x5C { // '\'
                        index += 2
                        continue
                    }
                    if current == 0x22 { // '"'
                        index += 1
                        break
                    }
                    index += 1
                }
                if let lastIndex = stack.indices.last,
                   case .object(var seen, let expectingKey) = stack[lastIndex],
                   expectingKey
                {
                    let tokenData = Data(bytes[start..<index])
                    guard
                        let decodedKey = try? JSONSerialization.jsonObject(
                            with: tokenData,
                            options: [.fragmentsAllowed]
                        ) as? String
                    else {
                        throw ContainerCreationPolicyError.invalidJSON
                    }
                    let canonical = canonicalKey(decodedKey)
                    guard !canonical.isEmpty else {
                        throw ContainerCreationPolicyError.forbiddenDirective(
                            key: decodedKey,
                            detail: "Keys must contain alphanumeric characters"
                        )
                    }
                    if !seen.insert(canonical).inserted {
                        throw ContainerCreationPolicyError.duplicateCanonicalKey(canonical)
                    }
                    stack[lastIndex] = .object(seenCanonicalKeys: seen, expectingKey: false)
                }

            default:
                index += 1
            }
        }
    }

    private static func exceedsNestingDepth(_ data: Data, maxDepth: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                if depth > maxDepth {
                    return true
                }
            } else if byte == 0x7D || byte == 0x5D {
                depth = max(0, depth - 1)
            }
        }
        return false
    }
}
