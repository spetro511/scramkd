import CScramKAudioRealtime
import Foundation

/// Sole unchecked boundary: a non-owning, pointer-sized C address. No deinit,
/// reference fields, reclamation, or asynchronous work. The control actor owns the
/// allocation until final handle release AND producer/block retirement are proven.
struct AudioRawAddress: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Checked Sendable owning-access handle. C storage is NOT freed by Swift deinit.
/// All non-render users retain this handle across pointer access/awaits. The render
/// native marker keeps only a raw C address, so marker teardown cannot free C.
final class AudioRealtimeStorage: Sendable {
    let address: AudioRawAddress
    let configuration: AudioRenderConfiguration
    let allocationID: UUID
    let reclamation: AudioReclamationControl
    var pointer: OpaquePointer { address.pointer }

    fileprivate init(address: AudioRawAddress, configuration: AudioRenderConfiguration,
                     id: UUID, reclamation: AudioReclamationControl) {
        self.address = address
        self.configuration = configuration
        self.allocationID = id
        self.reclamation = reclamation
    }

    deinit {
        let control = reclamation
        let id = allocationID
        // Never executed by the render token: it has no reference to this handle.
        // Final non-render handle release hands reclamation to its explicit actor.
        Task { await control.handleReleased(id: id) }
    }

    /// CPU fixtures use a private one-slot control owner, never the output singleton.
    static func cpuForTesting(configuration: AudioRenderConfiguration) throws -> AudioRealtimeStorage {
        let address = try AudioReclamationControl.createAddress(configuration: configuration)
        let id = UUID()
        let control = AudioReclamationControl(initialAddress: address, id: id)
        return AudioRealtimeStorage(address: address, configuration: configuration, id: id, reclamation: control)
    }

    func control(epoch: UInt32, enabled: Bool, muted: Bool) {
        let flags = (enabled ? UInt32(TART_ENABLED) : 0) | (muted ? UInt32(TART_MUTED) : 0)
        tart_publish_control(pointer, TARTControl(epoch: epoch, flags: flags))
    }

    func observedCue(epoch: UInt32) -> ToneCue? {
        let progress = tart_load_progress(pointer)
        guard UInt32(truncatingIfNeeded: progress >> 32) == epoch, tart_load_fault(pointer) == 0 else { return nil }
        return ToneCue.fromAudioID(UInt32(truncatingIfNeeded: progress))
    }

    var faultError: ScramKAudioError? {
        switch tart_load_fault(pointer) {
        case 0: nil
        case UInt32(TART_DEVICE_CHANGED): .deviceChanged
        default: .renderingFailed
        }
    }
}

struct AudioReclamationEvidence: Sendable {
    let id: UUID
    let renderStarts: UInt64
    let onControlActor: Bool
}

/// Exclusive successful-C-destruction site. No actor call or task comes from the
/// raw render token. Production shares ONE slot across synthesizer instances, so
/// an orphaned/unconfirmed retirement cannot cause repeated replacement leaks.
actor AudioReclamationControl {
    static let output = AudioReclamationControl()
    private struct Allocation: Sendable {
        let address: AudioRawAddress
        let id: UUID
        var handleReleased = false
    }
    private var allocation: Allocation?
    private var lastReclaimed: AudioReclamationEvidence?
    private var quarantineRetention: AudioReclamationControl?

    init() {}
    fileprivate init(initialAddress: AudioRawAddress, id: UUID) {
        allocation = Allocation(address: initialAddress, id: id)
    }

    fileprivate nonisolated static func createAddress(configuration: AudioRenderConfiguration) throws -> AudioRawAddress {
        var error: UInt32 = 0
        let config = TARTConfig(sample_rate: configuration.sampleRate, channels: configuration.channels,
                               maximum_frames: configuration.maximumFrames)
        guard let pointer = tart_create(config, &error) else {
            if error == UInt32(TART_NOT_LOCK_FREE) { throw ScramKAudioError.atomicsNotLockFree }
            if error == UInt32(TART_ALLOCATION_FAILED) { throw ScramKAudioError.engineInitializationFailed }
            throw ScramKAudioError.unsupportedFormat
        }
        return AudioRawAddress(pointer: pointer)
    }

    func allocate(configuration: AudioRenderConfiguration) async throws -> AudioRealtimeStorage {
        // Permit final non-render handle-release messages to arrive without assuming
        // actor FIFO. This is a real-clock bounded wait, not a replacement allocation.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        for _ in 0..<30 {
            reclaimIfPossible()
            if allocation == nil { break }
            guard ContinuousClock.now < deadline else { throw ScramKAudioError.cleanupIncomplete }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { throw ScramKAudioError.operationCancelled }
        }
        guard allocation == nil else { throw ScramKAudioError.cleanupIncomplete }
        guard !Task.isCancelled else { throw ScramKAudioError.operationCancelled }
        let address = try Self.createAddress(configuration: configuration)
        let id = UUID()
        allocation = Allocation(address: address, id: id)
        quarantineRetention = self
        return AudioRealtimeStorage(address: address, configuration: configuration, id: id, reclamation: self)
    }

    func handleReleased(id: UUID) async {
        guard allocation?.id == id else { return }
        allocation?.handleReleased = true
        quarantineRetention = self
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        for _ in 0..<30 {
            guard allocation?.id == id else { return }
            reclaimIfPossible()
            if allocation == nil { return }
            guard ContinuousClock.now < deadline else { return }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return } // Allocation stays owned/quarantined; never freed speculatively.
        }
    }

    @discardableResult
    func reclaimIfPossible() -> Bool {
        self.assertIsolated()
        guard let allocation, allocation.handleReleased,
              tart_is_quiescent(allocation.address.pointer) else { return false }
        let starts = tart_load_started_count(allocation.address.pointer)
        guard tart_destroy_quiescent(allocation.address.pointer) else { return false }
        // No pointer access follows successful destruction.
        lastReclaimed = AudioReclamationEvidence(id: allocation.id, renderStarts: starts, onControlActor: true)
        self.allocation = nil
        quarantineRetention = nil
        return true
    }

    func evidence(id: UUID) -> AudioReclamationEvidence? {
        reclaimIfPossible()
        return lastReclaimed?.id == id ? lastReclaimed : nil
    }

    func waitForHandleRelease(id: UUID, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while allocation?.id == id && allocation?.handleReleased == false {
            guard ContinuousClock.now < deadline else { throw ScramKAudioError.waitTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForReclamation(id: UUID, timeout: Duration = .seconds(2)) async throws -> AudioReclamationEvidence {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let evidence = evidence(id: id) { return evidence }
            guard ContinuousClock.now < deadline else { throw ScramKAudioError.waitTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        } while true
    }
}
