import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 用系統的背景 URLSession 上傳音檔並等 ElevenLabs 的結果。
///
/// 上傳與等待由系統代管：螢幕關閉、App 被暫停或被系統終止都會繼續；完成後系統喚醒 App，
/// 由 `TranscriptionCoordinator` 在解鎖後整理成逐字稿。使用者從多工畫面滑掉 App 時，系統會取消上傳。
/// 背景 session 不支援 async/await 與 completion handler，只能用 delegate。
final class BackgroundTranscriber: NSObject, URLSessionDataDelegate, Sendable {
    enum Event: Sendable, Equatable {
        case progress(UUID, TranscriptionProgress)
        case finished(UUID)
        case failed(UUID, String)
    }

    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "PlaudNotes") + ".transcription"

    #if !canImport(FoundationNetworking)
    static let shared = BackgroundTranscriber(configuration: .backgroundTranscription,
                                              store: TranscriptionJobStore(root: TranscriptionJobStore.defaultRoot))
    #endif

    let store: TranscriptionJobStore
    private let retryDelay: @Sendable (Int) -> TimeInterval

    private struct State {
        var session: URLSession?
        var buffers: [Int: Data] = [:]
        var lastPercent: [Int: Int] = [:]
        var onEvent: (@Sendable (Event) -> Void)?
        var backgroundCompletion: (@MainActor @Sendable () -> Void)?
        /// 系統已送完事件、但 AppDelegate 還沒交來 completion handler（session 在 App 啟動時就建立了）
        var eventsFinishedEarly = false
    }
    private let state = Mutex(State())

    init(configuration: URLSessionConfiguration, store: TranscriptionJobStore,
         retryDelay: @escaping @Sendable (Int) -> TimeInterval = { UploadRetry.delay(afterAttempt: $0).timeInterval }) {
        self.store = store
        self.retryDelay = retryDelay
        super.init()
        // 用同一個 identifier 重建 session，系統就會把 App 不在時完成的工作交給這個 delegate
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        state.withLock { $0.session = session }
    }

    var session: URLSession { state.withLock { $0.session! } }

    /// 事件可能在任何執行緒送出；接收端自行切回主執行緒
    func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        state.withLock { $0.onEvent = handler }
    }

    /// AppDelegate 收到系統喚醒時交給這裡；所有事件送完後呼叫（若已送完就立刻呼叫）
    func setBackgroundCompletion(_ completion: @escaping @MainActor @Sendable () -> Void) {
        let callNow = state.withLock { s -> Bool in
            if s.eventsFinishedEarly {
                s.eventsFinishedEarly = false
                return true
            }
            s.backgroundCompletion = completion
            return false
        }
        if callNow { Task { @MainActor in completion() } }
    }

    // MARK: - 開始／取消

    /// 寫出上傳本文並開始上傳。同一段錄音的舊工作會先取消。
    func start(recordingID id: UUID, audioURL: URL, provider: ElevenLabsProvider,
               options: TranscriptionOptions) async throws {
        await cancel(recordingID: id)
        try store.prepare(id)
        let boundary = UUID().uuidString
        do {
            try Multipart.writeBody(to: store.bodyURL(id), boundary: boundary,
                                    fields: ElevenLabsProvider.formFields(model: provider.model, options: options),
                                    fileField: "file", fileURL: audioURL)
            try store.save(TranscriptionJob(recordingID: id, attempt: 1, status: .uploading, startedAt: .now))
        } catch {
            store.remove(id)
            throw error
        }
        let task = session.uploadTask(with: provider.makeRequest(boundary: boundary), fromFile: store.bodyURL(id))
        task.taskDescription = id.uuidString
        task.resume()
    }

    func cancel(recordingID id: UUID) async {
        // 先刪資料夾：之後收到的「已取消」不會被當成失敗
        store.remove(id)
        for task in await runningTasks() where task.taskDescription == id.uuidString {
            task.cancel()
        }
    }

    /// App 啟動時呼叫：上傳中卻已沒有對應工作的（例如在上傳途中更新 App），標成失敗
    func reconcile() async {
        let running = Set(await runningTasks().compactMap(\.taskDescription))
        for job in store.allJobs() where job.status == .uploading && !running.contains(job.recordingID.uuidString) {
            fail(job.recordingID, message: "上傳中斷，請重新轉錄。")
        }
    }

    private func runningTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { c in session.getAllTasks { c.resume(returning: $0) } }
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)), totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let percent = Int(fraction * 100)
        let emit = state.withLock { s -> Bool in
            guard percent > s.lastPercent[task.taskIdentifier, default: -1] else { return false }
            s.lastPercent[task.taskIdentifier] = percent
            return true
        }
        guard emit else { return }
        send(.progress(id, .uploading(fraction)))
        if totalBytesSent >= totalBytesExpectedToSend { send(.progress(id, .processing)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.buffers[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = state.withLock { s -> Data in
            s.lastPercent[task.taskIdentifier] = nil
            return s.buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        }
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
              let job = store.job(id) else { return }   // 已取消或已刪除的工作
        let outcome = Self.outcome(error: error, response: task.response, data: data)
        if case .success = outcome {
            do {
                try store.saveResponse(data, for: id)
                send(.finished(id))
            } catch {
                fail(id, message: "無法儲存轉錄結果：\(error.localizedDescription)")
            }
            return
        }
        guard case .failure(let err) = outcome else { return }
        let sent = task.countOfBytesExpectedToSend > 0 && task.countOfBytesSent >= task.countOfBytesExpectedToSend
        if job.attempt < UploadRetry.maxAttempts, UploadRetry.shouldRetry(err, bodyFullySent: sent),
           let request = task.originalRequest {
            do {
                try store.update(id) { $0.attempt += 1 }
                let retry = session.uploadTask(with: request, fromFile: store.bodyURL(id))
                retry.taskDescription = id.uuidString
                // 背景 session 才會照這個時間延後開始；App 可能已在背景，不能用 sleep 等待
                #if !canImport(FoundationNetworking)
                retry.earliestBeginDate = Date(timeIntervalSinceNow: retryDelay(job.attempt))
                #endif
                retry.resume()
                send(.progress(id, .retrying(attempt: job.attempt + 1, of: UploadRetry.maxAttempts)))
                return
            } catch {}
        }
        let final = UploadRetry.finalError(err, bodyFullySent: sent)
        let message = (final as? URLError)?.code == .cancelled
            ? "上傳被取消（可能是 App 被從多工畫面關閉）。請重新轉錄。"
            : final.localizedDescription
        fail(id, message: message)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = state.withLock { s -> (@MainActor @Sendable () -> Void)? in
            defer { s.backgroundCompletion = nil }
            if s.backgroundCompletion == nil { s.eventsFinishedEarly = true }
            return s.backgroundCompletion
        }
        guard let completion else { return }
        Task { @MainActor in completion() }
    }

    // MARK: - 共用

    enum Outcome { case success, failure(Error) }

    static func outcome(error: Error?, response: URLResponse?, data: Data) -> Outcome {
        if let error { return .failure(error) }
        guard let http = response as? HTTPURLResponse else { return .failure(ProviderError.badResponse) }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(ProviderError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self)))
        }
        return .success
    }

    private func fail(_ id: UUID, message: String) {
        store.markFailed(id, message: message)
        send(.failed(id, message))
    }

    private func send(_ event: Event) {
        state.withLock { $0.onEvent }?(event)
    }
}

extension URLSessionConfiguration {
    #if !canImport(FoundationNetworking)
    static var backgroundTranscription: URLSessionConfiguration {
        let c = URLSessionConfiguration.background(withIdentifier: BackgroundTranscriber.sessionIdentifier)
        c.sessionSendsLaunchEvents = true
        // 使用者按下轉錄就開始，不讓系統延到充電或 Wi-Fi 時才傳
        c.isDiscretionary = false
        // 3 小時錄音的伺服器處理約數分鐘；整體上限給 1 天
        c.timeoutIntervalForResource = 24 * 3600
        return c
    }
    #endif
}

extension Duration {
    var timeInterval: TimeInterval {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}
