import Darwin
import Dispatch
import Foundation
import os

/// Default-deny subprocess environment sanitizer stripping inherited host secrets,
/// proxy variables, and dynamic loader injection vectors.
public struct DefaultSubprocessEnvironmentScrubber: Sendable {
    public static let allowedKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"
    ]

    public static let fallbackPath: String =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public init() {}

    private static let forbiddenPathPrefixes: [String] = [
        "/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp"
    ]

    public static func sanitizePath(_ rawPath: String?) -> String {
        guard let rawPath, !rawPath.isEmpty else {
            return fallbackPath
        }
        let segments = rawPath.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { segment in
                guard !segment.isEmpty,
                      segment != ".",
                      segment != "..",
                      segment.hasPrefix("/"),
                      !segment.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                else {
                    return false
                }
                let lowered = segment.lowercased()
                for prefix in forbiddenPathPrefixes {
                    if lowered == prefix || lowered.hasPrefix(prefix + "/") {
                        return false
                    }
                }
                return true
            }
        return segments.isEmpty ? fallbackPath : segments.joined(separator: ":")
    }

    public static func scrub(
        _ raw: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var clean: [String: String] = [:]
        for key in allowedKeys {
            guard key != "PATH",
                  let value = raw[key],
                  !key.isEmpty,
                  !key.contains("="),
                  !key.utf8.contains(0),
                  !value.utf8.contains(0)
            else {
                continue
            }
            let sanitized = String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
            if !sanitized.isEmpty {
                clean[key] = sanitized
            }
        }
        clean["PATH"] = sanitizePath(raw["PATH"])
        return clean
    }
}

/// Alias/wrapper preserving `DefaultSubprocessCommandExecutor` environment scrubbing contract.
public struct DefaultSubprocessCommandExecutor: Sendable {
    public static let allowedKeys: Set<String> = DefaultSubprocessEnvironmentScrubber.allowedKeys
    public static let fallbackPath: String = DefaultSubprocessEnvironmentScrubber.fallbackPath

    public init() {}

    public static func sanitizePath(_ rawPath: String?) -> String {
        DefaultSubprocessEnvironmentScrubber.sanitizePath(rawPath)
    }

    public static func scrub(
        _ raw: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        DefaultSubprocessEnvironmentScrubber.scrub(raw)
    }
}

public struct MCPProcessConfiguration: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?

    public init(executableURL: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment ?? DefaultSubprocessEnvironmentScrubber.scrub()
    }
}

enum MCPTransportOutput: Sendable {
    case stdout(Data)
    case stderr(Data)
    case stdoutEOF
    case exited(Int32)
}

/// Internal deterministic fault/barrier seams. All callbacks are synchronous, run outside
/// descriptor/pump locks, and default to absent. Tests may shorten, never extend, stop's budget.
struct MCPProcessTransportTestHooks: Sendable {
    var beforeStdoutRegistration: (@Sendable (@Sendable () -> Void) -> Void)?
    var beforeStderrSetup: (@Sendable () throws -> Void)?
    var onReaped: (@Sendable (Int32) -> Void)?
    var stopBudget: Duration = .seconds(2)
}

