import CryptoKit
import Foundation
import ScramKCore
import ScramKVirtualization

/// Deterministic semantic risk classification for intercepted MCP / container payloads.
/// Fails closed to `.critical` on malformed JSON, duplicate keys, nesting depth > 32, or invalid UTF-8.
public enum SemanticRiskLevel: String, Sendable, Equatable, Hashable, Comparable, CaseIterable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"

    public var severityRank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }

    public static func < (lhs: SemanticRiskLevel, rhs: SemanticRiskLevel) -> Bool {
        lhs.severityRank < rhs.severityRank
    }
}

/// Truthful Tier 1 provenance badge mapped directly from kernel peer credential trust (`OriginTrustKind`).
public enum SemanticProvenanceBadge: String, Sendable, Equatable, Hashable, CaseIterable {
    case verifiedPID = "VERIFIED PID"
    case claimedUnverified = "CLAIMED (UNVERIFIED)"
    case unknown = "UNKNOWN"

    public init(originTrust: OriginTrustKind) {
        switch originTrust {
        case .appProcess:
            self = .verifiedPID
        case .claimed:
            self = .claimedUnverified
        case .unknown:
            self = .unknown
        }
    }

    public var originTrust: OriginTrustKind {
        switch self {
        case .verifiedPID:
            .appProcess
        case .claimedUnverified:
            .claimed
        case .unknown:
            .unknown
        }
    }

    public var isKernelVerified: Bool {
        self == .verifiedPID
    }
}

/// Tier 3 structured key-path/value row parsed from JSON payload arguments.
/// All rendered text is sanitized through `BridgeDisplayText.escaped`.
public struct SemanticPayloadFieldDiff: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let keyPath: String
    public let value: String
    public let valueType: String
    public let riskLevel: SemanticRiskLevel
    public let riskReason: String?

    public init(
        id: String? = nil,
        keyPath: String,
        value: String,
        valueType: String = "STRING",
        riskLevel: SemanticRiskLevel = .low,
        riskReason: String? = nil
    ) {
        let escapedKeyPath = BridgeDisplayText.escaped(keyPath, limit: 160)
        let escapedValue = BridgeDisplayText.escaped(value, limit: 512)
        self.id = id ?? "\(escapedKeyPath)=\(escapedValue)"
        self.keyPath = escapedKeyPath
        self.value = escapedValue
        self.valueType = BridgeDisplayText.escaped(valueType, limit: 32)
        self.riskLevel = riskLevel
        self.riskReason = riskReason.map { BridgeDisplayText.escaped($0, limit: 160) }
    }
}

/// 3-Tier Progressive Disclosure HUD summary model for pending MCP / container intercepts.
public struct SemanticInterceptSummary: Sendable, Equatable {
    // MARK: - Tier 1: Ambient Status & Profile Strip
    public let gateStatus: InterlockStatus
    public let gateStateBadge: String
    public let securityProfile: ContainerSecurityProfile
    public let securityProfileBadge: String
    public let isHoldActive: Bool
    public let activeHoldBadge: String
    public let provenanceBadge: SemanticProvenanceBadge
    public let provenanceBadgeText: String

    // MARK: - Tier 2: Actionable Intercept Summary Card
    public let riskLevel: SemanticRiskLevel
    public let riskBadge: String
    public let riskReasons: [String]
    public let toolName: String
    public let methodName: String
    public let targetSummary: String
    public let criticalReadGuardDuration: Duration
    public let criticalReadGuardMilliseconds: Int
    public let isCriticalReadGuardSatisfied: Bool
    public let criticalReadGuardBadge: String
    public let controlStripBadges: [String]

    // MARK: - Tier 3: On-Demand Expandable Semantic Diff & Provenance Drawer
    public let fieldDiffs: [SemanticPayloadFieldDiff]
    public let sha256: String
    public let payloadByteCount: Int
    public let originTrust: OriginTrustKind
    public let originPID: Int32?
    public let originUID: UInt32?
    public let provenanceDetailText: String
    public let isFailClosedMalformed: Bool

    public init(
        gateStatus: InterlockStatus,
        gateStateBadge: String,
        securityProfile: ContainerSecurityProfile,
        securityProfileBadge: String,
        isHoldActive: Bool,
        activeHoldBadge: String,
        provenanceBadge: SemanticProvenanceBadge,
        riskLevel: SemanticRiskLevel,
        riskReasons: [String],
        toolName: String,
        methodName: String,
        targetSummary: String,
        criticalReadGuardDuration: Duration,
        criticalReadGuardMilliseconds: Int,
        isCriticalReadGuardSatisfied: Bool,
        criticalReadGuardBadge: String,
        controlStripBadges: [String],
        fieldDiffs: [SemanticPayloadFieldDiff],
        sha256: String,
        payloadByteCount: Int,
        originTrust: OriginTrustKind,
        originPID: Int32?,
        originUID: UInt32?,
        provenanceDetailText: String,
        isFailClosedMalformed: Bool
    ) {
        self.gateStatus = gateStatus
        self.gateStateBadge = gateStateBadge
        self.securityProfile = securityProfile
        self.securityProfileBadge = securityProfileBadge
        self.isHoldActive = isHoldActive
        self.activeHoldBadge = activeHoldBadge
        self.provenanceBadge = provenanceBadge
        self.provenanceBadgeText = provenanceBadge.rawValue
        self.riskLevel = riskLevel
        self.riskBadge = riskLevel.rawValue
        self.riskReasons = riskReasons
        self.toolName = toolName
        self.methodName = methodName
        self.targetSummary = targetSummary
        self.criticalReadGuardDuration = criticalReadGuardDuration
        self.criticalReadGuardMilliseconds = criticalReadGuardMilliseconds
        self.isCriticalReadGuardSatisfied = isCriticalReadGuardSatisfied
        self.criticalReadGuardBadge = criticalReadGuardBadge
        self.controlStripBadges = controlStripBadges
        self.fieldDiffs = fieldDiffs
        self.sha256 = sha256
        self.payloadByteCount = payloadByteCount
        self.originTrust = originTrust
        self.originPID = originPID
        self.originUID = originUID
        self.provenanceDetailText = provenanceDetailText
        self.isFailClosedMalformed = isFailClosedMalformed
    }
}

