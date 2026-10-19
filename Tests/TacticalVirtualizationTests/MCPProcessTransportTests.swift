import Darwin
import Foundation
import os
@testable import TacticalVirtualization
import XCTest

@MainActor
final class MCPProcessTransportTests: XCTestCase {
    func testInitializationDoesNotSpawnAndStopBeforeStartIsTerminal() async throws {
        let transport = try MCPProcessTransport(configuration: .init(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: []))
        let initialPID = await transport.processIdentifier
        XCTAssertNil(initialPID)
        XCTAssertThrowsError(try transport.writer.writeChunk(Data([1]), offset: 0)) {
            XCTAssertEqual($0 as? MCPTransportError, .notStarted)
        }
        try await transport.stop()
        try await transport.stop()
        do {
            try await transport.start()
            XCTFail("A stopped generation must not restart")
        } catch { XCTAssertEqual(error as? MCPTransportError, .stopped) }
    }

    func testConfigurationRejectsNULAndInvalidEnvironmentKeys() throws {
        XCTAssertThrowsError(try MCPProcessTransport(configuration: .init(
            executableURL: URL(string: "https://example.invalid/tool") ?? URL(fileURLWithPath: "/"), arguments: []
        ))) { XCTAssertEqual($0 as? MCPTransportError, .invalidConfiguration) }
        XCTAssertThrowsError(try MCPProcessTransport(configuration: .init(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: ["invalid\0argument"]
        ))) { XCTAssertEqual($0 as? MCPTransportError, .invalidConfiguration) }
        XCTAssertThrowsError(try MCPProcessTransport(configuration: .init(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: ["INVALID=KEY": "value"]
        ))) { XCTAssertEqual($0 as? MCPTransportError, .invalidConfiguration) }
    }

    func testLaunchFailureIsTypedAndCleanupCanBeAwaitedRepeatedly() async throws {
        let transport = try MCPProcessTransport(configuration: .init(
            executableURL: URL(fileURLWithPath: "/nonexistent-tactical-fixture/tool"), arguments: []
        ))
        do {
            try await transport.start()
            XCTFail("Nonexistent executable must fail launch")
        } catch let error as MCPTransportError {
            guard case .launchFailed = error else { return XCTFail("Unexpected launch error: \(error)") }
        }
        try await transport.stop()
        try await transport.stop()
        let pid = await transport.processIdentifier
        XCTAssertNil(pid)
        XCTAssertThrowsError(try transport.writer.writeChunk(Data([1]), offset: 0)) {
            XCTAssertEqual($0 as? MCPTransportError, .stopped)
        }
    }

