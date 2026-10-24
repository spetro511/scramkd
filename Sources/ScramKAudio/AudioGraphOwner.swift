import AVFoundation
import CScramKAudioRealtime
import Foundation

protocol AudioGraphDriving: Actor {
    func start(storage: AudioRealtimeStorage, generation: UInt64,
               invalidated: @escaping @Sendable (UInt64) async -> Void) async throws
    func stop(generation: UInt64) async -> ScramKAudioError?
}

/// Serial graph operations are isolated from the producer actor and render callback.
actor AudioGraphOwner: AudioGraphDriving {
    enum Mode: Sendable { case hardware, offline }
    private let mode: Mode
    private var running: RunningAudioGraph?
    private var quarantine: AudioRealtimeStorage?
    private var fencedThrough: UInt64 = 0

    init(mode: Mode = .hardware) { self.mode = mode }

    func start(storage: AudioRealtimeStorage, generation: UInt64,
               invalidated: @escaping @Sendable (UInt64) async -> Void) async throws {
        // Reject reuse without manufacturing retirement for a block we already own.
        guard running?.storage !== storage, quarantine !== storage else {
            throw ScramKAudioError.staleGeneration
        }
        guard !Task.isCancelled else {
            tart_mark_callback_retired(storage.pointer)
            throw ScramKAudioError.operationCancelled
        }
        if let quarantine {
            guard tart_is_quiescent(quarantine.pointer) else {
                tart_mark_callback_retired(storage.pointer) // New allocation has no source.
                throw ScramKAudioError.cleanupIncomplete
            }
            self.quarantine = nil
        }
        guard generation > fencedThrough, running == nil, !tart_callback_is_retired(storage.pointer) else {
            tart_mark_callback_retired(storage.pointer) // No callback was created.
            throw ScramKAudioError.staleGeneration
        }
        tart_prepare_waveforms(storage.pointer) // Graph actor, before any source callback exists.
        do {
            running = try RunningAudioGraph(storage: storage, generation: generation,
                                            mode: mode, invalidated: invalidated)
        } catch let error as ScramKAudioError {
            quarantine = storage
            throw error
        } catch {
            quarantine = storage
            throw ScramKAudioError.graphStartFailed(String(describing: error))
        }
    }

    func stop(generation: UInt64) async -> ScramKAudioError? {
        fencedThrough = max(fencedThrough, generation)
        if let graph = running, graph.generation == generation {
            running = nil
            quarantine = graph.storage
            graph.close()
        }
        guard let pending = quarantine else { return nil }
        // Bounded control-side retirement check. No polling or task occurs in render.
        for _ in 0..<20 {
            if tart_is_quiescent(pending.pointer) {
                if quarantine === pending { quarantine = nil }
                return nil
            }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return .cleanupIncomplete }
        }
        return .cleanupIncomplete
    }

    /// Test-only mode is selected before engine creation; this never switches a live graph.
    func renderOffline(frames: UInt32) throws -> [[Float]] {
        guard mode == .offline, let graph = running, let engine = graph.engine,
              frames <= graph.storage.configuration.maximumFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: frames) else {
            throw ScramKAudioError.unsupportedFormat
        }
        let result: AVAudioEngineManualRenderingStatus
        do { result = try engine.renderOffline(frames, to: buffer) }
        catch { throw ScramKAudioError.offlineRenderingFailed(String(describing: error)) }
        guard result == .success, buffer.frameLength == frames, let data = buffer.floatChannelData else {
            throw ScramKAudioError.offlineRenderingFailed("MANUAL_RENDER_STATUS_\(result.rawValue)")
        }
        return (0..<Int(graph.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(frames)))
        }
    }
}

/// Confined to AudioGraphOwner. No graph object crosses an actor boundary.
private final class RunningAudioGraph {
    let storage: AudioRealtimeStorage
    let generation: UInt64
    let format: AVAudioFormat
    var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var observer: (any NSObjectProtocol)?
    private var notificationContinuation: AsyncStream<Void>.Continuation?
    private var notificationTask: Task<Void, Never>?
    private var retirementAdmittedToNative = false

    init(storage: AudioRealtimeStorage, generation: UInt64, mode: AudioGraphOwner.Mode,
         invalidated: @escaping @Sendable (UInt64) async -> Void) throws {
        self.storage = storage
        self.generation = generation
        let config = storage.configuration
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: config.sampleRate,
                                        channels: config.channels, interleaved: false) else {
            tart_mark_callback_retired(storage.pointer)
            throw ScramKAudioError.unsupportedFormat
        }
        self.format = format
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            if mode == .offline {
                // Must precede all mixer/output/node access; no hardware fallback.
                try engine.enableManualRenderingMode(.offline, format: format,
                                                     maximumFrameCount: config.maximumFrames)
            }
            source = try makeSource(storage: storage, format: format)
            guard let source else { throw ScramKAudioError.engineInitializationFailed }
            engine.attach(source)
            if mode == .hardware {
                let output = engine.outputNode.outputFormat(forBus: 0)
                guard output.sampleRate.isFinite, output.sampleRate > 0,
                      output.channelCount > 0 else { throw ScramKAudioError.deviceUnavailable }
            }
            engine.connect(source, to: engine.mainMixerNode, format: format)
            if mode == .hardware {
                let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                notificationContinuation = pair.continuation
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [storage, continuation = pair.continuation] _ in
                    // Internal notification queue, not render. Irreversible fault fence.
                    tart_mark_device_changed(storage.pointer)
                    continuation.yield(())
                }
                notificationTask = Task {
                    for await _ in pair.stream {
                        guard !Task.isCancelled else { return }
                        await invalidated(generation)
                        return
                    }
                }
            }
            engine.prepare()
            try engine.start()
        } catch {
            close()
            // A nil/throwing factory result can still have surviving native block
            // copies. Only an explicit pre-admission result permits this mark.
            if !retirementAdmittedToNative { tart_mark_callback_retired(storage.pointer) }
            throw error
        }
    }

    private func makeSource(storage: AudioRealtimeStorage, format: AVAudioFormat) throws -> AVAudioSourceNode {
        var status: UInt32 = UInt32(TART_NATIVE_SOURCE_INVALID_INPUT)
        var ownsRetirement = false
        let node = tart_create_source_node(storage.pointer, format, &status, &ownsRetirement)
        retirementAdmittedToNative = ownsRetirement
        guard status == UInt32(TART_NATIVE_SOURCE_OK), ownsRetirement, let node else {
            throw ScramKAudioError.graphStartFailed("NATIVE_SOURCE_FACTORY_\(status)")
        }
        return node
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        notificationContinuation?.finish()
        notificationContinuation = nil
        notificationTask?.cancel()
        notificationTask = nil
        if let engine {
            engine.stop()
            if let source {
                engine.disconnectNodeOutput(source)
                engine.detach(source)
            }
        }
        source = nil
        engine = nil
    }
}