/// Deterministic, pure-Swift inspector that classifies and summarizes `PendingIntercept`
/// and raw JSON-RPC payloads into the 3-Tier Progressive Disclosure HUD model.
public enum SemanticInterceptInspector: Sendable {
    public static let maxJSONDepth: Int = 32
    public static let maxEvaluatedFields: Int = 64

    public static let defaultControlStripBadges: [String] = [
        "SPACE (GRANT)",
        "HOLD (INSPECT)",
        "ESC (ABORT)",
        "F12 (NOT IMPLEMENTED)",
    ]

    public static func gateStateBadge(for status: InterlockStatus) -> String {
        switch status {
        case .locked:
            "LOCKED"
        case .armed:
            "ARMED"
        case .permissiveGranted:
            "PERMISSIVE"
        case .emergencyAbort:
            "EMERGENCY ABORT"
        }
    }

    public static func activeHoldBadge(isHoldActive: Bool) -> String {
        isHoldActive ? "HOLD ACTIVE" : "COUNTDOWN"
    }

    public static func provenanceBadge(for originTrust: OriginTrustKind) -> SemanticProvenanceBadge {
        SemanticProvenanceBadge(originTrust: originTrust)
    }

    public static func provenanceDetail(
        originTrust: OriginTrustKind,
        originPID: Int32?,
        originUID: UInt32? = nil
    ) -> String {
        let badge = SemanticProvenanceBadge(originTrust: originTrust)
        switch originTrust {
        case .appProcess:
            let pidText = originPID.map { "PID \($0)" } ?? "PID VERIFIED"
            let uidText = originUID.map { " · UID \($0)" } ?? ""
            return "\(pidText)\(uidText) · \(badge.rawValue)"
        case .claimed:
            let pidText = originPID.map { "CLAIMED PID \($0)" } ?? "PID UNVERIFIED"
            let uidText = originUID.map { " · CLAIMED UID \($0)" } ?? ""
            return "\(pidText)\(uidText) · \(badge.rawValue)"
        case .unknown:
            let pidText = originPID.map { "PID \($0) · " } ?? ""
            return "\(pidText)PEER CREDENTIALS UNAVAILABLE · \(badge.rawValue)"
        }
    }

    public static func inspect(
        _ intercept: PendingIntercept,
        status: InterlockStatus = .armed,
        securityProfile: ContainerSecurityProfile = .strictAirgap,
        isHoldActive: Bool = false,
        activeHoldPolicy: ActiveHoldPolicy = ActiveHoldPolicy(),
        isCriticalReadGuardSatisfied: Bool = false,
        originUID: UInt32? = nil
    ) -> SemanticInterceptSummary {
        inspect(
            rawBytes: intercept.commandPayload,
            sha256: intercept.approval.sha256,
            toolHook: intercept.toolHook,
            status: status,
            securityProfile: securityProfile,
            isHoldActive: isHoldActive,
            activeHoldPolicy: activeHoldPolicy,
            isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
            originTrust: intercept.originTrust,
            originPID: intercept.originPID,
            originUID: originUID
        )
    }

    public static func inspect(
        jsonString: String,
        sha256: String? = nil,
        toolHook: String? = nil,
        status: InterlockStatus = .armed,
        securityProfile: ContainerSecurityProfile = .strictAirgap,
        isHoldActive: Bool = false,
        activeHoldPolicy: ActiveHoldPolicy = ActiveHoldPolicy(),
        isCriticalReadGuardSatisfied: Bool = false,
        originTrust: OriginTrustKind = .unknown,
        originPID: Int32? = nil,
        originUID: UInt32? = nil
    ) -> SemanticInterceptSummary {
        inspect(
            rawBytes: Data(jsonString.utf8),
            sha256: sha256,
            toolHook: toolHook,
            status: status,
            securityProfile: securityProfile,
            isHoldActive: isHoldActive,
            activeHoldPolicy: activeHoldPolicy,
            isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
            originTrust: originTrust,
            originPID: originPID,
            originUID: originUID
        )
    }

