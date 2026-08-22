import AVFoundation
import Combine
import Speech

private final class SpeechAudioBufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    nonisolated init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}

private final class SpeechRecognitionSink: @unchecked Sendable {
    weak var owner: SpeechInputService?
    let sessionID: UUID

    init(owner: SpeechInputService, sessionID: UUID) {
        self.owner = owner
        self.sessionID = sessionID
    }

    nonisolated func receive(_ result: SFSpeechRecognitionResult?, error: Error?) {
        let transcript = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let errorMessage = error?.localizedDescription
        let sessionID = sessionID
        Task { @MainActor [weak owner] in
            owner?.receiveRecognition(
                transcript,
                isFinal: isFinal,
                errorMessage: errorMessage,
                sessionID: sessionID
            )
        }
    }
}

struct SpeechTranscriptAccumulator {
    private(set) var committed = ""
    private(set) var live = ""

    var text: String { Self.merge(committed, live) }

    mutating func reset() {
        committed = ""
        live = ""
    }

    @discardableResult
    mutating func receive(_ text: String, isFinal: Bool) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return self.text }
        if isFinal {
            committed = Self.merge(committed, cleaned)
            live = ""
        } else {
            live = cleaned
        }
        return self.text
    }

    @discardableResult
    mutating func commitLive() -> String {
        committed = Self.merge(committed, live)
        live = ""
        return committed
    }

    static func merge(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        if prefix == suffix || prefix.hasSuffix(suffix) { return prefix }
        if suffix.hasPrefix(prefix) { return suffix }

        let maximumOverlap = min(prefix.count, suffix.count)
        if maximumOverlap > 0 {
            for length in stride(from: maximumOverlap, through: 1, by: -1) {
                if prefix.suffix(length) == suffix.prefix(length) {
                    return prefix + suffix.dropFirst(length)
                }
            }
        }

        let separator = needsSpace(after: prefix.last, before: suffix.first) ? " " : ""
        return prefix + separator + suffix
    }

    private static func needsSpace(after left: Character?, before right: Character?) -> Bool {
        guard let left, let right else { return false }
        if left.isWhitespace || right.isWhitespace { return false }
        if String(left).rangeOfCharacter(from: .punctuationCharacters) != nil { return false }
        if String(right).rangeOfCharacter(from: .punctuationCharacters) != nil { return false }
        return left.isASCII && right.isASCII
    }
}

@MainActor
final class SpeechInputService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = "点击开始语音输入"
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioBufferSink: SpeechAudioBufferSink?
    private var recognitionSink: SpeechRecognitionSink?
    private var tapInstalled = false
    private var activeSessionID: UUID?
    private var accumulator = SpeechTranscriptAccumulator()

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        lastError = nil
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            fail("当前语音识别服务不可用，请检查网络或稍后重试。")
            return
        }

        stop(clearStatus: false, commitLive: false)
        accumulator.reset()
        transcript = ""
        guard beginRecognitionSession(using: recognizer) else { return }
    }

    @discardableResult
    private func beginRecognitionSession(using recognizer: SFSpeechRecognizer) -> Bool {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            status = "正在听写 · 本机识别"
        } else {
            status = "正在听写 · 可能使用 Apple 在线识别"
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("没有检测到可用的麦克风输入。")
            return false
        }
        removeTapIfNeeded()
        let audioBufferSink = SpeechAudioBufferSink(request: request)
        Self.installTap(on: inputNode, format: format, sink: audioBufferSink)
        self.audioBufferSink = audioBufferSink
        tapInstalled = true

        let sessionID = UUID()
        activeSessionID = sessionID
        let recognitionSink = SpeechRecognitionSink(owner: self, sessionID: sessionID)
        self.recognitionSink = recognitionSink
        recognitionTask = Self.startRecognition(
            recognizer: recognizer,
            request: request,
            sink: recognitionSink
        )

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            return true
        } catch {
            fail("无法启动麦克风：\(error.localizedDescription)")
            return false
        }
    }

    func stop(clearStatus: Bool = true, commitLive: Bool = true) {
        if commitLive {
            transcript = accumulator.commitLive()
        }
        activeSessionID = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeTapIfNeeded()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        audioBufferSink = nil
        recognitionSink = nil
        isRecording = false
        if clearStatus { status = transcript.isEmpty ? "点击开始语音输入" : "语音已转成文字" }
    }

    private func requestPermissions() async -> Bool {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechStatus = await Self.requestSpeechAuthorization()
        } else {
            speechStatus = SFSpeechRecognizer.authorizationStatus()
        }
        guard speechStatus == .authorized else {
            fail("语音识别权限未开启。请到“系统设置 > 隐私与安全性 > 语音识别”允许 Reading Companion Open。")
            return false
        }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneAllowed: Bool
        switch microphoneStatus {
        case .authorized:
            microphoneAllowed = true
        case .notDetermined:
            microphoneAllowed = await Self.requestMicrophoneAuthorization()
        default:
            microphoneAllowed = false
        }
        guard microphoneAllowed else {
            fail("麦克风权限未开启。请到“系统设置 > 隐私与安全性 > 麦克风”允许 Reading Companion Open。")
            return false
        }
        return true
    }

    private func fail(_ message: String) {
        transcript = accumulator.commitLive()
        activeSessionID = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeTapIfNeeded()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        audioBufferSink = nil
        recognitionSink = nil
        isRecording = false
        status = "语音输入不可用"
        lastError = message
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    fileprivate func receiveRecognition(
        _ text: String?,
        isFinal: Bool,
        errorMessage: String?,
        sessionID: UUID
    ) {
        guard sessionID == activeSessionID else { return }
        if let text {
            transcript = accumulator.receive(text, isFinal: isFinal)
            if isFinal {
                continueAfterPause()
                return
            }
        }
        if let errorMessage, isRecording {
            fail("语音识别失败：\(errorMessage)")
        }
    }

    private func continueAfterPause() {
        guard isRecording, let recognizer, recognizer.isAvailable else {
            stop()
            return
        }

        activeSessionID = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeTapIfNeeded()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        audioBufferSink = nil
        recognitionSink = nil

        status = "正在听写 · 可停顿后继续"
        _ = beginRecognitionSession(using: recognizer)
    }

    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        sink: SpeechAudioBufferSink
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            sink.append(buffer)
        }
    }

    nonisolated private static func startRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        sink: SpeechRecognitionSink
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            sink.receive(result, error: error)
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }
}
