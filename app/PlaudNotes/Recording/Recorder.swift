import AVFoundation
import Observation
import UIKit

/// App 內建錄音（F11）。AAC 48 kHz 單聲道 64 kbps，存成 ADTS（.aac）。
///
/// - 背景：靠 UIBackgroundModes=audio，螢幕關閉、切到其他 App 時繼續錄。
/// - 中斷（來電、Siri、鬧鐘）：系統會暫停錄音；中斷結束後只要使用者沒有按暫停，就自動繼續，
///   不等系統的「可以恢復」提示（螢幕關著時沒人會去按繼續）。原本的錄音器無法繼續時開新的一段。
/// - 閃退：ADTS 寫到哪裡就能讀到哪裡；開始錄音時留下記錄檔，下次開 App 由 `RecordingRecovery` 救回。
/// 待實機驗證：3 小時連續錄音、來電中斷後恢復、鎖定畫面狀態。
@MainActor
@Observable
final class Recorder: NSObject {
    enum State: Equatable { case idle, recording, paused, interrupted }

    static let shared = Recorder()

    private(set) var state: State = .idle {
        didSet { if state != oldValue { syncActivity() } }
    }
    private(set) var elapsed: TimeInterval = 0
    var lastError: String?
    /// 中斷後狀態的說明，例如「通話中，結束後自動繼續」
    private(set) var notice: String?

    /// 錄音中（含暫停、中斷）的錄音 ID；救回時要跳過它
    var activeID: UUID? { session?.id }
    var startedAt: Date? { session?.startedAt }

    nonisolated static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
    }

    private var recorder: AVAudioRecorder?
    private var session: RecordingSession?
    private var directory: URL { RecordingLibrary.recordingsDirectory }
    /// 使用者自己按了暫停：中斷結束後不自動繼續
    private var userPaused = false
    /// 已錄的時間（不含暫停與中斷）
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var resumeTask: Task<Void, Never>?

    func start() async {
        guard state == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "沒有麥克風權限，請到「設定」開啟。"
            return
        }
        do {
            try configureAudioSession()
            session = RecordingSession(id: UUID(), startedAt: .now)
            accumulated = 0
            userPaused = false
            notice = nil
            try startNewPart()
            setRunning(true)
            if let startedAt = session?.startedAt { RecordingActivity.start(startedAt: startedAt) }
            state = .recording
            startTimer()
            observeAudioSession()
        } catch {
            if let id = session?.id { RecordingSessionStore.remove(id, in: directory) }
            session = nil
            recorder = nil
            lastError = "無法開始錄音：\(error.localizedDescription)"
        }
    }

    func pause() {
        guard state == .recording || state == .interrupted else { return }
        userPaused = true
        resumeTask?.cancel()
        recorder?.pause()
        setRunning(false)
        state = .paused
        notice = nil
    }

    func resume() {
        guard state == .paused || state == .interrupted else { return }
        userPaused = false
        if !continueRecording() {
            lastError = "無法繼續錄音，請再試一次。"
        }
    }

    /// 停止錄音。檔案的整理與加入清單由 `RecordingRecovery.recover` 處理：
    /// 裝置鎖定時（例如從鎖定畫面按停止）清單無法存檔，記錄檔會留著，解鎖後再加入。
    func stop() {
        guard var s = session else { return }
        resumeTask?.cancel()
        recorder?.stop()
        recorder = nil
        s.stopped = true
        try? RecordingSessionStore.save(s, in: directory)
        setRunning(false)
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        elapsed = 0
        notice = nil
        session = nil
        RecordingActivity.end()
    }

    // MARK: - 錄音器

    private func configureAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        // 通知提示音不要打斷錄音
        try? audio.setPrefersNoInterruptionsFromSystemAlerts(true)
        // 藍牙耳機斷線時不中斷，改用手機麥克風繼續
        try? audio.setPrefersInterruptionOnRouteDisconnect(false)
        try audio.setActive(true)
    }

    private func startNewPart() throws {
        guard var s = session else { return }
        let name = s.nextPartName()
        let r = try AVAudioRecorder(url: directory.appending(path: name), settings: Self.settings)
        guard r.record() else { throw RecorderError.failedToStart }
        recorder = r
        s.parts.append(name)
        session = s
        try RecordingSessionStore.save(s, in: directory)
    }

    /// 繼續錄音：先試原本的錄音器，不行就開新的一段（停止時接起來）
    private func continueRecording() -> Bool {
        try? AVAudioSession.sharedInstance().setActive(true)
        if recorder?.record() == true {
            setRunning(true)
            state = .recording
            notice = nil
            return true
        }
        recorder?.stop()
        recorder = nil
        do {
            try startNewPart()
            setRunning(true)
            state = .recording
            notice = nil
            return true
        } catch {
            return false
        }
    }

    /// 中斷結束後自動繼續；音訊工作階段可能還被占用（例如通話剛掛斷），每 2 秒重試，最多 1 分鐘
    private func autoResume() {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            for _ in 0..<30 {
                guard let self, !Task.isCancelled, !self.userPaused, self.state == .interrupted else { return }
                if self.continueRecording() { return }
                try? await Task.sleep(for: .seconds(2))
            }
            guard let self, self.state == .interrupted else { return }
            self.state = .paused
            self.notice = "中斷後無法自動繼續錄音，請按「繼續」。"
        }
    }

    // MARK: - 音訊工作階段事件

    private func observeAudioSession() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw) }
            },
            // 媒體服務重設：所有錄音器都失效，要重新設定再開新的一段
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMediaServicesReset() }
            },
        ]
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            guard state == .recording else { return }
            setRunning(false)
            state = .interrupted
            notice = "錄音被中斷（例如來電），結束後會自動繼續。"
        case .ended:
            // 不看 shouldResume：螢幕關著時沒人會按繼續，只要使用者沒暫停就自動繼續
            guard state == .interrupted, !userPaused else { return }
            autoResume()
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard session != nil else { return }
        recorder = nil
        try? configureAudioSession()
        guard !userPaused else { return }
        setRunning(false)
        state = .interrupted
        autoResume()
    }

    /// 鎖定畫面的即時動態跟著狀態更新（錄音中由系統自己走秒，不必每秒更新）
    private func syncActivity() {
        switch state {
        case .idle: break
        case .recording: RecordingActivity.update(.recording, elapsed: currentElapsed)
        case .paused: RecordingActivity.update(.paused, elapsed: currentElapsed)
        case .interrupted: RecordingActivity.update(.interrupted, elapsed: currentElapsed)
        }
    }

    // MARK: - 計時

    private func setRunning(_ running: Bool) {
        if running {
            if runningSince == nil { runningSince = .now }
        } else if let since = runningSince {
            accumulated += Date.now.timeIntervalSince(since)
            runningSince = nil
        }
        elapsed = currentElapsed
    }

    private var currentElapsed: TimeInterval {
        accumulated + (runningSince.map { Date.now.timeIntervalSince($0) } ?? 0)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.elapsed = self.currentElapsed } }
        }
    }

    enum RecorderError: LocalizedError {
        case failedToStart
        var errorDescription: String? { "錄音器無法啟動" }
    }
}