/// Raw, protocol-independent stdio for one explicitly started, owned child process.
///
/// A transport is a single generation: start is idempotent while running, stop is idempotent,
/// and a stopped/exited instance cannot restart. Callers must explicitly await stop, including
/// after output failure or consumer cancellation. Neither EOF nor transmission proves an RPC
/// response, a container state change, rollback, or any authorization decision.
/// Exit observation may precede trailing pipe data. Natural completion waits for both output
/// EOFs; explicit stop terminates still-active output with .stopped independently of reaping, without
/// inventing stdoutEOF or claiming a full drain. That output error does not prove child exit.
actor MCPProcessTransport {
    nonisolated let writer: MCPNonblockingWriter
    nonisolated let output: AsyncThrowingStream<MCPTransportOutput, any Error>

    private enum Lifecycle: Equatable { case idle, running, exited, stopping, stopped }

    private let configuration: MCPProcessConfiguration
    private let generation = UUID()
    private let exit = MCPIOCompletion<Int32>()
    private let pump: MCPOutputPump
    private let testHooks: MCPProcessTransportTestHooks
    private let stopBudget: Duration
    private var process: Process?
    private var lifecycle = Lifecycle.idle
    private var identifier: Int32?
    private var stopDeadline: ContinuousClock.Instant?
    private var stopFailure: MCPTransportError?

    init(configuration: MCPProcessConfiguration) throws {
        try self.init(configuration: configuration, testHooks: .init())
    }

    init(configuration: MCPProcessConfiguration, testHooks: MCPProcessTransportTestHooks) throws {
        guard configuration.executableURL.isFileURL,
              configuration.executableURL.path.hasPrefix("/"),
              !configuration.executableURL.path.utf8.contains(0),
              !configuration.arguments.contains(where: { $0.utf8.contains(0) }),
              !(configuration.environment?.contains(where: {
                  $0.key.isEmpty || $0.key.contains("=") || $0.key.utf8.contains(0) || $0.value.utf8.contains(0)
              }) ?? false) else {
            throw MCPTransportError.invalidConfiguration
        }
        self.configuration = configuration
        self.testHooks = testHooks
        self.stopBudget = min(max(testHooks.stopBudget, .zero), .seconds(2))
        let writer = MCPNonblockingWriter()
        let pair = AsyncThrowingStream<MCPTransportOutput, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        self.writer = writer
        self.output = pair.stream
        let pump = MCPOutputPump(continuation: pair.continuation, writer: writer, testHooks: testHooks)
        self.pump = pump
        pair.continuation.onTermination = { [weak pump] _ in pump?.consumerTerminated() }
    }

    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return identifier
    }

    func start() async throws {
        switch lifecycle {
        case .running:
            guard process?.isRunning == true else {
                lifecycle = .exited
                throw MCPTransportError.stopped
            }
            return
        case .exited, .stopping, .stopped: throw MCPTransportError.stopped
        case .idle: break
        }
        try Task.checkCancellation()
        let pipes: MCPLaunchPipes
        do {
            pipes = try MCPLaunchPipes()
        } catch {
            failStart(error)
            throw error
        }
        let child = Process()
        child.executableURL = configuration.executableURL
        child.arguments = configuration.arguments
        child.environment = configuration.environment
        // These FileHandles do not own the descriptors. The launch scope closes each original
        // child end exactly once after run (or launch failure); libdispatch owns the parent ends.
        child.standardInput = FileHandle(fileDescriptor: pipes.descriptor(at: 0), closeOnDealloc: false)
        child.standardOutput = FileHandle(fileDescriptor: pipes.descriptor(at: 3), closeOnDealloc: false)
        child.standardError = FileHandle(fileDescriptor: pipes.descriptor(at: 5), closeOnDealloc: false)
        let exit = self.exit
        let pump = self.pump
        let generation = self.generation
        let onReaped = testHooks.onReaped
        child.terminationHandler = { [weak self, exit, pump, onReaped] child in
            // Extract Sendable values before the actor hop. Never send Foundation.Process.
            let status = child.terminationStatus
            pump.didExit(status)
            exit.finish(.success(status))
            onReaped?(status)
            Task { [weak self] in await self?.didExit(generation: generation) }
        }

        do {
            // Configure the actual pipe writer before making it available to any caller.
            let input = pipes.descriptor(at: 1)
            try writer.install(descriptor: input)
            pipes.relinquish(at: 1)
            try pump.install(stdout: pipes.descriptor(at: 2), stderr: pipes.descriptor(at: 4), relinquish: { index in
                pipes.relinquish(at: index)
            })
            try Task.checkCancellation()
            try child.run()
        } catch {
            let failure: any Error
            if error is CancellationError || error is MCPTransportError {
                failure = error
            } else {
                let foundationError = error as NSError
                failure = MCPTransportError.launchFailed(domain: foundationError.domain, code: foundationError.code)
            }
            // run failed, so there is no owned child to signal or reap.
            child.terminationHandler = nil
            let closeFailure = pipes.closeRemaining()
            failStart(failure)
            if let closeFailure { throw closeFailure }
            throw failure
        }

        process = child
        identifier = child.processIdentifier
        lifecycle = .running
        if let closeFailure = pipes.closeRemaining() {
            // Spawn succeeded: retain ownership, revoke admission, and force the caller down stop.
            writer.revoke()
            pump.fail(closeFailure)
            throw closeFailure
        }
    }

    /// Revokes admission immediately, closes stdio after source quiescence, sends SIGTERM only
    /// to Foundation's owned child if still running, and awaits Foundation's reaping callback.
    /// A single monotonic two-second budget covers all cleanup. No SIGKILL escalation or process
    /// group/container operation is performed. Timeout retains child ownership for a later stop.
    func stop() async throws {
        if lifecycle == .stopped {
            let deadline = ContinuousClock.now.advanced(by: stopBudget)
            var failure: MCPTransportError?
            var cancelled = false
            do { try await writer.waitForClose(deadline: deadline) }
            catch { collectStopError(error, into: &failure, cancelled: &cancelled) }
            do { try await pump.waitForClose(deadline: deadline) }
            catch { collectStopError(error, into: &failure, cancelled: &cancelled) }
            if cancelled { throw CancellationError() }
            if let failure { throw failure }
            if let stopFailure { throw stopFailure }
            return
        }
        if lifecycle == .idle {
            lifecycle = .stopped
            writer.revoke()
            pump.stopWithoutProcess()
            return
        }
        if lifecycle != .stopping {
            lifecycle = .stopping
            stopDeadline = ContinuousClock.now.advanced(by: stopBudget)
            writer.revoke()
            pump.beginStop()
            if let process, process.isRunning { process.terminate() }
        }
        // A timed-out stop is retryable, but no retry can reopen admission or signal a new child.
        let deadline = stopDeadline ?? ContinuousClock.now
        var failure: MCPTransportError?
        var cancelled = false
        do { try await writer.waitForClose(deadline: deadline) }
        catch { collectStopError(error, into: &failure, cancelled: &cancelled) }
        do { try await pump.waitForClose(deadline: deadline) }
        catch { collectStopError(error, into: &failure, cancelled: &cancelled) }
        var reaped = false
        do {
            _ = try await exit.wait(deadline: deadline)
            reaped = true
        } catch { collectStopError(error, into: &failure, cancelled: &cancelled) }
        if reaped {
            process?.terminationHandler = nil
            process = nil
            identifier = nil
            lifecycle = .stopped
            stopFailure = failure
        } else {
            // Permit another bounded reap attempt without resending SIGTERM.
            stopDeadline = ContinuousClock.now.advanced(by: stopBudget)
        }
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }

    // Read-only test witnesses: no signalling, reopening, or replacement of owned resources.
    var hasOwnedProcessForTesting: Bool { process != nil }

    func waitForStdioCloseForTesting(deadline: ContinuousClock.Instant) async throws {
        try await writer.waitForClose(deadline: deadline)
        try await pump.waitForClose(deadline: deadline)
    }

    private func collectStopError(_ error: any Error, into failure: inout MCPTransportError?, cancelled: inout Bool) {
        if error is CancellationError { cancelled = true; return }
        let typed = (error as? MCPTransportError) ?? .stopped
        let mapped: MCPTransportError = typed == .deadlineExceeded ? .stopTimedOut : typed
        if failure == nil { failure = mapped }
    }

    private func failStart(_ error: any Error) {
        lifecycle = .stopped
        writer.revoke()
        pump.fail(error)
        exit.finish(.failure(error))
    }

    private func didExit(generation: UUID) {
        guard generation == self.generation else { return }
        identifier = nil
        if lifecycle == .running { lifecycle = .exited }
    }
}

