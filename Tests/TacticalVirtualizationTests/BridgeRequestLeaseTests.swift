import Darwin
import Foundation
import TacticalCore
import XCTest
@testable import TacticalVirtualization

final class BridgeRequestLeaseTests: XCTestCase {
    private struct Fixture: Sendable {
        let fence: BridgeAdmissionFence
        let writer: MCPNonblockingWriter
        let gate: HardwareInterlockGate
        let generation: UUID
        let key: BridgeApprovalKey
        let frame: Data
        let deadline: ContinuousClock.Instant
        let readDescriptor: Int32
    }

    private static func withLease(frame: Data = Data("x\n".utf8), _ body: @Sendable (Fixture) async throws -> Void) async throws {
        var descriptors: [Int32] = [-1, -1]
        let pipeResult = descriptors.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return Darwin.pipe(base)
        }
        guard pipeResult == 0 else { throw MCPTransportError.posix(operation: "test-pipe", code: errno) }
        let readDescriptor = descriptors[0]
        defer { XCTAssertEqual(Darwin.close(readDescriptor), 0) }
        let writer = MCPNonblockingWriter()
        do { try writer.install(descriptor: descriptors[1]) }
        catch { XCTAssertEqual(Darwin.close(descriptors[1]), 0); throw error }
        let fence = BridgeAdmissionFence()
        let generation = UUID()
        let id = UUID()
        let key = BridgeAdmissionFence.key(requestID: id, generation: generation, frame: frame)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let gate = HardwareInterlockGate()
        do {
            try fence.install(generation: generation, writer: writer)
            try fence.register(id: id, generation: generation, frame: frame, key: key, deadline: deadline,
                               approval: BridgeOneShot(), response: BridgeOneShot())
            try await gate.arm()
            try await body(Fixture(fence: fence, writer: writer, gate: gate, generation: generation,
                                   key: key, frame: frame, deadline: deadline, readDescriptor: readDescriptor))
            fence.revoke(.currentConnection, reason: .detached)
            try await writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        } catch {
            writer.revoke()
            do { try await writer.waitForClose(deadline: ContinuousClock.now.advanced(by: .seconds(2))) }
            catch { XCTFail("Writer cleanup failed: \(error)") }
            throw error
        }
    }

    func testHashIncludesLFAndMismatchedFrozenBytesAreRejected() async throws {
        try await Self.withLease { fixture in
            let withoutLF = BridgeAdmissionFence.key(requestID: fixture.key.requestID, generation: fixture.generation,
                                                     frame: Data(fixture.frame.dropLast()))
            XCTAssertNotEqual(withoutLF.sha256, fixture.key.sha256)
            let otherID = UUID()
            let bad = BridgeApprovalKey(requestID: otherID, sha256: String(repeating: "0", count: 64), connectionGeneration: fixture.generation)
            XCTAssertThrowsError(try fixture.fence.register(id: otherID, generation: fixture.generation, frame: fixture.frame,
                                                          key: bad, deadline: fixture.deadline, approval: BridgeOneShot(), response: BridgeOneShot())) {
                XCTAssertEqual($0 as? BridgeError, .wrongHash)
            }
        }
    }

    func testBareCoreGrantCannotAuthorizeAWrite() async throws {
        try await Self.withLease { fixture in
            try await fixture.gate.grantPermissive()
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                            generation: fixture.generation, offset: 0,
                                                            now: ContinuousClock.now, deadline: fixture.deadline)
                XCTFail("An unbound Core grant cannot authorize bytes")
            } catch let error as BridgeError {
                guard case .gateRejected = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.bytes, 0)
        }
    }

    func testApprovalTupleAndExactDeadline() async throws {
        try await Self.withLease { fixture in
            let wrongHash = BridgeApprovalKey(requestID: fixture.key.requestID, sha256: "wrong", connectionGeneration: fixture.generation)
            do {
                _ = try await fixture.fence.approve(on: fixture.gate, key: wrongHash, now: ContinuousClock.now, nanoseconds: 1)
                XCTFail("Wrong hash accepted")
            } catch let error as BridgeError { XCTAssertEqual(error, .wrongHash) }
            let wrongGeneration = BridgeApprovalKey(requestID: fixture.key.requestID, sha256: fixture.key.sha256, connectionGeneration: UUID())
            do {
                _ = try await fixture.fence.approve(on: fixture.gate, key: wrongGeneration, now: ContinuousClock.now, nanoseconds: 1)
                XCTFail("Wrong generation accepted")
            } catch let error as BridgeError { XCTAssertEqual(error, .staleGeneration) }
            do {
                _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: fixture.deadline, nanoseconds: 1)
                XCTFail("Exact deadline must be expired")
            } catch let error as BridgeError { XCTAssertEqual(error, .expired) }
            let status = await fixture.gate.currentStatus
            XCTAssertEqual(status, .armed)
        }
    }

    func testFinalByteRelocksBeforeReturningAndLeaseCannotBeReused() async throws {
        try await Self.withLease { fixture in
            let receipt = try await fixture.fence.approve(on: fixture.gate, key: fixture.key,
                                                        now: ContinuousClock.now, nanoseconds: 1)
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            let first = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                               generation: fixture.generation, offset: 0,
                                                               now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
            XCTAssertEqual(first, .written(1))
            let final = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                               generation: fixture.generation, offset: 1,
                                                               now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
            XCTAssertEqual(final, .written(1))
            let status = await fixture.gate.currentStatus
            let cursor = await fixture.gate.observationSnapshot(historyLimit: 0).cursor
            XCTAssertEqual(status, .locked)
            XCTAssertGreaterThan(cursor, receipt.admittedGateCursor)
            XCTAssertEqual(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.stage, .complete)
            do {
                _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 2)
                XCTFail("Consumed approval reused")
            } catch let error as BridgeError { XCTAssertEqual(error, .staleApproval) }
        }
    }

    func testAbortResetRearmBeforeFinalByteCannotReuseOldGrantEpoch() async throws {
        try await Self.withLease { fixture in
            _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 1)
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                       generation: fixture.generation, offset: 0,
                                                       now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
            await fixture.gate.tripEmergencyAbort()
            try await fixture.gate.resetEmergencyAbort()
            try await fixture.gate.arm()
            try await fixture.gate.grantPermissive()
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                           generation: fixture.generation, offset: 1,
                                                           now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
                XCTFail("Final byte crossed an abort/reset/rearm epoch")
            } catch let error as BridgeError {
                guard case .gateRejected = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.bytes, 1)
            do { try fixture.fence.check(generation: fixture.generation); XCTFail("Partial connection must retire") }
            catch let error as BridgeError {
                guard case .revoked(.gateChanged, _) = error else { return XCTFail("Unexpected error: \(error)") }
            }
            // Cleanup must not lock the *new* grant even though it is permissive.
            try await fixture.fence.relockAbandoned(on: fixture.gate, id: fixture.key.requestID, generation: fixture.generation)
            let status = await fixture.gate.currentStatus
            XCTAssertEqual(status, .permissiveGranted)
        }
    }

    func testEAGAINThenAbortRejectsRetryWithoutObserverDelivery() async throws {
        try await Self.withLease(frame: Data(repeating: 0x41, count: 524_288)) { fixture in
            _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 1)
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            var offset = 0
            var blocked = false
            while offset < fixture.frame.count {
                let result = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                                    generation: fixture.generation, offset: offset,
                                                                    now: ContinuousClock.now, deadline: fixture.deadline)
                switch result {
                case .written(let count): offset += count
                case .wouldBlock: blocked = true
                }
                if blocked { break }
            }
            XCTAssertTrue(blocked, "Bounded fixture exceeds the private pipe's capacity")
            XCTAssertGreaterThan(offset, 0)
            let before = offset
            await fixture.gate.tripEmergencyAbort()
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                           generation: fixture.generation, offset: offset,
                                                           now: ContinuousClock.now, deadline: fixture.deadline)
                XCTFail("Readiness retry crossed abort")
            } catch let error as BridgeError {
                guard case .gateRejected(.emergencyAbortActive, _) = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.bytes, before)
        }
    }

    func testCurrentConnectionRevocationDoesNotPoisonNextGeneration() async throws {
        try await Self.withLease { fixture in
            let captured = fixture.fence.revoke(.currentConnection, reason: .windowClosed)
            XCTAssertEqual(captured, fixture.generation)
            fixture.fence.clear(generation: fixture.generation)
            let replacement = UUID()
            let newWriter = MCPNonblockingWriter()
            try fixture.fence.install(generation: replacement, writer: newWriter)
            fixture.fence.revoke(.connection(generation: fixture.generation), reason: .detached)
            XCTAssertNoThrow(try fixture.fence.check(generation: replacement))
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                           generation: fixture.generation, offset: 0,
                                                           now: ContinuousClock.now, deadline: fixture.deadline)
                XCTFail("Old generation reached the replacement writer")
            } catch let error as BridgeError { XCTAssertEqual(error, .staleGeneration) }
            fixture.fence.revoke(.currentConnection, reason: .detached)
        }
    }

    func testApprovalForADoesNotAuthorizeB() async throws {
        try await Self.withLease { fixture in
            _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 1)
            fixture.fence.revoke(.request(fixture.key), reason: .operatorDeclined)
            try await fixture.fence.relockAbandoned(on: fixture.gate, id: fixture.key.requestID, generation: fixture.generation)
            fixture.fence.remove(id: fixture.key.requestID, generation: fixture.generation)
            let id = UUID()
            let key = BridgeAdmissionFence.key(requestID: id, generation: fixture.generation, frame: fixture.frame)
            try fixture.fence.register(id: id, generation: fixture.generation, frame: fixture.frame, key: key,
                                       deadline: fixture.deadline, approval: BridgeOneShot(), response: BridgeOneShot())
            try fixture.fence.beginWrite(id: id, generation: fixture.generation)
            try await fixture.gate.arm()
            do {
                _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 2)
                XCTFail("Approval A accepted for B")
            } catch let error as BridgeError { XCTAssertEqual(error, .staleApproval) }
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: id, generation: fixture.generation,
                                                           offset: 0, now: ContinuousClock.now, deadline: fixture.deadline)
                XCTFail("B inherited A's authorization")
            } catch let error as BridgeError {
                guard case .gateRejected = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testPartialCancellationRetiresConnectionBeforeAnotherFrame() async throws {
        try await Self.withLease { fixture in
            _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 1)
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                       generation: fixture.generation, offset: 0,
                                                       now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
            fixture.fence.revoke(.request(fixture.key), reason: .requestCancelled)
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                           generation: fixture.generation, offset: 1,
                                                           now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
                XCTFail("Cancelled partial frame continued")
            } catch let error as BridgeError {
                guard case .revoked(.requestCancelled, _) = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.bytes, 1)
            XCTAssertThrowsError(try fixture.fence.register(id: UUID(), generation: fixture.generation, frame: Data("{}\n".utf8),
                                                          key: nil, deadline: nil, approval: nil, response: BridgeOneShot()))
        }
    }

    func testDetachAdmissionFenceRejectsFinalByteSynchronously() async throws {
        try await Self.withLease { fixture in
            _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: ContinuousClock.now, nanoseconds: 1)
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                       generation: fixture.generation, offset: 0,
                                                       now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
            fixture.fence.revoke(.currentConnection, reason: .windowClosed)
            do {
                _ = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                           generation: fixture.generation, offset: 1,
                                                           now: ContinuousClock.now, deadline: fixture.deadline, maximumCount: 1)
                XCTFail("Final byte crossed synchronous detach revocation")
            } catch let error as BridgeError {
                guard case .revoked(.windowClosed, _) = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.bytes, 1)
        }
    }

    func testCompletionBeforeAwaitResolvesExactlyOnce() async throws {
        let completion = BridgeOneShot<Int>()
        XCTAssertTrue(completion.finish(.success(7)))
        XCTAssertFalse(completion.finish(.failure(BridgeError.detached)))
        let observed = try await completion.value()
        XCTAssertEqual(observed, 7)
    }

    func testWriteBudgetStartsAtKeyedAdmissionNotAfterWorkerResumes() async throws {
        try await Self.withLease { fixture in
            let admittedAt = fixture.deadline.advanced(by: .seconds(-1))
            _ = try await fixture.fence.approve(on: fixture.gate, key: fixture.key, now: admittedAt, nanoseconds: 1)
            let leaseDeadline = try XCTUnwrap(fixture.fence.progress(id: fixture.key.requestID, generation: fixture.generation)?.writeDeadline)
            XCTAssertEqual(leaseDeadline, admittedAt.advanced(by: .seconds(5)))
            try fixture.fence.beginWrite(id: fixture.key.requestID, generation: fixture.generation)
            // Admission occurred before the approval deadline. The distinct
            // write budget remains valid after the presentation window ends.
            let result = try await fixture.fence.writePrivileged(on: fixture.gate, id: fixture.key.requestID,
                                                                generation: fixture.generation, offset: 0,
                                                                now: fixture.deadline.advanced(by: .seconds(1)), deadline: leaseDeadline)
            XCTAssertEqual(result, .written(fixture.frame.count))
        }
    }
}