    func testMoreThan64KiBExactExchangeWithChildWaitingForNewline() async throws {
        // The child produces no response until the complete LF-terminated request arrives.
        // Response blocks are acknowledged so a fast fixture cannot accidentally test overflow
        // instead of the independent reader / backpressured writer contract.
        let configuration = try Self.pythonConfiguration(#"""
import os, sys
os.write(1, b'READY\n')
line = sys.stdin.buffer.readline(131073)
if not line.endswith(b'\n'):
    sys.exit(41)
for offset in range(0, len(line), 8192):
    block = line[offset:offset + 8192]
    while block:
        block = block[os.write(1, block):]
    if sys.stdin.buffer.readline(8) != b'ACK\n':
        sys.exit(42)
"""#)
        var payload = Data((0..<81_920).map { UInt8(65 + ($0 % 26)) })
        payload.append(0x0A)
        let expected = payload
        try await Self.withTransport(configuration) { transport in
            let ready = MCPIOCompletion<Void>()
            let reader = Task { () async throws -> Data in
                var received = Data()
                var acknowledgements = 0
                var stdoutEOF = false
                var status: Int32?
                for try await event in transport.output {
                    switch event {
                    case .stdout(let data):
                        XCTAssertLessThanOrEqual(data.count, 16_384)
                        received.append(data)
                        if received.count >= 6 {
                            XCTAssertEqual(received.prefix(6), Data("READY\n".utf8))
                            ready.finish(.success(()))
                            let bodyCount = received.count - 6
                            let blocks = (expected.count + 8191) / 8192
                            while acknowledgements < blocks,
                                  bodyCount >= min((acknowledgements + 1) * 8192, expected.count) {
                                try await Self.writeAll(Data("ACK\n".utf8), writer: transport.writer)
                                acknowledgements += 1
                            }
                        }
                    case .stderr(let data): XCTFail("Unexpected fixture stderr (\(data.count) bytes)")
                    case .stdoutEOF: stdoutEOF = true
                    case .exited(let code): status = code
                    }
                }
                XCTAssertTrue(stdoutEOF)
                XCTAssertEqual(status, 0)
                return Data(received.dropFirst(6))
            }
            do {
                try await transport.start()
                try await ready.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
                try await Self.writeAll(expected, writer: transport.writer)
                let received = try await Self.boundedValue(reader)
                XCTAssertEqual(received, expected)
            } catch {
                reader.cancel()
                _ = await reader.result
                throw error
            }
        }
    }

    func testSplitOutputAndStdoutEOFDoNotImplyProcessExit() async throws {
        let configuration = try Self.pythonConfiguration(#"""
import os, sys
os.write(1, b'alpha')
if sys.stdin.buffer.readline(8) != b'ACK\n':
    sys.exit(51)
os.write(2, b'diagnostic')
os.write(1, b'beta')
os.close(1)
if sys.stdin.buffer.readline(8) != b'ACK\n':
    sys.exit(52)
sys.exit(23)
"""#)
        try await Self.withTransport(configuration) { transport in
            try await transport.start()
            var iterator = transport.output.makeAsyncIterator()
            var stdout = Data()
            var stderr = Data()
            while stdout.count < 5, let event = try await iterator.next() {
                if case .stdout(let data) = event { stdout.append(data) }
            }
            XCTAssertEqual(stdout, Data("alpha".utf8))
            try await Self.writeAll(Data("ACK\n".utf8), writer: transport.writer)
            var sawEOF = false
            while !sawEOF, let event = try await iterator.next() {
                switch event {
                case .stdout(let data): stdout.append(data)
                case .stderr(let data): stderr.append(data)
                case .stdoutEOF: sawEOF = true
                case .exited: XCTFail("Child is blocked behind the second ACK, not exited")
                }
            }
            XCTAssertTrue(sawEOF)
            XCTAssertEqual(stdout, Data("alphabeta".utf8))
            let pidBeforeExit = await transport.processIdentifier
            XCTAssertNotNil(pidBeforeExit)
            try await Self.writeAll(Data("ACK\n".utf8), writer: transport.writer)
            var statuses: [Int32] = []
            while let event = try await iterator.next() {
                switch event {
                case .stderr(let data): stderr.append(data)
                case .exited(let status): statuses.append(status)
                case .stdoutEOF: XCTFail("stdout EOF must be emitted only once")
                case .stdout: XCTFail("stdout must not produce data after its EOF")
                }
            }
            XCTAssertEqual(stderr, Data("diagnostic".utf8))
            XCTAssertEqual(statuses, [23])
        }
    }

    func testOutputFloodFailsClosedAndAllBufferedChunksAreBounded() async throws {
        let configuration = try Self.pythonConfiguration(#"""
import os, sys
try:
    for _ in range(256):
        block = b'x' * 16384
        while block:
            block = block[os.write(1, block):]
except BrokenPipeError:
    sys.exit(31)
"""#)
        try await Self.withTransport(configuration) { transport in
            try await transport.start()
            // No consumer is admitted until source overflow has revoked and closed stdin.
            try await transport.writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            XCTAssertThrowsError(try transport.writer.writeChunk(Data([1]), offset: 0)) {
                XCTAssertEqual($0 as? MCPTransportError, .stopped)
            }
            var chunks = 0
            var bytes = 0
            do {
                for try await event in transport.output {
                    switch event {
                    case .stdout(let data), .stderr(let data):
                        XCTAssertLessThanOrEqual(data.count, 16_384)
                        chunks += 1
                        bytes += data.count
                    case .stdoutEOF, .exited: break
                    }
                }
                XCTFail("Overflow must finish with an error, not silently discard bytes")
            } catch { XCTAssertEqual(error as? MCPTransportError, .outputOverflow) }
            XCTAssertLessThanOrEqual(chunks, 8)
            XCTAssertLessThanOrEqual(bytes, 8 * 16_384)
        }
    }

    func testRepeatedStartStopReapsOnlyItsOwnedChild() async throws {
        for _ in 0..<4 {
            try await Self.withTransport(.init(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [])) { transport in
                try await transport.start()
                let first = await transport.processIdentifier
                XCTAssertNotNil(first)
                try await transport.start()
                let repeated = await transport.processIdentifier
                XCTAssertEqual(first, repeated)
                try await transport.stop()
                try await transport.stop()
                let stopped = await transport.processIdentifier
                XCTAssertNil(stopped)
                XCTAssertThrowsError(try transport.writer.writeChunk(Data([1]), offset: 0)) {
                    XCTAssertEqual($0 as? MCPTransportError, .stopped)
                }
                do {
                    try await transport.start()
                    XCTFail("Restart requires a new transport/writer generation")
                } catch { XCTAssertEqual(error as? MCPTransportError, .stopped) }
            }
        }
    }

    func testWriteBoundsAndReportedCountsAreAccurate() async throws {
        try await Self.withWriter { writer, readDescriptor, _ in
            let data = Data(repeating: 0x6D, count: 32_768)
            for (offset, maximumCount) in [(-1, 1), (Int.max, 1), (0, 0), (0, -1)] {
                XCTAssertThrowsError(try writer.writeChunk(data, offset: offset, maximumCount: maximumCount)) {
                    XCTAssertEqual($0 as? MCPTransportError, .invalidWriteRange)
                }
            }
            let result = try writer.writeChunk(data, offset: 7, maximumCount: Int.max)
            guard case .written(let count) = result else { return XCTFail("Empty pipe must accept some bytes") }
            XCTAssertGreaterThan(count, 0)
            XCTAssertLessThanOrEqual(count, 16_384)
            let drained = try Self.readAvailable(readDescriptor)
            XCTAssertEqual(drained, Data(repeating: 0x6D, count: count))
            XCTAssertEqual(try writer.writeChunk(data, offset: data.count), .written(0))
        }
    }

    func testFullPipeReadinessCancellationUsesRegisteredWaiter() async throws {
        let registered = MCPIOCompletion<Void>()
        try await Self.withWriter(onRegistered: { registered.finish(.success(())) }) { writer, _, _ in
            _ = try Self.fillPipe(writer)
            let wait = Task { try await writer.waitUntilWritable(deadline: ContinuousClock.now.advanced(by: .seconds(10))) }
            try await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            XCTAssertEqual(writer.pendingReadinessWaiterCount, 1)
            wait.cancel()
            do {
                try await wait.value
                XCTFail("Cancellation must settle the registered readiness waiter")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(writer.pendingReadinessWaiterCount, 0)
        }
    }

    func testFullPipeReadinessResumesAfterControlledDrain() async throws {
        let registered = MCPIOCompletion<Void>()
        try await Self.withWriter(onRegistered: { registered.finish(.success(())) }) { writer, readDescriptor, _ in
            let accepted = try Self.fillPipe(writer)
            let wait = Task { try await writer.waitUntilWritable(deadline: ContinuousClock.now.advanced(by: .seconds(3))) }
            try await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            let drained = try Self.readAvailable(readDescriptor)
            XCTAssertEqual(drained.count, accepted)
            XCTAssertTrue(drained.allSatisfy { $0 == 0x5A })
            try await Self.boundedValue(wait)
            let result = try writer.writeChunk(Data([0x2A]), offset: 0)
            XCTAssertEqual(result, .written(1))
            XCTAssertEqual(writer.pendingReadinessWaiterCount, 0)
        }
    }

    func testRevokeSettlesRegisteredWaitersAndNeverReopensWriter() async throws {
        let registered = MCPIOCompletion<Void>()
        try await Self.withWriter(onRegistered: { registered.finish(.success(())) }) { writer, _, _ in
            _ = try Self.fillPipe(writer)
            let wait = Task { try await writer.waitUntilWritable(deadline: ContinuousClock.now.advanced(by: .seconds(10))) }
            try await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            writer.revoke()
            writer.revoke()
            do {
                try await wait.value
                XCTFail("Revocation must settle readiness waiters")
            } catch { XCTAssertEqual(error as? MCPTransportError, .stopped) }
            try await writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            XCTAssertEqual(writer.pendingReadinessWaiterCount, 0)
            XCTAssertThrowsError(try writer.writeChunk(Data([1]), offset: 0)) {
                XCTAssertEqual($0 as? MCPTransportError, .stopped)
            }
        }
    }

    func testPastReadinessDeadlineDoesNotRegisterOrSpin() async throws {
        try await Self.withWriter { writer, _, _ in
            _ = try Self.fillPipe(writer)
            do {
                try await writer.waitUntilWritable(deadline: ContinuousClock.now)
                XCTFail("An expired readiness deadline must fail")
            } catch { XCTAssertEqual(error as? MCPTransportError, .deadlineExceeded) }
            XCTAssertEqual(writer.pendingReadinessWaiterCount, 0)
        }
    }

    func testRegisteredFullPipeWaiterExpiresWithoutPolling() async throws {
        let registered = MCPIOCompletion<Void>()
        try await Self.withWriter(onRegistered: { registered.finish(.success(())) }) { writer, _, _ in
            _ = try Self.fillPipe(writer)
            let wait = Task { try await writer.waitUntilWritable(deadline: ContinuousClock.now.advanced(by: .seconds(1))) }
            try await registered.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            do {
                try await wait.value
                XCTFail("A full undrained pipe must expire its registered readiness waiter")
            } catch { XCTAssertEqual(error as? MCPTransportError, .deadlineExceeded) }
            XCTAssertEqual(writer.pendingReadinessWaiterCount, 0)
        }
    }

    func testRevokedDescriptorNumberCanBeReusedWithoutWritingToReplacement() async throws {
        try await Self.withWriter { writer, _, oldWriteDescriptor in
            // Allocate the replacement before closing the old fd so its own ends are distinct.
            let replacement = try Self.makePipe()
            defer {
                XCTAssertEqual(Darwin.close(replacement.0), 0)
                XCTAssertEqual(Darwin.close(replacement.1), 0)
            }
            writer.revoke()
            try await writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            XCTAssertEqual(dup2(replacement.1, oldWriteDescriptor), oldWriteDescriptor)
            defer { XCTAssertEqual(Darwin.close(oldWriteDescriptor), 0) }
            XCTAssertThrowsError(try writer.writeChunk(Data("must-not-leak".utf8), offset: 0)) {
                XCTAssertEqual($0 as? MCPTransportError, .stopped)
            }
            XCTAssertTrue(try Self.readAvailable(replacement.0).isEmpty)
            writer.revoke()
            // Repeated revoke must not close a different owner that reused the old fd number.
            XCTAssertNotEqual(fcntl(oldWriteDescriptor, F_GETFD), -1)
        }
    }

    func testConsumerTerminationBeforeStdoutRegistrationAndStderrSetupFailureClosesTransferredReaders() async throws {
        let stages = OSAllocatedUnfairLock(initialState: [String]())
        let injected = MCPTransportError.posix(operation: "fixture-stderr-setup", code: EIO)
        var hooks = MCPProcessTransportTestHooks()
        hooks.beforeStdoutRegistration = { terminateOutput in
            // Run the real stream termination callback after ownership transfer but before the
            // stdout reader enters the pump's registry. No sleeps or blocking barriers.
            terminateOutput()
            stages.withLock { $0.append("consumer-terminated-before-registration") }
        }
        hooks.beforeStderrSetup = {
            stages.withLock { $0.append("second-reader-setup-failed") }
            throw injected
        }
        let transport = try MCPProcessTransport(
            configuration: .init(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: []), testHooks: hooks
        )
        do {
            try await transport.start()
            XCTFail("The injected second-reader setup failure must prevent spawning")
        } catch { XCTAssertEqual(error as? MCPTransportError, injected) }
        XCTAssertEqual(stages.withLock { $0 }, ["consumer-terminated-before-registration", "second-reader-setup-failed"])
        // This joins the transferred stdout source as well as stdin. The old race timed out
        // here because failStart skipped reader cleanup once the stream was already terminal.
        try await transport.stop()
        try await transport.waitForStdioCloseForTesting(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        let ownsProcess = await transport.hasOwnedProcessForTesting
        XCTAssertFalse(ownsProcess)
        var iterator = transport.output.makeAsyncIterator()
        let next = try await iterator.next()
        XCTAssertNil(next)
    }

    func testStopTimeoutSettlesOutputAndRetainsOwnedChildUntilControlledReap() async throws {
        let baseConfiguration = try Self.pythonConfiguration(#"""
import os, signal, sys
signal.signal(signal.SIGTERM, signal.SIG_IGN)
release = os.open(sys.argv[1], os.O_RDONLY)
os.write(1, b'READY\n')
value = os.read(release, 1)
os.close(release)
sys.exit(0 if value == b'x' else 61)
"""#)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("mcp-stop-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let releaseURL = directory.appendingPathComponent("release.fifo")
        defer {
            if FileManager.default.fileExists(atPath: releaseURL.path) {
                do { try FileManager.default.removeItem(at: releaseURL) }
                catch { XCTFail("Owned release FIFO cleanup failed: \(error)") }
            }
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Owned fixture directory cleanup failed: \(error)") }
        }
        guard mkfifo(releaseURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw MCPTransportError.posix(operation: "fixture-mkfifo", code: errno)
        }
        // O_RDWR keeps FIFO admission nonblocking and gives the child a release path independent
        // of all three stdio descriptors. No extra inherited fd or process signal is needed.
        let releaseDescriptor = open(releaseURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard releaseDescriptor >= 0 else { throw MCPTransportError.posix(operation: "fixture-fifo-open", code: errno) }
        defer { XCTAssertEqual(Darwin.close(releaseDescriptor), 0) }
        let ready = MCPIOCompletion<Void>()
        let reaped = MCPIOCompletion<Int32>()
        var hooks = MCPProcessTransportTestHooks()
        hooks.stopBudget = .zero
        hooks.onReaped = { reaped.finish(.success($0)) }
        let transport = try MCPProcessTransport(configuration: .init(
            executableURL: baseConfiguration.executableURL,
            arguments: baseConfiguration.arguments + [releaseURL.path], environment: baseConfiguration.environment
        ), testHooks: hooks)
        let consumer = Task { () async throws -> MCPTransportError? in
            var received = Data()
            do {
                for try await event in transport.output {
                    switch event {
                    case .stdout(let data):
                        received.append(data)
                        if received == Data("READY\n".utf8) { ready.finish(.success(())) }
                    case .stderr(let data): XCTFail("Unexpected fixture stderr (\(data.count) bytes)")
                    case .stdoutEOF: XCTFail("Stop must not invent stdout EOF")
                    case .exited: XCTFail("The child must remain behind its independent release FIFO")
                    }
                }
                return nil
            } catch let error as MCPTransportError { return error }
        }
        do {
            try await transport.start()
            try await ready.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let originalPID = await transport.processIdentifier
            XCTAssertNotNil(originalPID)
            do {
                try await transport.stop()
                XCTFail("The unreleased SIGTERM-ignoring child must exhaust the zero test budget")
            } catch { XCTAssertEqual(error as? MCPTransportError, .stopTimedOut) }
            // No cancellation of the consumer is used to make this assertion pass.
            let outputOutcome = try await Self.boundedValue(consumer)
            XCTAssertEqual(outputOutcome, .stopped)
            try await transport.waitForStdioCloseForTesting(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            let retainedPID = await transport.processIdentifier
            let ownsBeforeRelease = await transport.hasOwnedProcessForTesting
            XCTAssertEqual(retainedPID, originalPID)
            XCTAssertTrue(ownsBeforeRelease)
            XCTAssertThrowsError(try transport.writer.writeChunk(Data([1]), offset: 0)) {
                XCTAssertEqual($0 as? MCPTransportError, .stopped)
            }
            do {
                try await transport.start()
                XCTFail("Incomplete cleanup must not admit a replacement generation")
            } catch { XCTAssertEqual(error as? MCPTransportError, .stopped) }
            try Self.releaseFixture(releaseDescriptor)
            let status = try await reaped.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            XCTAssertEqual(status, 0)
            try await transport.stop()
            try await transport.stop()
            let ownsAfterReap = await transport.hasOwnedProcessForTesting
            let finalPID = await transport.processIdentifier
            XCTAssertFalse(ownsAfterReap)
            XCTAssertNil(finalPID)
        } catch {
            let primary = error
            // Every failure path releases the owned fixture rather than escalating to SIGKILL.
            do { try Self.releaseFixture(releaseDescriptor) }
            catch { XCTFail("Owned fixture release failed: \(error)") }
            consumer.cancel()
            _ = await consumer.result
            do { _ = try await reaped.wait(deadline: ContinuousClock.now.advanced(by: .seconds(5))) }
            catch { XCTFail("Owned fixture did not reap after controlled release: \(error)") }
            do { try await transport.stop() }
            catch { XCTFail("Owned fixture cleanup failed: \(error)") }
            throw primary
        }
    }

    func testPendingCompletionRejectsLateSuccessWithTimeoutCallbackHeld() async throws {
        // Both exact-boundary and after-deadline completion must reject a pending waiter.
        for lateness in [Duration.zero, .nanoseconds(1)] {
            let start = ContinuousClock.now
            let deadline = start.advanced(by: .seconds(10))
            let clock = OSAllocatedUnfairLock(initialState: start)
            let heldTimeout = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
            let timerArmed = MCPIOCompletion<Void>()
            let completion = MCPIOCompletion<Int>(now: { clock.withLock { $0 } }, scheduleTimeout: { _, expire in
                heldTimeout.withLock { $0 = expire }
                timerArmed.finish(.success(()))
            })
            let wait = Task { try await completion.wait(deadline: deadline) }
            defer { wait.cancel() }
            try await timerArmed.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            XCTAssertEqual(completion.pendingWaiterCount, 1)
            clock.withLock { $0 = deadline.advanced(by: lateness) }
            // The timer callback is still held. finish itself must reject the late success.
            completion.finish(.success(17))
            do {
                _ = try await wait.value
                XCTFail("Pending completion at/after its monotonic deadline must fail")
            } catch { XCTAssertEqual(error as? MCPTransportError, .deadlineExceeded) }
            let releaseTimeout = heldTimeout.withLock { $0 }
            XCTAssertNotNil(releaseTimeout)
            releaseTimeout?()
            XCTAssertEqual(completion.pendingWaiterCount, 0)
            // New observation of an already resolved event is expressly not a pending wait.
            let observed = try await completion.wait(deadline: start)
            XCTAssertEqual(observed, 17)
        }
    }

    func testCompletionBeforeDeadlineRemainsSuccessfulWhenTimerRunsLate() async throws {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(10))
        let clock = OSAllocatedUnfairLock(initialState: start)
        let heldTimeout = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let timerArmed = MCPIOCompletion<Void>()
        let completion = MCPIOCompletion<Int>(now: { clock.withLock { $0 } }, scheduleTimeout: { _, expire in
            heldTimeout.withLock { $0 = expire }
            timerArmed.finish(.success(()))
        })
        let wait = Task { try await completion.wait(deadline: deadline) }
        defer { wait.cancel() }
        try await timerArmed.wait(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        clock.withLock { $0 = deadline.advanced(by: .nanoseconds(-1)) }
        completion.finish(.success(29))
        clock.withLock { $0 = deadline.advanced(by: .nanoseconds(1)) }
        let releaseTimeout = heldTimeout.withLock { $0 }
        XCTAssertNotNil(releaseTimeout)
        releaseTimeout?()
        let result = try await wait.value
        XCTAssertEqual(result, 29)
        XCTAssertEqual(completion.pendingWaiterCount, 0)
    }

    // MARK: Owned local fixtures and bounded test operations

    private nonisolated static func releaseFixture(_ descriptor: Int32) throws {
        var byte: UInt8 = 0x78
        let written = withUnsafePointer(to: &byte) { Darwin.write(descriptor, $0, 1) }
        guard written == 1 else { throw MCPTransportError.posix(operation: "fixture-release", code: errno) }
    }

    private nonisolated static func pythonConfiguration(_ script: String) throws -> MCPProcessConfiguration {
        let path = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Owned local Python fixture unavailable at /usr/bin/python3")
        }
        return .init(executableURL: URL(fileURLWithPath: path), arguments: ["-u", "-c", script], environment: ["PYTHONUNBUFFERED": "1"])
    }

    private nonisolated static func withTransport(
        _ configuration: MCPProcessConfiguration,
        operation: @escaping @Sendable (MCPProcessTransport) async throws -> Void
    ) async throws {
        let transport = try MCPProcessTransport(configuration: configuration)
        let task = Task { try await operation(transport) }
        do {
            try await boundedValue(task)
            try await transport.stop()
        } catch {
            task.cancel()
            _ = await task.result
            do { try await transport.stop() }
            catch { XCTFail("Owned fixture cleanup failed: \(error)") }
            throw error
        }
    }

    private nonisolated static func boundedValue<Value: Sendable>(_ task: Task<Value, any Error>) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await task.value }
                group.addTask {
                    try await ContinuousClock().sleep(for: .seconds(10))
                    task.cancel()
                    throw MCPTransportError.deadlineExceeded
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw MCPTransportError.deadlineExceeded }
                return result
            }
        } onCancel: { task.cancel() }
    }

    private nonisolated static func writeAll(_ data: Data, writer: MCPNonblockingWriter) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            switch try writer.writeChunk(data, offset: offset) {
            case .written(let count):
                guard count > 0, count <= data.count - offset else { throw MCPTransportError.noWriteProgress }
                offset += count
            case .wouldBlock: try await writer.waitUntilWritable(deadline: deadline)
            }
        }
    }

    private nonisolated static func withWriter(
        onRegistered: (@Sendable () -> Void)? = nil,
        operation: @Sendable (MCPNonblockingWriter, Int32, Int32) async throws -> Void
    ) async throws {
        let pipe = try makePipe()
        defer { XCTAssertEqual(Darwin.close(pipe.0), 0) }
        let writer = MCPNonblockingWriter(onReadinessWaiterRegistered: onRegistered)
        do { try writer.install(descriptor: pipe.1) }
        catch { XCTAssertEqual(Darwin.close(pipe.1), 0); throw error }
        do {
            try await operation(writer, pipe.0, pipe.1)
            writer.revoke()
            try await writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        } catch {
            writer.revoke()
            do { try await writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(2))) }
            catch { XCTFail("Owned writer cleanup failed: \(error)") }
            throw error
        }
    }

    private nonisolated static func makePipe() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.pipe(base)
        }
        guard result == 0 else { throw MCPTransportError.posix(operation: "fixture-pipe", code: errno) }
        do { try MCPDescriptorConfiguration.nonblocking(descriptors[0]) }
        catch {
            XCTAssertEqual(Darwin.close(descriptors[0]), 0)
            XCTAssertEqual(Darwin.close(descriptors[1]), 0)
            throw error
        }
        return (descriptors[0], descriptors[1])
    }

    private nonisolated static func fillPipe(_ writer: MCPNonblockingWriter) throws -> Int {
        let block = Data(repeating: 0x5A, count: 16_384)
        var total = 0
        // Every iteration transfers bytes; EAGAIN exits immediately rather than spinning.
        for _ in 0..<1024 {
            switch try writer.writeChunk(block, offset: 0) {
            case .written(let count): total += count
            case .wouldBlock: return total
            }
        }
        throw MCPTransportError.noWriteProgress
    }

    private nonisolated static func readAvailable(_ descriptor: Int32) throws -> Data {
        var result = Data()
        for _ in 0..<1024 {
            var block = Data(count: 16_384)
            let count = block.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, buffer.count)
            }
            if count > 0 {
                block.count = count
                result.append(block)
            } else if count == 0 { return result }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return result }
            else { throw MCPTransportError.posix(operation: "fixture-read", code: errno) }
        }
        throw MCPTransportError.outputOverflow
    }
}