    public static func inspect(
        rawBytes: Data,
        sha256: String? = nil,
        toolHook: String? = nil,
        status: InterlockStatus = .armed,
        securityProfile: ContainerSecurityProfile = .strictAirgap,
        isHoldActive: Bool = false,
        activeHoldPolicy: ActiveHoldPolicy = ActiveHoldPolicy(),
        isCriticalReadGuardSatisfied: Bool = false,
        originTrust: OriginTrustKind = .unknown,
        originPID: Int32? = nil,
        originUID: UInt32? = nil
    ) -> SemanticInterceptSummary {
        let gateBadge = gateStateBadge(for: status)
        let profileBadge = securityProfile.rawValue
        let holdBadge = activeHoldBadge(isHoldActive: isHoldActive)
        let provBadge = provenanceBadge(for: originTrust)
        let provDetail = provenanceDetail(
            originTrust: originTrust,
            originPID: originPID,
            originUID: originUID
        )
        let normalizedSHA256 = resolveSHA256(provided: sha256, rawBytes: rawBytes)
        let guardMs = durationMilliseconds(activeHoldPolicy.criticalReadGuardDuration)
        let guardBadge = isCriticalReadGuardSatisfied
            ? "1.5s DWELL GUARD READY (\(guardMs)ms)"
            : "1.5s DWELL GUARD ACTIVE (\(guardMs)ms)"

        let fallbackTool = BridgeDisplayText.escaped(
            (toolHook?.isEmpty == false ? toolHook! : "UNPARSED_PAYLOAD"),
            limit: 64
        )

        guard !rawBytes.isEmpty else {
            return makeFailClosedSummary(
                reason: "Empty payload; failing closed to CRITICAL",
                fallbackTool: fallbackTool,
                gateStatus: status,
                gateBadge: gateBadge,
                securityProfile: securityProfile,
                profileBadge: profileBadge,
                isHoldActive: isHoldActive,
                holdBadge: holdBadge,
                provBadge: provBadge,
                provDetail: provDetail,
                guardDuration: activeHoldPolicy.criticalReadGuardDuration,
                guardMs: guardMs,
                isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
                guardBadge: guardBadge,
                sha256: normalizedSHA256,
                payloadByteCount: 0,
                originTrust: originTrust,
                originPID: originPID,
                originUID: originUID
            )
        }

        guard let utf8Text = String(data: rawBytes, encoding: .utf8) else {
            return makeFailClosedSummary(
                reason: "Invalid UTF-8 byte sequence; failing closed to CRITICAL",
                fallbackTool: fallbackTool,
                gateStatus: status,
                gateBadge: gateBadge,
                securityProfile: securityProfile,
                profileBadge: profileBadge,
                isHoldActive: isHoldActive,
                holdBadge: holdBadge,
                provBadge: provBadge,
                provDetail: provDetail,
                guardDuration: activeHoldPolicy.criticalReadGuardDuration,
                guardMs: guardMs,
                isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
                guardBadge: guardBadge,
                sha256: normalizedSHA256,
                payloadByteCount: rawBytes.count,
                originTrust: originTrust,
                originPID: originPID,
                originUID: originUID
            )
        }

        var parser = StrictSemanticJSONParser(utf8Text, maxDepth: maxJSONDepth)
        let parsedResult = parser.parseRoot()
        let rootPairs: [(String, SemanticJSONValue)]
        switch parsedResult {
        case .failure(let failure):
            return makeFailClosedSummary(
                reason: failure.reasonDescription,
                fallbackTool: fallbackTool,
                gateStatus: status,
                gateBadge: gateBadge,
                securityProfile: securityProfile,
                profileBadge: profileBadge,
                isHoldActive: isHoldActive,
                holdBadge: holdBadge,
                provBadge: provBadge,
                provDetail: provDetail,
                guardDuration: activeHoldPolicy.criticalReadGuardDuration,
                guardMs: guardMs,
                isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
                guardBadge: guardBadge,
                sha256: normalizedSHA256,
                payloadByteCount: rawBytes.count,
                originTrust: originTrust,
                originPID: originPID,
                originUID: originUID
            )
        case .success(let value):
            guard case .object(let pairs) = value else {
                return makeFailClosedSummary(
                    reason: "JSON root is not an object; failing closed to CRITICAL",
                    fallbackTool: fallbackTool,
                    gateStatus: status,
                    gateBadge: gateBadge,
                    securityProfile: securityProfile,
                    profileBadge: profileBadge,
                    isHoldActive: isHoldActive,
                    holdBadge: holdBadge,
                    provBadge: provBadge,
                    provDetail: provDetail,
                    guardDuration: activeHoldPolicy.criticalReadGuardDuration,
                    guardMs: guardMs,
                    isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
                    guardBadge: guardBadge,
                    sha256: normalizedSHA256,
                    payloadByteCount: rawBytes.count,
                    originTrust: originTrust,
                    originPID: originPID,
                    originUID: originUID
                )
            }
            rootPairs = pairs
        }

        let extracted = extractToolAndFields(from: rootPairs, fallbackToolHook: toolHook)
        var overallRisk = extracted.baseRiskLevel
        var riskReasons = extracted.baseRiskReasons

        for diff in extracted.fieldDiffs {
            if diff.riskLevel > overallRisk {
                overallRisk = diff.riskLevel
            }
            if let reason = diff.riskReason, !riskReasons.contains(reason) {
                riskReasons.append(reason)
            }
        }

        if rawBytes.count > 4096 && overallRisk < .medium {
            overallRisk = .medium
            riskReasons.append("Large payload (\(rawBytes.count) bytes)")
        }

        if riskReasons.isEmpty {
            riskReasons.append("Standard \(overallRisk.rawValue) risk inspection classification")
        }

        return SemanticInterceptSummary(
            gateStatus: status,
            gateStateBadge: gateBadge,
            securityProfile: securityProfile,
            securityProfileBadge: profileBadge,
            isHoldActive: isHoldActive,
            activeHoldBadge: holdBadge,
            provenanceBadge: provBadge,
            riskLevel: overallRisk,
            riskReasons: riskReasons.map { BridgeDisplayText.escaped($0, limit: 160) },
            toolName: extracted.toolName,
            methodName: extracted.methodName,
            targetSummary: extracted.targetSummary,
            criticalReadGuardDuration: activeHoldPolicy.criticalReadGuardDuration,
            criticalReadGuardMilliseconds: guardMs,
            isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
            criticalReadGuardBadge: guardBadge,
            controlStripBadges: defaultControlStripBadges,
            fieldDiffs: extracted.fieldDiffs,
            sha256: normalizedSHA256,
            payloadByteCount: rawBytes.count,
            originTrust: originTrust,
            originPID: originPID,
            originUID: originUID,
            provenanceDetailText: provDetail,
            isFailClosedMalformed: false
        )
    }

