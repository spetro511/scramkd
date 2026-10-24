import Foundation
import os

/// Control/test-only one-shot. Never captured or called by the render block.
/// Real ContinuousClock watchdog and synchronous cancellation resolve the actual
/// continuation, not a task-group race against an uncancellable suspended worker.
final class AudioWaitSignal: Sendable {
    private struct State: Sendable {
        var result: Result<Void, ScramKAudioError>?
        var continuation: CheckedContinuation<Void, any Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func succeed() { complete(.success(())) }
    func fail(_ error: ScramKAudioError) { complete(.failure(error)) }

    private func complete(_ result: Result<Void, ScramKAudioError>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard case nil = state.result else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        if let continuation { resume(continuation, result: result) }
    }

    private func resume(_ continuation: CheckedContinuation<Void, any Error>,
                        result: Result<Void, ScramKAudioError>) {
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    func wait(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let watchdog = Task { [self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return } // Watchdog cancellation is expected after resolution.
            fail(.waitTimedOut)
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready = state.withLock { state -> Result<Void, ScramKAudioError>? in
                    if let result = state.result { return result }
                    guard case nil = state.continuation else { return .failure(.operationInProgress) }
                    state.continuation = continuation
                    return nil
                }
                if let ready { resume(continuation, result: ready) }
            }
        } onCancel: { [self] in fail(.operationCancelled) }
    }
}