/// The only non-Sendable member is a Dispatch source, confined to synchronous lock access.
private final class MCPReadPipe: Sendable {
    private struct State {
        var source: (any DispatchSourceRead)?
        var cancelled = false
    }
    private enum ReadResult: Sendable { case bytes(Data), eof, again, failure(Int32) }

    private let descriptor: Int32
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let closed = MCPIOCompletion<Void>()
    private let bytes: @Sendable (Data) -> Void
    private let eof: @Sendable () -> Void
    private let failure: @Sendable (MCPTransportError) -> Void

    /// Configuration precedes ownership transfer. Once initialized, the cancellation handler
    /// alone closes the descriptor, including when the owner is released before callbacks run.
    init(descriptor: Int32, queue: DispatchQueue, bytes: @escaping @Sendable (Data) -> Void,
         eof: @escaping @Sendable () -> Void, failure: @escaping @Sendable (MCPTransportError) -> Void) throws {
        try MCPDescriptorConfiguration.nonblocking(descriptor)
        try MCPDescriptorConfiguration.closeOnExec(descriptor)
        self.descriptor = descriptor
        self.bytes = bytes
        self.eof = eof
        self.failure = failure
        state.withLock { state in
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            let closed = self.closed
            source.setCancelHandler {
                let result = Darwin.close(descriptor)
                if result == 0 { closed.finish(.success(())) }
                else { closed.finish(.failure(MCPTransportError.posix(operation: "output-close", code: errno))) }
            }
            state.source = source
            source.resume()
        }
    }