    // MARK: - Private Helpers

    private static func makeFailClosedSummary(
        reason: String,
        fallbackTool: String,
        gateStatus: InterlockStatus,
        gateBadge: String,
        securityProfile: ContainerSecurityProfile,
        profileBadge: String,
        isHoldActive: Bool,
        holdBadge: String,
        provBadge: SemanticProvenanceBadge,
        provDetail: String,
        guardDuration: Duration,
        guardMs: Int,
        isCriticalReadGuardSatisfied: Bool,
        guardBadge: String,
        sha256: String,
        payloadByteCount: Int,
        originTrust: OriginTrustKind,
        originPID: Int32?,
        originUID: UInt32?
    ) -> SemanticInterceptSummary {
        let escapedReason = BridgeDisplayText.escaped(reason, limit: 160)
        return SemanticInterceptSummary(
            gateStatus: gateStatus,
            gateStateBadge: gateBadge,
            securityProfile: securityProfile,
            securityProfileBadge: profileBadge,
            isHoldActive: isHoldActive,
            activeHoldBadge: holdBadge,
            provenanceBadge: provBadge,
            riskLevel: .critical,
            riskReasons: [escapedReason],
            toolName: fallbackTool,
            methodName: fallbackTool,
            targetSummary: "FAIL-CLOSED: \(escapedReason)",
            criticalReadGuardDuration: guardDuration,
            criticalReadGuardMilliseconds: guardMs,
            isCriticalReadGuardSatisfied: isCriticalReadGuardSatisfied,
            criticalReadGuardBadge: guardBadge,
            controlStripBadges: defaultControlStripBadges,
            fieldDiffs: [],
            sha256: sha256,
            payloadByteCount: payloadByteCount,
            originTrust: originTrust,
            originPID: originPID,
            originUID: originUID,
            provenanceDetailText: provDetail,
            isFailClosedMalformed: true
        )
    }

