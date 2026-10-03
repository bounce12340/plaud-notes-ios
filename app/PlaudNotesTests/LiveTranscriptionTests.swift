import XCTest
@testable import PlaudNotes

/// 真的呼叫 ElevenLabs 轉錄（用 App 的 ElevenLabsProvider）。
/// 只有環境變數 ELEVENLABS_API_KEY 存在時才執行；CI 只在手動觸發且勾選 live_llm 時提供金鑰。
/// 音檔是 espeak-ng 合成的英文語音（Fixtures/speech_sample.mp3，約 7 秒），不含任何真實錄音。
final class LiveTranscriptionTests: XCTestCase {
    func testElevenLabsTranscribesSyntheticSpeech() async throws {
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw XCTSkip("未提供 ELEVENLABS_API_KEY，略過實際呼叫") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "speech_sample", withExtension: "mp3"))

        // keyterms 以表單欄位送出（含詞庫時 ElevenLabs 另收 20%），順便確認請求格式被接受
        let t = try await ElevenLabsProvider(apiKey: key)
            .transcribe(fileURL: url, options: TranscriptionOptions(languageCode: nil, keyterms: ["Plaud"]))
        let text = t.plainText.lowercased()
        print("LIVE[elevenlabs] language=\(t.languageCode ?? "?") segments=\(t.segments.count) text=\(t.plainText)")
        XCTAssertTrue(t.languageCode?.hasPrefix("en") ?? false, "應偵測為英文：\(t.languageCode ?? "nil")")
        XCTAssertTrue(text.contains("budget"), text)
        XCTAssertTrue(text.contains("friday"), text)
        XCTAssertFalse(t.segments.isEmpty)
        XCTAssertLessThan(t.segments.last?.end ?? 99, 10, "時間戳應在音檔長度內")
    }
}
