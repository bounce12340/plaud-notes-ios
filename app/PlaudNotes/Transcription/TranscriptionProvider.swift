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

    var plainText: String { segments.map(\.text).joined() }
}

struct TranscriptionOptions: Sendable {
    var languageCode: String?      // nil = 自動偵測
    var diarize = true
    var maxSpeakers: Int?
}

/// 轉錄引擎抽象：本機（WhisperKit / FluidAudio / SpeechAnalyzer）與雲端（ElevenLabs…）都實作它。
protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var isOnDevice: Bool { get }
    func transcribe(fileURL: URL, options: TranscriptionOptions) async throws -> Transcript
}