    private static func resolveSHA256(provided: String?, rawBytes: Data) -> String {
        if let provided, provided.count == 64, provided.allSatisfy(\.isHexDigit) {
            return provided.lowercased()
        }
        return SHA256.hash(data: rawBytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func durationMilliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let msFromSeconds = Int(seconds) * 1_000
        let msFromAtto = Int(attoseconds / 1_000_000_000_000_000)
        return max(0, msFromSeconds + msFromAtto)
    }

    private struct ExtractedPayloadData {
        let toolName: String
        let methodName: String
        let targetSummary: String
        let fieldDiffs: [SemanticPayloadFieldDiff]
        let baseRiskLevel: SemanticRiskLevel
        let baseRiskReasons: [String]
    }

    private static func extractToolAndFields(
        from rootPairs: [(String, SemanticJSONValue)],
        fallbackToolHook: String?
    ) -> ExtractedPayloadData {
        var rawMethod: String?
        var rawToolName: String?
        var paramsPairs: [(String, SemanticJSONValue)]?
        var argumentsValue: SemanticJSONValue?

        for (key, value) in rootPairs {
            switch key {
            case "method":
                if case .string(let str) = value { rawMethod = str }
            case "tool", "name":
                if case .string(let str) = value, rawToolName == nil { rawToolName = str }
            case "params":
                if case .object(let p) = value {
                    paramsPairs = p
                    for (pKey, pVal) in p {
                        if (pKey == "name" || pKey == "tool"), case .string(let s) = pVal {
                            rawToolName = s
                        } else if pKey == "arguments" || pKey == "input" {
                            argumentsValue = pVal
                        }
                    }
                }
            case "arguments":
                if argumentsValue == nil {
                    argumentsValue = value
                }
            default:
                break
            }
        }

        let resolvedMethod = rawMethod ?? fallbackToolHook ?? rawToolName ?? "jsonrpc.request"
        let resolvedTool = rawToolName ?? rawMethod ?? fallbackToolHook ?? "jsonrpc.request"

        let escapedMethod = BridgeDisplayText.escaped(resolvedMethod, limit: 80)
        let escapedTool = BridgeDisplayText.escaped(resolvedTool, limit: 80)

        var baseRisk: SemanticRiskLevel = .low
        var baseReasons: [String] = []

        let (toolRisk, toolReason) = classifyToolOrMethod(tool: resolvedTool, method: resolvedMethod)
        if toolRisk > baseRisk {
            baseRisk = toolRisk
        }
        if let toolReason {
            baseReasons.append(toolReason)
        }

        // Flatten fields: if `params.arguments` is a non-empty object/array, walk its fields first
        // with concise key paths, and also include any other non-boilerplate root/params fields.
        var diffs: [SemanticPayloadFieldDiff] = []
        var didExceedLimit = false
        if let argumentsValue {
            flattenJSONValue(
                argumentsValue,
                prefix: "",
                toolContext: resolvedTool,
                didExceedLimit: &didExceedLimit,
                into: &diffs
            )
        }
        if diffs.isEmpty, let paramsPairs {
            for (key, value) in paramsPairs where key != "name" {
                flattenJSONValue(
                    value,
                    prefix: key,
                    toolContext: resolvedTool,
                    didExceedLimit: &didExceedLimit,
                    into: &diffs
                )
            }
        }
        if diffs.isEmpty {
            for (key, value) in rootPairs where key != "jsonrpc" {
                flattenJSONValue(
                    value,
                    prefix: key,
                    toolContext: resolvedTool,
                    didExceedLimit: &didExceedLimit,
                    into: &diffs
                )
            }
        }
        if diffs.isEmpty {
            for (key, value) in rootPairs {
                flattenJSONValue(
                    value,
                    prefix: key,
                    toolContext: resolvedTool,
                    didExceedLimit: &didExceedLimit,
                    into: &diffs
                )
            }
        }

        if didExceedLimit {
            baseRisk = .critical
            baseReasons.append("Evaluated field limit exceeded; fail-closed to CRITICAL")
        }

        let target = resolveTargetSummary(from: diffs, toolName: escapedTool)

        return ExtractedPayloadData(
            toolName: escapedTool,
            methodName: escapedMethod,
            targetSummary: target,
            fieldDiffs: diffs,
            baseRiskLevel: baseRisk,
            baseRiskReasons: baseReasons
        )
    }

    private static func flattenJSONValue(
        _ value: SemanticJSONValue,
        prefix: String,
        toolContext: String,
        didExceedLimit: inout Bool,
        into diffs: inout [SemanticPayloadFieldDiff]
    ) {
        if diffs.count >= maxEvaluatedFields {
            didExceedLimit = true
            return
        }

        switch value {
        case .object(let pairs):
            if pairs.isEmpty {
                let path = prefix.isEmpty ? "{}" : prefix
                let (risk, reason) = classifyField(keyPath: path, rawValue: "{}", toolContext: toolContext)
                diffs.append(
                    SemanticPayloadFieldDiff(
                        id: "\(diffs.count):\(path)",
                        keyPath: path,
                        value: "{}",
                        valueType: "OBJECT",
                        riskLevel: risk,
                        riskReason: reason
                    )
                )
                return
            }
            for (key, child) in pairs {
                if diffs.count >= maxEvaluatedFields {
                    didExceedLimit = true
                    return
                }
                let nextPrefix = prefix.isEmpty ? key : "\(prefix).\(key)"
                if containsSpoofingControlOrBidi(key) {
                    diffs.append(
                        SemanticPayloadFieldDiff(
                            id: "\(diffs.count):\(nextPrefix)",
                            keyPath: nextPrefix,
                            value: "<KEY_SPOOFING_DETECTED>",
                            valueType: "KEY",
                            riskLevel: .critical,
                            riskReason: "Bidirectional override or control character in JSON key"
                        )
                    )
                }
                flattenJSONValue(child, prefix: nextPrefix, toolContext: toolContext, didExceedLimit: &didExceedLimit, into: &diffs)
            }
        case .array(let elements):
            if elements.isEmpty {
                let path = prefix.isEmpty ? "[]" : prefix
                let (risk, reason) = classifyField(keyPath: path, rawValue: "[]", toolContext: toolContext)
                diffs.append(
                    SemanticPayloadFieldDiff(
                        id: "\(diffs.count):\(path)",
                        keyPath: path,
                        value: "[]",
                        valueType: "ARRAY",
                        riskLevel: risk,
                        riskReason: reason
                    )
                )
                return
            }
            for (index, element) in elements.enumerated() {
                if diffs.count >= maxEvaluatedFields {
                    didExceedLimit = true
                    return
                }
                let nextPrefix = prefix.isEmpty ? "[\(index)]" : "\(prefix)[\(index)]"
                flattenJSONValue(element, prefix: nextPrefix, toolContext: toolContext, didExceedLimit: &didExceedLimit, into: &diffs)
            }
        case .string(let str):
            let path = prefix.isEmpty ? "value" : prefix
            let (risk, reason) = classifyField(keyPath: path, rawValue: str, toolContext: toolContext)
            diffs.append(
                SemanticPayloadFieldDiff(
                    id: "\(diffs.count):\(path)",
                    keyPath: path,
                    value: str,
                    valueType: "STRING",
                    riskLevel: risk,
                    riskReason: reason
                )
            )
        case .number(let num):
            let path = prefix.isEmpty ? "value" : prefix
            let (risk, reason) = classifyField(keyPath: path, rawValue: num, toolContext: toolContext)
            diffs.append(
                SemanticPayloadFieldDiff(
                    id: "\(diffs.count):\(path)",
                    keyPath: path,
                    value: num,
                    valueType: "NUMBER",
                    riskLevel: risk,
                    riskReason: reason
                )
            )
        case .bool(let flag):
            let path = prefix.isEmpty ? "value" : prefix
            let raw = flag ? "true" : "false"
            let (risk, reason) = classifyField(keyPath: path, rawValue: raw, toolContext: toolContext)
            diffs.append(
                SemanticPayloadFieldDiff(
                    id: "\(diffs.count):\(path)",
                    keyPath: path,
                    value: raw,
                    valueType: "BOOL",
                    riskLevel: risk,
                    riskReason: reason
                )
            )
        case .null:
            let path = prefix.isEmpty ? "value" : prefix
            diffs.append(
                SemanticPayloadFieldDiff(
                    id: "\(diffs.count):\(path)",
                    keyPath: path,
                    value: "null",
                    valueType: "NULL",
                    riskLevel: .low,
                    riskReason: nil
                )
            )
        }
    }

    private static func resolveTargetSummary(
        from diffs: [SemanticPayloadFieldDiff],
        toolName: String
    ) -> String {
        let prioritySuffixes = [
            "container", "container_id", "containerid",
            "target", "path", "filepath", "file", "uri", "url",
            "socket", "mount", "device", "host", "command", "cmd",
        ]
        for suffix in prioritySuffixes {
            if let match = diffs.first(where: {
                let lower = $0.keyPath.lowercased()
                return lower == suffix || lower.hasSuffix(".\(suffix)")
            }), !match.value.isEmpty {
                return BridgeDisplayText.escaped("\(match.keyPath): \(match.value)", limit: 96)
            }
        }
        if let first = diffs.first {
            return BridgeDisplayText.escaped("\(first.keyPath): \(first.value)", limit: 96)
        }
        return BridgeDisplayText.escaped("TOOL \(toolName)", limit: 96)
    }

    private static func classifyToolOrMethod(
        tool: String,
        method: String
    ) -> (SemanticRiskLevel, String?) {
        if containsSpoofingControlOrBidi(tool) || containsSpoofingControlOrBidi(method) {
            return (.critical, "Bidirectional override or control character in tool/method name")
        }
        let combined = "\(tool) \(method)".lowercased()

        for pattern in criticalPatterns {
            if combined.contains(pattern) {
                return (.critical, "Critical pattern in tool/method: \(pattern)")
            }
        }

        let highRiskTools = [
            "bash", "sh", "zsh", "exec", "execute", "run_command", "shell",
            "terminal", "eval", "spawn", "system", "kill", "pkill", "docker_exec",
        ]
        for token in highRiskTools {
            if matchesIdentifierToken(combined, token: token) {
                return (.high, "Privileged execution tool: \(tool)")
            }
        }

        let mediumRiskTools = [
            "write", "edit", "patch", "create", "update", "move", "rename",
            "copy", "put", "post", "upload", "download", "fetch", "env",
        ]
        for token in mediumRiskTools {
            if combined.contains(token) {
                return (.medium, "Mutating or network tool: \(tool)")
            }
        }

        return (.low, nil)
    }

    private static let criticalPatterns: [String] = [
        "rm -rf",
        "rm -fr",
        "rm --no-preserve-root",
        "sudo",
        "/etc/shadow",
        "/etc/sudoers",
        "/etc/master.passwd",
        "/etc/passwd",
        "chmod 777",
        "chmod -r 777",
        "chmod +s",
        "chmod 4755",
        "chown root",
        "mkfs",
        "dd if=",
        "diskutil erasedisk",
        "mount ",
        "mount -",
        "umount ",
        "nsenter",
        "unshare",
        "chroot",
        "pivot_root",
        "insmod",
        "modprobe",
        "sock_raw",
        "af_packet",
        "/dev/mem",
        "/dev/kmem",
        "/dev/disk",
        "/var/run/docker.sock",
        "docker.sock",
        "--privileged",
        "cap_sys_admin",
        "cap_net_raw",
        "/dev/tcp/",
        "nc -e",
        "ncat -e",
        "curl | sh",
        "curl | bash",
        "wget | sh",
    ]

    private static let highPatterns: [String] = [
        "rm ",
        "unlink",
        "drop table",
        "truncate",
        "chmod",
        "chown",
        "iptables",
        "pfctl",
        "ifconfig",
        "ip link",
        "ssh ",
        "scp ",
        "sftp",
        "/etc/",
        "/root",
        "/system",
        "/library",
        ".ssh",
        "id_rsa",
        "socket",
        "0.0.0.0",
        "http://",
        "https://",
        "ws://",
        "wss://",
    ]

    private static let mediumPatterns: [String] = [
        "/tmp",
        "/var",
        "/opt",
        "/usr/local",
        "write",
        "delete",
        "overwrite",
        "export ",
    ]

    private static func classifyField(
        keyPath: String,
        rawValue: String,
        toolContext: String
    ) -> (SemanticRiskLevel, String?) {
        if containsSpoofingControlOrBidi(keyPath) || containsSpoofingControlOrBidi(rawValue) {
            return (.critical, "Bidirectional override or control character detected in \(keyPath)")
        }

        let lowerKey = keyPath.lowercased()
        let lowerVal = rawValue.lowercased()
        let normalizedPath = NSString(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)).standardizingPath.lowercased()
        let combined = "\(lowerKey)=\(lowerVal)"

        for pattern in criticalPatterns {
            if lowerVal.contains(pattern) || lowerKey.contains(pattern) || normalizedPath.contains(pattern) {
                return (.critical, "Destructive or privileged pattern (\(pattern)) in \(keyPath)")
            }
        }

        if (lowerKey.hasSuffix("privileged") || lowerKey.hasSuffix("hostnetwork") || lowerKey.hasSuffix("hostpid"))
            && lowerVal == "true"
        {
            return (.critical, "Privileged container capability enabled in \(keyPath)")
        }

        for pattern in highPatterns {
            if lowerVal.contains(pattern) || lowerKey.contains(pattern) || normalizedPath.contains(pattern) {
                return (.high, "High-risk pattern (\(pattern)) in \(keyPath)")
            }
        }

        let highRiskKeyNames = ["command", "cmd", "script", "shell", "exec", "raw_socket", "mount"]
        for keyToken in highRiskKeyNames {
            if lowerKey == keyToken || lowerKey.hasSuffix(".\(keyToken)") {
                if keyToken == "raw_socket" || keyToken == "mount" {
                    return (.critical, "Critical capability key: \(keyPath)")
                }
                return (.high, "Command execution field: \(keyPath)")
            }
        }

        for pattern in mediumPatterns {
            if combined.contains(pattern) {
                return (.medium, "Moderate-risk target or operation (\(pattern)) in \(keyPath)")
            }
        }

        return (.low, nil)
    }