    deinit { cancel() }

    func cancel() {
        state.withLock { state in
            guard !state.cancelled else { return }
            state.cancelled = true
            state.source?.cancel()
            state.source = nil
        }
    }

    func waitForClose(deadline: ContinuousClock.Instant) async throws { try await closed.wait(deadline: deadline) }

    private func readAvailable() {
        // Bound each callback's work; the level-triggered source schedules remaining bytes.
        for _ in 0..<4 {
            let result = state.withLock { state -> ReadResult in
                guard !state.cancelled else { return .again }
                var data = Data(count: 16_384)
                let count = data.withUnsafeMutableBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return -1 }
                    return Darwin.read(descriptor, base, buffer.count)
                }
                if count > 0 {
                    data.count = count
                    return .bytes(data)
                }
                if count == 0 { return .eof }
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return .again }
                return .failure(code)
            }
            switch result {
            case .bytes(let data): bytes(data)
            case .again: return
            case .eof:
                cancel()
                eof()
                return
            case .failure(let code):
                cancel()
                failure(.posix(operation: "output-read", code: code))
                return
            }
        }
    }
}

/// Serializes stream admission, EOF/exit ordering, and fail-closed overload handling without
/// one Task per data event. Eight buffered events contain at most eight 16-KiB data chunks.
private final class MCPOutputPump: Sendable {
    private struct State: Sendable {
        var readers: [MCPReadPipe] = []
        var stdoutEOF = false
        var stderrEOF = false
        var exit: Int32?
        var terminal = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "scramk.mcp.output", qos: .utility)
    private let continuation: AsyncThrowingStream<MCPTransportOutput, any Error>.Continuation
    private let writer: MCPNonblockingWriter
    private let testHooks: MCPProcessTransportTestHooks

    init(continuation: AsyncThrowingStream<MCPTransportOutput, any Error>.Continuation, writer: MCPNonblockingWriter,
         testHooks: MCPProcessTransportTestHooks) {
        self.continuation = continuation
        self.writer = writer
        self.testHooks = testHooks
    }

    func install(stdout: Int32, stderr: Int32, relinquish: (Int) -> Void) throws {
        do {
            let output = try MCPReadPipe(descriptor: stdout, queue: queue, bytes: { [weak self] in
                self?.receive(.stdout($0))
            }, eof: { [weak self] in self?.didEOF(stdout: true) }, failure: { [weak self] in self?.fail($0) })
            relinquish(2)
            let continuation = self.continuation
            testHooks.beforeStdoutRegistration?({ continuation.finish() })
            _ = register(output)
            try testHooks.beforeStderrSetup?()
            let errors = try MCPReadPipe(descriptor: stderr, queue: queue, bytes: { [weak self] in
                self?.receive(.stderr($0))
            }, eof: { [weak self] in self?.didEOF(stdout: false) }, failure: { [weak self] in self?.fail($0) })
            relinquish(4)
            if register(errors) { throw MCPTransportError.consumerClosed }
        } catch {
            // Cleanup cannot depend on whether a consumer/overflow already finished the stream.
            fail(error)
            throw error
        }
    }

    /// Registration and terminal-state observation share one lock. If termination won first,
    /// this newly transferred reader is cancelled immediately; if registration won first,
    /// termination's snapshot includes it. It remains retained for close/join accounting.
    private func register(_ reader: MCPReadPipe) -> Bool {
        let terminal = state.withLock { state in
            state.readers.append(reader)
            return state.terminal
        }
        if terminal { reader.cancel() }
        return terminal
    }

    func didExit(_ status: Int32) {
        writer.revoke()
        let outcome = state.withLock { state -> Emission in
            guard !state.terminal else { return .none }
            state.exit = status
            return emit(.exited(status), state: &state)
        }
        settle(outcome)
        finishIfComplete()
    }

    func beginStop() {
        // Output is no longer readable once sources are cancelled. Settle its consumer now,
        // not on a future exit callback that a SIGTERM-resistant child may never produce.
        fail(MCPTransportError.stopped)
    }

