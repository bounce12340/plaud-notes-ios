import AVFoundation
import Observation

/// App 內建錄音（F11）。AAC M4A、48 kHz 單聲道；靠 UIBackgroundModes=audio 在背景持續錄音。
/// 待實機驗證：3 小時連續錄音、來電中斷後恢復、鎖定畫面狀態。
@MainActor
@Observable
final class Recorder: NSObject {
    enum State: Equatable { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    var lastError: String?

    private var recorder: AVAudioRecorder?
    private var currentID = UUID()
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    func start() async {
        guard state == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "沒有麥克風權限，請到「設定」開啟。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            currentID = UUID()
            let url = RecordingLibrary.recordingsDirectory
                .appending(path: "\(currentID.uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw RecorderError.failedToStart }
            recorder = r
            state = .recording
            startTimer()
            observeInterruptions()
        } catch {
            lastError = "無法開始錄音：\(error.localizedDescription)"
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if recorder?.record() == true { state = .recording }
    }

    /// 停止並回傳新的錄音項目（由呼叫端加入 RecordingLibrary）。
    func stop() -> RecordingItem? {
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        timer?.invalidate()
        state = .idle
        elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
        let title = Date.now.formatted(date: .abbreviated, time: .shortened)
        return RecordingItem(id: currentID, title: "錄音 \(title)",
                             fileName: "\(currentID.uuidString).m4a",
                             createdAt: .now, source: .recorded,
                             durationSeconds: duration)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }

    /// 來電等中斷：系統會暫停錄音；中斷結束時若系統允許就自動繼續。
    private func observeInterruptions() {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                guard let self, let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                switch type {
                case .began:
                    if self.state == .recording { self.state = .paused }
                case .ended:
                    let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw ?? 0)
                    if opts.contains(.shouldResume) { self.resume() }
                @unknown default: break
                }
            }
        }
    }

    enum RecorderError: LocalizedError {
        case failedToStart
        var errorDescription: String? { "錄音器無法啟動" }
    }
}
