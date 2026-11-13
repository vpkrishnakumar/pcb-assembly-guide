import AVFoundation
import Speech

/// Listens for spoken commands ("next", "back", "skip") so the guide can be stepped with both hands busy.
final class VoiceControl {
    enum Command {
        case next, back, skip
    }

    /// Called on the main queue.
    var onCommand: ((Command) -> Void)?
    /// Called on the main queue when listening stops because of a problem.
    var onFailure: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handledWords = 0
    private var isOn = false

    func start() {
        isOn = true
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                return self.fail("Speech recognition is not allowed. Enable it in System Settings › Privacy & Security.")
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        return self.fail("Microphone access is not allowed. Enable it in System Settings › Privacy & Security.")
                    }
                    if self.isOn { self.listen() }
                }
            }
        }
    }

    func stop() {
        isOn = false
        endSession()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.stop()
            self.onFailure?(message)
        }
    }

    private func endSession() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func listen() {
        guard let recognizer, recognizer.isAvailable else { return fail("Speech recognition is not available right now.") }
        endSession()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep audio on this Mac where the system supports it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        handledWords = 0

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return fail("No microphone was found.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return fail("The microphone could not be started: \(error.localizedDescription)")
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isOn, self.request === request else { return }
                if let result {
                    let words = result.bestTranscription.segments.map { $0.substring.lowercased() }
                    for word in words.dropFirst(min(self.handledWords, words.count)) {
                        if let command = Self.command(for: word) { self.onCommand?(command) }
                    }
                    self.handledWords = words.count
                }
                // Sessions end after about a minute or on silence, so start a fresh one.
                if error != nil || result?.isFinal == true {
                    self.endSession()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if self.isOn { self.listen() }
                    }
                }
            }
        }
    }

    private static func command(for word: String) -> Command? {
        switch word.trimmingCharacters(in: .punctuationCharacters) {
        case "next", "placed", "done", "okay", "ok": return .next
        case "back", "previous", "undo": return .back
        case "skip", "later": return .skip
        default: return nil
        }
    }
}