    func stopWithoutProcess() {
        let shouldFinish = state.withLock { state in
            guard !state.terminal else { return false }
            state.terminal = true
            return true
        }
        if shouldFinish { continuation.finish() }
    }

    func consumerTerminated() {
        writer.revoke()
        let readers = state.withLock { state in
            state.terminal = true
            return state.readers
        }
        for reader in readers { reader.cancel() }
    }

    func fail(_ error: any Error) {
        let cleanup = state.withLock { state in
            let shouldFinish = !state.terminal
            state.terminal = true
            return (state.readers, shouldFinish)
        }
        writer.revoke()
        for reader in cleanup.0 { reader.cancel() }
        if cleanup.1 { continuation.finish(throwing: error) }
    }

    func waitForClose(deadline: ContinuousClock.Instant) async throws {
        let readers = state.withLock { $0.readers }
        var firstError: (any Error)?
        for reader in readers {
            do { try await reader.waitForClose(deadline: deadline) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private enum Emission: Sendable { case none, fail(MCPTransportError, [MCPReadPipe]) }

    // Called only with state held. finish is deliberately outside the lock because
    // AsyncStream onTermination can synchronously reenter the pump.
    private func emit(_ event: MCPTransportOutput, state: inout State) -> Emission {
        switch continuation.yield(event) {
        case .enqueued: return .none
        case .dropped:
            state.terminal = true
            return .fail(.outputOverflow, state.readers)
        case .terminated:
            state.terminal = true
            return .fail(.consumerClosed, state.readers)
        @unknown default:
            state.terminal = true
            return .fail(.outputOverflow, state.readers)
        }
    }

    private func receive(_ event: MCPTransportOutput) {
        let outcome = state.withLock { state in
            state.terminal ? Emission.none : emit(event, state: &state)
        }
        settle(outcome)
    }

    private func didEOF(stdout: Bool) {
        let outcome = state.withLock { state -> Emission in
            guard !state.terminal else { return .none }
            if stdout {
                guard !state.stdoutEOF else { return .none }
                state.stdoutEOF = true
                return emit(.stdoutEOF, state: &state)
            }
            state.stderrEOF = true
            return .none
        }
        settle(outcome)
        finishIfComplete()
    }

    private func settle(_ outcome: Emission) {
        if case .fail(let error, let readers) = outcome {
            writer.revoke()
            for reader in readers { reader.cancel() }
            continuation.finish(throwing: error)
        }
    }

    private func finishIfComplete() {
        let shouldFinish = state.withLock { state in
            guard !state.terminal, state.exit != nil,
                  state.stdoutEOF && state.stderrEOF else { return false }
            state.terminal = true
            return true
        }
        if shouldFinish { continuation.finish() }
    }
}

/// Actor-confined launch-scope ownership. Child ends are closed immediately after spawn; parent
/// ends transfer to source cancellation handlers. No descriptor is duplicated or closed twice.
private final class MCPLaunchPipes {
    private var descriptors: [Int32] = []

    init() throws {
        do {
            for _ in 0..<3 {
                var pair: [Int32] = [-1, -1]
                let result = pair.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    guard let base = buffer.baseAddress else { return -1 }
                    return Darwin.pipe(base)
                }
                guard result == 0 else { throw MCPTransportError.posix(operation: "pipe-create", code: errno) }
                descriptors.append(contentsOf: pair)
                for descriptor in pair { try MCPDescriptorConfiguration.closeOnExec(descriptor) }
            }
        } catch {
            // Preserve the primary setup error; there is no successfully launched child.
            let closeFailure = closeRemaining()
            if let closeFailure { throw closeFailure }
            throw error
        }
    }

    deinit {
        // Exceptional lifetime fallback only; all normal paths call closeRemaining explicitly.
        for descriptor in descriptors where descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    func descriptor(at index: Int) -> Int32 { descriptors[index] }
    func relinquish(at index: Int) { descriptors[index] = -1 }

    func closeRemaining() -> MCPTransportError? {
        var failure: MCPTransportError?
        for index in descriptors.indices where descriptors[index] >= 0 {
            let descriptor = descriptors[index]
            descriptors[index] = -1
            if Darwin.close(descriptor) != 0, failure == nil {
                // Never retry close(EINTR): the fd number may already have been reused.
                failure = .posix(operation: "launch-pipe-close", code: errno)
            }
        }
        return failure
    }
}
