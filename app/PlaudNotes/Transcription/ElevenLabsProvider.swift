import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ElevenLabs Scribe 轉錄（雲端，使用者自己的 API key）。
/// API：POST https://api.elevenlabs.io/v1/speech-to-text（2026-09-30 依官方文件）
///
/// 長音檔整檔上傳、不切段：官方上限 3 GB／10 小時，超過 8 分鐘的檔案伺服器會自己切段平行處理
/// （2026-10-04 查閱 Speech to Text capabilities 文件）。App 自己切段的話，每段的說話者代號會各自重新編號。
/// 請求本文先寫到暫存檔再從檔案上傳，不把整個音檔讀進記憶體。
struct ElevenLabsProvider: TranscriptionProvider {
    let id = "elevenlabs"
    let isOnDevice = false
    var model = "scribe_v2"
    let apiKey: String
    var session: URLSession = .shared
    var endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    var retryDelay: @Sendable (Int) -> Duration = UploadRetry.delay(afterAttempt:)

    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    onProgress: TranscriptionProgressHandler?) async throws -> Transcript {
        let boundary = UUID().uuidString
        let bodyURL = FileManager.default.temporaryDirectory
            .appending(path: "elevenlabs-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Multipart.writeBody(to: bodyURL, boundary: boundary,
                                fields: Self.formFields(model: model, options: options),
                                fileField: "file", fileURL: fileURL)
        let request = makeRequest(boundary: boundary)

        var attempt = 1
        while true {
            let observer = UploadObserver(onProgress: onProgress)
            do {
                let (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: observer)
                await observer.finish()
                guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
                guard (200..<300).contains(http.statusCode) else {
                    throw ProviderError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
                }
                return try Self.parse(data)
            } catch {
                await observer.finish()
                let sent = observer.bodyFullySent
                guard attempt < UploadRetry.maxAttempts, UploadRetry.shouldRetry(error, bodyFullySent: sent) else {
                    throw UploadRetry.finalError(error, bodyFullySent: sent)
                }
                attempt += 1
                await onProgress?(.retrying(attempt: attempt, of: UploadRetry.maxAttempts))
                try await Task.sleep(for: retryDelay(attempt - 1))
            }
        }
    }

    /// 表單欄位。`keyterms` 每個詞各送一個欄位（2026-09-30 實測：送 JSON 陣列會回 400）。
    static func formFields(model: String, options: TranscriptionOptions) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model_id", model),
            ("diarize", options.diarize ? "true" : "false"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
        ]
        if let lang = options.languageCode { fields.append(("language_code", lang)) }
        if let n = options.maxSpeakers { fields.append(("num_speakers", String(n))) }
        for term in Glossary.keyterms(from: options.keyterms) { fields.append(("keyterms", term)) }
        return fields
    }

    func makeRequest(boundary: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // 閒置逾時：上傳完後伺服器處理期間不會送任何資料（3 小時錄音約數分鐘）
        request.timeoutInterval = 3600
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - 回應解析（字詞 → 依說話者與句子合併成段落）

    private struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let type: String?
            let speaker_id: String?
        }
        let language_code: String?
        let text: String?
        let words: [Word]?
    }

    /// 同一人講太久也要切段，否則筆記的時間戳只剩段落開頭。
    /// 樣本 C（2026-10-03，23 分鐘一人報告）：只依說話者合併時，前 12 分鐘成為 1 段，筆記時間戳幾乎都是 00:00:00。
    enum Split {
        /// 段落超過這個長度，遇到句尾標點就切
        static let sentenceSeconds = 20.0
        /// 再更長，遇到逗號、頓號也切
        static let clauseSeconds = 40.0
        /// 沒有標點時的硬上限
        static let maxSeconds = 60.0
        /// 停頓超過這個長度就切
        static let pauseSeconds = 2.0
        static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", ".", "…"]
        static let clauseEnders: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]
    }

    /// 下一個字詞要不要另起一段（同一位說話者時才會問）。
    static func shouldSplit(_ seg: TranscriptSegment, nextText: String, nextType: String?, nextStart: Double) -> Bool {
        // 空白與標點不當段落開頭，標點留在前一句
        guard nextType != "spacing",
              let first = nextText.trimmingCharacters(in: .whitespaces).first,
              !Split.sentenceEnders.contains(first), !Split.clauseEnders.contains(first) else { return false }
        if nextStart - seg.end >= Split.pauseSeconds { return true }
        let duration = seg.end - seg.start
        let lastChar = seg.text.trimmingCharacters(in: .whitespaces).last
        if duration >= Split.sentenceSeconds, let c = lastChar, Split.sentenceEnders.contains(c) { return true }
        if duration >= Split.clauseSeconds, let c = lastChar, Split.clauseEnders.contains(c) { return true }
        return duration >= Split.maxSeconds
    }

    static func parse(_ data: Data) throws -> Transcript {
        let r = try JSONDecoder().decode(Response.self, from: data)
        var segments: [TranscriptSegment] = []
        for w in r.words ?? [] where w.type != "audio_event" {
            let start = w.start ?? segments.last?.end ?? 0
            let end = w.end ?? start
            if var last = segments.last, last.speaker == w.speaker_id,
               !shouldSplit(last, nextText: w.text, nextType: w.type, nextStart: start) {
                last.text += w.text
                last.end = max(last.end, end)
                segments[segments.count - 1] = last
            } else {
                segments.append(TranscriptSegment(start: start, end: end,
                                                  speaker: w.speaker_id, text: w.text))
            }
        }
        if segments.isEmpty, let text = r.text {
            segments = [TranscriptSegment(start: 0, end: 0, speaker: nil, text: text)]
        }
        return Transcript(languageCode: r.language_code, segments: segments, engine: "elevenlabs")
    }
}

enum ProviderError: LocalizedError {
    case badResponse
    case http(Int, String)
    case missingAPIKey
    /// 音檔已全部送出，但等結果時連線中斷：伺服器可能已經轉錄並計費，所以不自動重送
    case interruptedAfterUpload(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: "伺服器回應格式錯誤"
        case .http(let code, let msg): "HTTP \(code)：\(msg)"
        case .missingAPIKey: "尚未設定 API key"
        case .interruptedAfterUpload(let msg):
            "音檔已上傳完畢，但等待轉錄結果時連線中斷（\(msg)）。伺服器可能已處理並計費，因此沒有自動重送；請確認網路後再按一次轉錄。"
        }
    }
}

enum Multipart {
    /// 把 multipart 本文寫到 `destination`，音檔以 1 MB 為單位複製，不整個讀進記憶體。回傳本文大小。
    @discardableResult
    static func writeBody(to destination: URL, boundary: String, fields: [(String, String)],
                          fileField: String, fileURL: URL, chunkSize: Int = 1 << 20) throws -> Int64 {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        var head = ""
        for (k, v) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        let name = fileURL.lastPathComponent
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return Int64(try out.offset())
    }
}