    private static func matchesIdentifierToken(_ text: String, token: String) -> Bool {
        let parts = text.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        return parts.contains { $0 == Substring(token) }
    }

    private static func containsSpoofingControlOrBidi(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x0000...0x0008, 0x000B, 0x000C, 0x000E...0x001F, 0x007F...0x009F,
                 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                return true
            default:
                continue
            }
        }
        return false
    }
}

// MARK: - Strict RFC 8259 JSON Parser (Max Depth 32, Duplicate Key Rejection)

private enum SemanticJSONValue: Sendable {
    case object([(String, SemanticJSONValue)])
    case array([SemanticJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

private enum SemanticParseFailure: Error, Sendable {
    case maxDepthExceeded(Int)
    case duplicateKey(String)
    case malformedSyntax

    var reasonDescription: String {
        switch self {
        case .maxDepthExceeded(let limit):
            "JSON nesting depth exceeds \(limit) levels; failing closed to CRITICAL"
        case .duplicateKey(let key):
            "Duplicate JSON key '\(key)' detected; failing closed to CRITICAL"
        case .malformedSyntax:
            "Malformed JSON payload; failing closed to CRITICAL"
        }
    }
}

private struct StrictSemanticJSONParser {
    private let bytes: [UInt8]
    private let maxDepth: Int
    private var index = 0

    init(_ text: String, maxDepth: Int) {
        self.bytes = Array(text.utf8)
        self.maxDepth = maxDepth
    }

    mutating func parseRoot() -> Result<SemanticJSONValue, SemanticParseFailure> {
        skipWhitespace()
        let result = parseValue(depth: 0)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            skipWhitespace()
            guard index == bytes.count else {
                return .failure(.malformedSyntax)
            }
            return .success(value)
        }
    }

    private mutating func parseValue(depth: Int) -> Result<SemanticJSONValue, SemanticParseFailure> {
        guard depth <= maxDepth else {
            return .failure(.maxDepthExceeded(maxDepth))
        }
        guard index < bytes.count else {
            return .failure(.malformedSyntax)
        }
        switch bytes[index] {
        case 0x7B:
            return parseObject(depth: depth + 1)
        case 0x5B:
            return parseArray(depth: depth + 1)
        case 0x22:
            guard let str = parseString() else { return .failure(.malformedSyntax) }
            return .success(.string(str))
        case 0x74:
            return consumeLiteral([0x74, 0x72, 0x75, 0x65]) ? .success(.bool(true)) : .failure(.malformedSyntax)
        case 0x66:
            return consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) ? .success(.bool(false)) : .failure(.malformedSyntax)
        case 0x6E:
            return consumeLiteral([0x6E, 0x75, 0x6C, 0x6C]) ? .success(.null) : .failure(.malformedSyntax)
        case 0x2D, 0x30...0x39:
            guard let num = parseNumber() else { return .failure(.malformedSyntax) }
            return .success(.number(num))
        default:
            return .failure(.malformedSyntax)
        }
    }

    private mutating func parseObject(depth: Int) -> Result<SemanticJSONValue, SemanticParseFailure> {
        guard depth <= maxDepth else {
            return .failure(.maxDepthExceeded(maxDepth))
        }
        index += 1 // '{'
        skipWhitespace()
        if consumeByte(0x7D) { return .success(.object([])) }
        var pairs: [(String, SemanticJSONValue)] = []
        var seenKeys = Set<String>()
        while true {
            skipWhitespace()
            guard let key = parseString() else { return .failure(.malformedSyntax) }
            guard seenKeys.insert(key).inserted else {
                return .failure(.duplicateKey(key))
            }
            skipWhitespace()
            guard consumeByte(0x3A) else { return .failure(.malformedSyntax) }
            skipWhitespace()
            let childValue: SemanticJSONValue
            switch parseValue(depth: depth) {
            case .failure(let err):
                return .failure(err)
            case .success(let val):
                childValue = val
            }
            pairs.append((key, childValue))
            skipWhitespace()
            if consumeByte(0x7D) { return .success(.object(pairs)) }
            guard consumeByte(0x2C) else { return .failure(.malformedSyntax) }
        }
    }

    private mutating func parseArray(depth: Int) -> Result<SemanticJSONValue, SemanticParseFailure> {
        guard depth <= maxDepth else {
            return .failure(.maxDepthExceeded(maxDepth))
        }
        index += 1 // '['
        skipWhitespace()
        if consumeByte(0x5D) { return .success(.array([])) }
        var elements: [SemanticJSONValue] = []
        while true {
            skipWhitespace()
            switch parseValue(depth: depth) {
            case .failure(let err):
                return .failure(err)
            case .success(let val):
                elements.append(val)
            }
            skipWhitespace()
            if consumeByte(0x5D) { return .success(.array(elements)) }
            guard consumeByte(0x2C) else { return .failure(.malformedSyntax) }
        }
    }

    private mutating func parseString() -> String? {
        guard consumeByte(0x22) else { return nil }
        var scalars: [UnicodeScalar] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                return String(String.UnicodeScalarView(scalars))
            }
            if byte == 0x5C {
                guard let escaped = parseEscape() else { return nil }
                scalars.append(escaped)
                continue
            }
            guard byte >= 0x20 else { return nil }
            index -= 1
            guard let scalar = decodeUTF8Scalar() else { return nil }
            scalars.append(scalar)
        }
        return nil
    }

    private mutating func parseEscape() -> UnicodeScalar? {
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        index += 1
        switch byte {
        case 0x22: return UnicodeScalar(0x22)
        case 0x5C: return UnicodeScalar(0x5C)
        case 0x2F: return UnicodeScalar(0x2F)
        case 0x62: return UnicodeScalar(0x08)
        case 0x66: return UnicodeScalar(0x0C)
        case 0x6E: return UnicodeScalar(0x0A)
        case 0x72: return UnicodeScalar(0x0D)
        case 0x74: return UnicodeScalar(0x09)
        case 0x75:
            guard let unit = parseHexQuad() else { return nil }
            if (0xD800...0xDBFF).contains(unit) {
                guard consumeByte(0x5C), consumeByte(0x75), let low = parseHexQuad(),
                      (0xDC00...0xDFFF).contains(low) else { return nil }
                let value = 0x10000 + ((UInt32(unit - 0xD800) << 10) | UInt32(low - 0xDC00))
                return UnicodeScalar(value)
            }
            guard !(0xDC00...0xDFFF).contains(unit) else { return nil }
            return UnicodeScalar(unit)
        default:
            return nil
        }
    }

    private mutating func parseHexQuad() -> UInt16? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt16
            switch byte {
            case 0x30...0x39: digit = UInt16(byte - 0x30)
            case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
            default: return nil
            }
            value = (value << 4) | digit
        }
        return value
    }

    private mutating func decodeUTF8Scalar() -> UnicodeScalar? {
        let start = index
        let b0 = bytes[index]
        let length: Int
        switch b0 {
        case 0x00...0x7F: length = 1
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return nil
        }
        guard start + length <= bytes.count else { return nil }
        index += length
        guard let string = String(bytes: bytes[start..<(start + length)], encoding: .utf8),
              string.unicodeScalars.count == 1,
              let scalar = string.unicodeScalars.first else { return nil }
        return scalar
    }

    private mutating func parseNumber() -> String? {
        let start = index
        if bytes[index] == 0x2D {
            index += 1
            guard index < bytes.count else { return nil }
        }
        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) { return nil }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else { return nil }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { return nil }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { return nil }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        return String(bytes: bytes[start..<index], encoding: .utf8)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func consumeByte(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) -> Bool {
        guard index + literal.count <= bytes.count else { return false }
        for offset in 0..<literal.count where bytes[index + offset] != literal[offset] {
            return false
        }
        index += literal.count
        return true
    }
}
