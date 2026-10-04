import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 何時自動重送轉錄請求。
/// 原則：只有確定伺服器沒有處理（因此不會計費）時才重送，避免同一段錄音被收兩次費。
enum UploadRetry {
    static let maxAttempts = 3

    /// 第 n 次失敗後等多久再試（2 秒、8 秒）
    static func delay(afterAttempt n: Int) -> Duration { .seconds(n <= 1 ? 2 : 8) }

    static let transientURLErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff,
        .callIsActive, .dataNotAllowed,
    ]

    static func shouldRetry(_ error: Error, bodyFullySent: Bool) -> Bool {
        switch error {
        case ProviderError.http(let code, _):
            // 429 過於頻繁、503 暫停服務：請求被拒絕，沒有處理
            return code == 429 || code == 503
        case let e as URLError:
            // 音檔還沒送完就斷線：伺服器拿不到完整檔案，不會轉錄
            return !bodyFullySent && transientURLErrors.contains(e.code)
        default:
            return false
        }
    }

    /// 放棄重送時回報的錯誤：上傳完才斷線要特別說明可能已計費
    static func finalError(_ error: Error, bodyFullySent: Bool) -> Error {
        if bodyFullySent, let e = error as? URLError, e.code != .cancelled {
            return ProviderError.interruptedAfterUpload(e.localizedDescription)
        }
        return error
    }
}

/// 接收上傳進度並依序轉給畫面；同時記錄音檔是否已全部送出（決定能否重送）。
final class UploadObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State { var lastPercent = -1; var sentAll = false }
    private let state = Mutex(State())
    private let continuation: AsyncStream<TranscriptionProgress>.Continuation
    private let consumer: Task<Void, Never>

    init(onProgress: TranscriptionProgressHandler?) {
        let (stream, continuation) = AsyncStream<TranscriptionProgress>.makeStream()
        self.continuation = continuation
        // 用單一 Task 依序送出，進度不會因為多個 Task 搶先後而倒退
        consumer = Task {
            for await p in stream { await onProgress?(p) }
        }
    }

    var bodyFullySent: Bool { state.withLock { $0.sentAll } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        record(sent: totalBytesSent, total: totalBytesExpectedToSend)
    }

    /// 每多 1% 才更新一次；送完時改報「伺服器轉錄中」
    func record(sent: Int64, total: Int64) {
        guard total > 0 else { return }
        let fraction = min(1, Double(sent) / Double(total))
        let percent = Int(fraction * 100)
        let (emit, done) = state.withLock { s -> (Bool, Bool) in
            guard !s.sentAll else { return (false, false) }
            let done = sent >= total
            let emit = percent > s.lastPercent
            if emit { s.lastPercent = percent }
            if done { s.sentAll = true }
            return (emit, done)
        }
        if emit { continuation.yield(.uploading(fraction)) }
        if done { continuation.yield(.processing) }
    }

    /// 結束並等所有進度都送到畫面
    func finish() async {
        continuation.finish()
        await consumer.value
    }
}
