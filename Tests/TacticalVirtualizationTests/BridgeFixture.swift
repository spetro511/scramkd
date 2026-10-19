import Foundation
import TacticalCore
import XCTest
import os
@testable import TacticalVirtualization

enum BridgeFixture {
    struct Session: Sendable {
        let gate: HardwareInterlockGate
        let bridge: ContainerSocketBridge
        let info: ServerInfo
    }

    /// Inert process fixture: parses JSON and returns canned results. It never
    /// invokes host tools, imports ScreenEnv, contacts Docker, or executes payloads.
    static func configuration(mode: String = "normal") -> MCPProcessConfiguration {
        let script = #"""
        import sys, json, os
        mode = MODE
        deferred = []
        for raw in sys.stdin.buffer:
            request = json.loads(raw)
            method = request.get('method')
            rid = request.get('id')
            if method == 'notifications/initialized':
                continue
            if method == 'initialize':
                result = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}},
                          'serverInfo': {'name': 'offline-fixture', 'version': '1'}}
                if mode == 'badInit':
                    result['protocolVersion'] = 'UNSUPPORTED'
                response = {'jsonrpc': '2.0', 'id': rid, 'result': result}
            elif method == 'tools/list':
                response = {'jsonrpc': '2.0', 'id': rid, 'result': {'tools': [
                    {'name': 'fixture', 'inputSchema': {'type': 'object'}}]}}
            elif method == 'tools/call':
                if mode == 'withhold':
                    continue
                if mode == 'exitTool':
                    os._exit(7)
                if mode == 'remoteError':
                    response = {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32602, 'message': 'fixture error'}}
                else:
                    response = {'jsonrpc': '2.0', 'id': rid, 'result': {'content': [], 'isError': mode == 'toolError'}}
            else:
                if mode == 'malformed':
                    os.write(1, b'{not json}\n')
                    continue
                if mode == 'truncated':
                    os.write(1, b'{"jsonrpc":')
                    os._exit(8)
                response = {'jsonrpc': '2.0', 'id': rid, 'result': {}}
            if mode == 'wrongID' and method != 'initialize':
                response['id'] = '00000000-0000-0000-0000-000000000000'
            if mode == 'lowercaseID' and method != 'initialize':
                response['id'] = rid.lower() if rid.lower() != rid else rid + 'x'
            data = (json.dumps(response, separators=(',', ':')) + '\n').encode()
            if mode == 'reverse' and method in ('ping', 'tools/list'):
                deferred.append(data)
                if len(deferred) == 2:
                    os.write(1, deferred[1] + deferred[0])
                    deferred.clear()
                continue
            if mode == 'notify':
                data = b'{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}\n' + data
            os.write(1, data)
        """#.replacingOccurrences(of: "MODE", with: "'" + mode + "'")
        return MCPProcessConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script])
    }

    static func withSession(
        mode: String = "normal", timing: BridgeTiming = BridgeTiming(), hooks: BridgeTestHooks = BridgeTestHooks(),
        _ body: @Sendable (Session) async throws -> Void
    ) async throws {
        let gate = HardwareInterlockGate()
        let bridge = ContainerSocketBridge(interlockGate: gate, configuration: configuration(mode: mode), timing: timing, hooks: hooks)
        do {
            let info = try await bridge.attach()
            try await body(Session(gate: gate, bridge: bridge, info: info))
            let receipt = await bridge.detach()
            XCTAssertNotEqual(receipt.outcome, .cleanupIncomplete)
        } catch {
            let receipt = await bridge.detach()
            XCTAssertNotEqual(receipt.outcome, .cleanupIncomplete)
            throw error
        }
    }

    static func approveNext(_ session: Session, intercept: MCPIOCompletion<PendingIntercept>, arguments: Data = Data("{}".utf8)) async throws -> BridgeToolResult {
        try await session.gate.arm()
        let task = Task { try await session.bridge.submitTool(name: "fixture", argumentsJSON: arguments, generation: session.info.generation) }
        defer { task.cancel() }
        let pending = try await intercept.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        _ = try await session.bridge.approve(pending.approval)
        return try await task.value
    }
}

/// Logical time, advanced explicitly by tests. Cancellation unregisters sleepers;
/// advancing before a timeout task registers is handled by the deadline check.
final class BridgeManualClock: Sendable {
    private struct State: Sendable {
        var now: ContinuousClock.Instant
        var nanoseconds: UInt64 = 1
        var sleepers: [UUID: (ContinuousClock.Instant, BridgeOneShot<Void>)] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>

    init() { state = OSAllocatedUnfairLock(initialState: State(now: ContinuousClock.now)) }

    var timing: BridgeTiming {
        BridgeTiming(now: { self.state.withLock { $0.now } },
                     nanoseconds: { self.state.withLock { $0.nanoseconds } },
                     sleep: { try await self.sleep(until: $0) })
    }

    func advance(seconds: Int64) {
        let ready = state.withLock { state -> [BridgeOneShot<Void>] in
            state.now = state.now.advanced(by: .seconds(seconds))
            state.nanoseconds += UInt64(seconds) * 1_000_000_000
            let ids = state.sleepers.filter { $0.value.0 <= state.now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0)?.1 }
        }
        for completion in ready { completion.finish(.success(())) }
    }

    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        let completion = BridgeOneShot<Void>()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let ready = state.withLock { state -> Bool in
                if deadline <= state.now { return true }
                state.sleepers[id] = (deadline, completion)
                return false
            }
            if ready { completion.finish(.success(())) }
            defer { _ = state.withLock { $0.sleepers.removeValue(forKey: id) } }
            try await completion.value()
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            _ = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
        }
    }
}