/// 把留下記錄檔的錄音整理好加入清單：正常停止的（`stopped`），以及 App 中途被終止的（標題註明「中斷後救回」）。
enum RecordingRecovery {
    /// 回傳加入清單的錄音數
    @MainActor
    @discardableResult
    static func recover(into library: RecordingLibrary, skipping active: UUID?) -> Int {
        // 裝置鎖定或清單沒讀到時不動：清單存不了檔，記錄檔要留到解鎖後
        guard UIApplication.shared.isProtectedDataAvailable, !library.needsReload else { return 0 }
        let dir = RecordingLibrary.recordingsDirectory
        var added = 0
        for session in RecordingSessionStore.pending(in: dir) where session.id != active {
            if library.item(id: session.id) != nil {
                RecordingSessionStore.remove(session.id, in: dir)
                continue
            }
            do {
                guard let result = try RecordingSessionStore.finalize(session, in: dir, keepMarker: true) else {
                    if session.stopped == true { library.lastError = "沒有錄到聲音。" }
                    continue
                }
                // 確定寫進清單才刪記錄檔
                if library.add(item(for: session, result: result, recovered: session.stopped != true)) {
                    RecordingSessionStore.remove(session.id, in: dir)
                    added += 1
                }
            } catch {
                library.lastError = "整理錄音檔失敗：\(error.localizedDescription)。下次開啟 App 會再試一次。"
            }
        }
        return added
    }

    static func item(for session: RecordingSession, result: RecordingSessionStore.Finalized,
                     recovered: Bool) -> RecordingItem {
        let title = "錄音 " + session.startedAt.formatted(date: .abbreviated, time: .shortened)
            + (recovered ? "（中斷後救回）" : "")
        return RecordingItem(id: session.id, title: title, fileName: result.fileName, createdAt: .now,
                             source: .recorded, durationSeconds: result.duration, recordedAt: session.startedAt)
    }
}
