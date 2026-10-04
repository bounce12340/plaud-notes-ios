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

    /// iPhone 編碼器壓出的 16 kHz 單聲道 AAC 要能被 ElevenLabs 接受，內容不變；同時走從暫存檔上傳的流程
    func testElevenLabsTranscribesCompactedAudio() async throws {
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw XCTSkip("未提供 ELEVENLABS_API_KEY，略過實際呼叫") }
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "speech_sample", withExtension: "mp3"))
        let dst = FileManager.default.temporaryDirectory.appending(path: "live-compact-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: dst) }
        let bitRate = try await AudioCompactor.compact(src, to: dst, duration: 7)

        let log = LiveProgressLog()
        let t = try await ElevenLabsProvider(apiKey: key)
            .transcribe(fileURL: dst, options: TranscriptionOptions(), onProgress: { log.add($0) })
        let text = t.plainText.lowercased()
        let progress = await log.items
        print("LIVE[elevenlabs-compact] bitRate=\(bitRate) progress=\(progress.map(\.label)) text=\(t.plainText)")
        XCTAssertTrue(text.contains("budget"), text)
        XCTAssertTrue(text.contains("friday"), text)
        XCTAssertEqual(progress.last, .processing)
    }
}

extension LiveTranscriptionTests {
    /// 真正的背景 URLSession（系統代管上傳）在模擬器上能完成請求、存下回應
    func testBackgroundSessionTranscribesSyntheticSpeech() async throws {
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw XCTSkip("未提供 ELEVENLABS_API_KEY，略過實際呼叫") }
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "speech_sample", withExtension: "mp3"))
        let root = FileManager.default.temporaryDirectory.appending(path: "live-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let config = URLSessionConfiguration.background(withIdentifier: "live-test-\(UUID().uuidString)")
        config.isDiscretionary = false
        let transcriber = BackgroundTranscriber(configuration: config, store: TranscriptionJobStore(root: root))
        defer { transcriber.invalidate() }
        let log = TranscriberEventLog()
        transcriber.setEventHandler { log.append($0) }

        let id = UUID()
        try await transcriber.start(recordingID: id, audioURL: audio, provider: ElevenLabsProvider(apiKey: key),
                                    options: TranscriptionOptions())
        let final = try await log.waitForFinal(id, timeout: .seconds(180))
        print("LIVE[elevenlabs-background] final=\(final) events=\(log.events.count)")
        XCTAssertEqual(final, .finished(id))
        let t = try ElevenLabsProvider.parse(Data(contentsOf: transcriber.store.responseURL(id)))
        XCTAssertTrue(t.plainText.lowercased().contains("budget"), t.plainText)
    }
}

@MainActor
private final class LiveProgressLog {
    private(set) var items: [TranscriptionProgress] = []
    func add(_ p: TranscriptionProgress) { items.append(p) }
}
