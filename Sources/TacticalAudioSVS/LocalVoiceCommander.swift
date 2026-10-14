@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import TacticalCore

/// Actor managing 100% offline, on-device speech command recognition.
/// Uses Apple Neural Engine without external network transport.
public actor LocalVoiceCommander {
    private let speechRecognizer: SFSpeechRecognizer?
    private let interlockGate: HardwareInterlockGate
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isListening: Bool = false

    public init(interlockGate: HardwareInterlockGate, locale: Locale = Locale(identifier: "en-US")) {
        self.interlockGate = interlockGate
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Engages local Push-To-Talk speech capture and recognition.
    public func startPTT() async throws {
        guard !isListening else { return }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw HardwareInterlockError.subsystemFailure(reason: "Local speech recognizer unavailable")
        }

        // Enforce 100% on-device processing invariant
        guard recognizer.supportsOnDeviceRecognition else {
            throw HardwareInterlockError.subsystemFailure(reason: "On-device recognition not supported on this host")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        self.isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self, let result = result else { return }
            let transcription = result.bestTranscription.formattedString.uppercased()

            Task {
                await self.evaluateTacticalTokens(transcription)
            }
        }
    }

    /// Disengages PTT, cuts the audio bus, and flushes the recognition task.
    public func stopPTT() {
        guard isListening else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    /// Deterministic string tokenizer matching canonical tactical gate commands.
    func evaluateTacticalTokens(_ transcript: String) async {
        let tokens = transcript.split(separator: " ").map(String.init)
        guard let latestToken = tokens.last else { return }

        do {
            switch latestToken {
            case "ARM":
                try await interlockGate.arm()
            case "GRANT", "PERMISSIVE":
                try await interlockGate.grantPermissive()
            case "ABORT", "HALT":
                await interlockGate.tripEmergencyAbort(reason: "LOCAL_VOICE_PTT_ABORT")
            default:
                break
            }
        } catch {
            // Ignore non-ladder voice state violations
        }
    }

    deinit {
        audioEngine.stop()
        recognitionTask?.cancel()
    }
}
