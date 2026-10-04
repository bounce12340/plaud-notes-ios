import Foundation

/// 轉錄結果的共同格式（所有引擎都轉成這個）。
struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var speaker: String?
    var text: String
}

struct Transcript: Codable, Sendable {
    var languageCode: String?
    var segments: [TranscriptSegment]
    var engine: String
    /// 套用過的後處理，例如 `opencc-s2tw`；nil 表示引擎原始輸出
    var postProcessing: String? = nil
    /// 使用者設定的說話者名稱（speaker_0 → 王經理）。Optional 是為了能讀取舊版存檔。
    var speakerNames: [String: String]? = nil

    var plainText: String { segments.map(\.text).joined() }

    /// 說話者顯示名稱；沒設定就回傳原始代號
    func displayName(_ speaker: String?) -> String? {
        guard let speaker else { return nil }
        let name = speakerNames?[speaker]?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? speaker : name
    }

    /// 出現過的說話者（依第一次出現順序）
    var speakers: [String] {
        var seen: [String] = []
        for s in segments { if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) } }
        return seen
    }
}

struct TranscriptionOptions: Sendable {
    var languageCode: String?      // nil = 自動偵測
    var diarize = true
    var maxSpeakers: Int?
    /// 專有名詞（詞庫），讓轉錄引擎優先辨識
    var keyterms: [String] = []
}

/// 轉錄進度（給畫面顯示）
enum TranscriptionProgress: Sendable, Equatable {
    /// 上傳前壓縮音檔，0...1
    case compacting(Double)
    /// 上傳中，0...1
    case uploading(Double)
    /// 已上傳完畢，等伺服器轉錄
    case processing
    /// 連線失敗，第 attempt 次嘗試（共 of 次）
    case retrying(attempt: Int, of: Int)
}

extension TranscriptionProgress {
    /// 畫面上的狀態文字
    var label: String {
        switch self {
        case .compacting(let f): "壓縮音檔中（\(Int(f * 100))%）…"
        case .uploading(let f): "上傳中（\(Int(f * 100))%）…"
        case .processing: "伺服器轉錄中…"
        case .retrying(let attempt, let total): "暫時失敗，重試中（第 \(attempt)/\(total) 次）…"
        }
    }
}

typealias TranscriptionProgressHandler = @MainActor @Sendable (TranscriptionProgress) -> Void

/// 轉錄引擎抽象：本機（WhisperKit / FluidAudio / SpeechAnalyzer）與雲端（ElevenLabs…）都實作它。
protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var isOnDevice: Bool { get }
    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    onProgress: TranscriptionProgressHandler?) async throws -> Transcript
}

extension TranscriptionProvider {
    func transcribe(fileURL: URL, options: TranscriptionOptions) async throws -> Transcript {
        try await transcribe(fileURL: fileURL, options: options, onProgress: nil)
    }
}
