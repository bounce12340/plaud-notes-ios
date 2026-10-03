import XCTest
@testable import PlaudNotes

/// 真的呼叫 DeepSeek（用 App 的 Swift LLM 客戶端與 NoteGenerator）。
/// 只有環境變數 DEEPSEEK_API_KEY 存在時才執行，否則略過；CI 只在手動觸發且勾選 live_llm 時提供金鑰。
/// 逐字稿是虛構內容，不含任何真實錄音。
final class LiveLLMTests: XCTestCase {
    private var apiKey: String? {
        let k = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return k.isEmpty ? nil : k
    }

    private func client() throws -> LLMClient {
        guard let key = apiKey else { throw XCTSkip("未提供 DEEPSEEK_API_KEY，略過實際呼叫") }
        let config = LLMConfig(preset: try XCTUnwrap(LLMPreset.find("deepseek")))
        return try LLMClientFactory.make(config: config, apiKey: key)
    }

    func testConnection() async throws {
        let c = try client()
        let reply = try await c.complete([ChatMessage(role: .user, content: "請只回覆 OK")])
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("LIVE connection reply: \(reply.prefix(40))")
    }

    func testMeetingNotesSingleCall() async throws {
        let c = try client()
        let gen = NoteGenerator(client: c, maxInputCharacters: 300_000)
        let result = try await gen.generate(Self.request())
        try check(result, label: "single")
        XCTAssertEqual(result.chunkCount, 1)
    }

    func testMeetingNotesMapReduce() async throws {
        let c = try client()
        let gen = NoteGenerator(client: c, maxInputCharacters: 2_000)
        let result = try await gen.generate(Self.request())
        try check(result, label: "mapreduce")
        XCTAssertGreaterThan(result.chunkCount, 1)
    }

    @MainActor
    func testStreamingNotes() async throws {
        let c = try client()
        let gen = NoteGenerator(client: c, maxInputCharacters: 300_000)
        var updates = 0
        var sawThinking = false
        var lastText = ""
        let result = try await gen.generate(Self.request()) { p in
            switch p {
            case .thinking: sawThinking = true
            case .writing(let t): updates += 1; lastText = t
            case .summarizing: break
            }
        }
        try check(result, label: "stream")
        XCTAssertGreaterThan(updates, 1, "串流應分多次更新畫面")
        XCTAssertEqual(lastText, result.markdown)
        print("LIVE[stream] updates=\(updates) thinking=\(sawThinking)")
    }

    // MARK: - Ollama Cloud

    /// CI 只在手動觸發且勾選 live_llm 時，從 repo secret OLLAMA_API_KEY 提供
    private func ollamaClient() throws -> LLMClient {
        let k = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !k.isEmpty else { throw XCTSkip("未提供 OLLAMA_API_KEY，略過實際呼叫") }
        let config = LLMConfig(preset: try XCTUnwrap(LLMPreset.find("ollama-cloud")))
        return try LLMClientFactory.make(config: config, apiKey: k)
    }

    @MainActor
    func testOllamaCloudStreamingNotes() async throws {
        let c = try ollamaClient()
        var pieces = 0
        for try await d in c.stream([ChatMessage(role: .user, content: "用繁體中文寫三句話介紹台北。")]) {
            if case .content = d { pieces += 1 }
        }
        XCTAssertGreaterThan(pieces, 1, "Ollama Cloud 串流應分多個片段送達")

        let gen = NoteGenerator(client: c, maxInputCharacters: 60_000)
        var updates = 0
        var sawThinking = false
        var lastText = ""
        let result = try await gen.generate(Self.request()) { p in
            switch p {
            case .thinking: sawThinking = true
            case .writing(let t): updates += 1; lastText = t
            case .summarizing: break
            }
        }
        try check(result, label: "ollama-stream")
        XCTAssertEqual(lastText, result.markdown)
        print("LIVE[ollama-stream] pieces=\(pieces) updates=\(updates) thinking=\(sawThinking)")
    }

    // MARK: - Anthropic（Claude）

    /// CI 只在手動觸發且勾選 live_llm 時，從 repo secret ANTHROPIC_API_KEY 提供
    private func anthropicClient() throws -> LLMClient {
        let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !k.isEmpty else { throw XCTSkip("未提供 ANTHROPIC_API_KEY，略過實際呼叫") }
        var config = LLMConfig(preset: try XCTUnwrap(LLMPreset.find("anthropic")))
        config.model = "claude-opus-5-5"
        return try LLMClientFactory.make(config: config, apiKey: k)
    }

    func testAnthropicConnection() async throws {
        let reply = try await anthropicClient().complete([ChatMessage(role: .user, content: "請只回覆 OK")])
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("LIVE[anthropic] connection reply: \(reply.prefix(40))")
    }

    @MainActor
    func testAnthropicStreamingNotes() async throws {
        let c = try anthropicClient()
        // 直接看串流本身：要有多個正文片段，不是退回一次性呼叫
        var pieces = 0
        for try await d in c.stream([ChatMessage(role: .user, content: "用繁體中文寫三句話介紹台北。")]) {
            if case .content = d { pieces += 1 }
        }
        XCTAssertGreaterThan(pieces, 1, "Anthropic 串流應分多個片段送達")

        let gen = NoteGenerator(client: c, maxInputCharacters: 150_000)
        var updates = 0
        var lastText = ""
        let result = try await gen.generate(Self.request()) { p in
            if case .writing(let t) = p { updates += 1; lastText = t }
        }
        try check(result, label: "anthropic-stream")
        XCTAssertEqual(lastText, result.markdown)
        print("LIVE[anthropic-stream] pieces=\(pieces) updates=\(updates)")
    }

    // MARK: -

    private func check(_ result: NoteGenerator.Result, label: String) throws {
        var md = result.markdown
        if let conv = try? ChineseConverter(mode: .s2tw, bundle: Bundle(for: RecordingLibrary.self)) {
            md = conv.convertWithFixups(md)
        }
        XCTAssertTrue(md.contains("##"), "應依範本輸出 Markdown 標題")
        XCTAssertTrue(md.contains("決議"), "會議記錄範本應有「決議事項」")

        // 規則遵循情況只記錄、不判定失敗（LLM 輸出非決定性）
        let guessedName = md.contains("speaker_1（Kevin") || md.contains("speaker_1 (Kevin")
        let addedYear = md.range(of: #"20[0-9]{2}\s*年\s*10\s*月\s*5\s*日"#, options: .regularExpression) != nil
        let usedName = md.contains("林經理")
        let usedGlossary = md.contains("Zentrova")
        let usedRemark = md.contains("9 月 28 日") || md.contains("9月28日") || md.contains("2026-09-28")
        print("""
        LIVE[\(label)] chunks=\(result.chunkCount) chars=\(md.count) \
        guessedSpeakerName=\(guessedName) addedYear=\(addedYear) \
        usedSpeakerName=\(usedName) usedGlossary=\(usedGlossary) usedRemarkDate=\(usedRemark)
        <<<LIVE_NOTE_BEGIN \(label)>>>
        \(md)
        <<<LIVE_NOTE_END \(label)>>>
        """)
        XCTAssertTrue(usedName, "應使用使用者設定的說話者名稱")
    }

    /// 虛構的中英夾雜會議：speaker_0 已命名；speaker_1 被別人叫 Kevin，但沒有設定名稱；
    /// 「十月五日」沒有年份；Zentrova 在逐字稿被誤寫成 Zentrovah。
    static func request() -> NoteGenerator.Request {
        let lines: [(Double, String, String)] = [
            (0, "speaker_0", "好，我們開始今天的產品上市會議。今天要確認 Zentrovah 的包裝設計、上市時程跟行銷預算。"),
            (14, "speaker_1", "OK. For packaging, the vendor sent the third version of the artwork yesterday. We still need regulatory to confirm the label text."),
            (31, "speaker_0", "Kevin，法規那邊什麼時候可以回覆？"),
            (36, "speaker_1", "They said by next Friday. If there are no comments, we can send the final artwork to the printer."),
            (48, "speaker_2", "印刷廠需要三週交貨，所以最晚十月五日要把定稿送出去，不然趕不上上市。"),
            (63, "speaker_0", "好，那就決定十月五日前定稿。Kevin 負責追法規的回覆。"),
            (75, "speaker_2", "行銷預算的部分，第一季我們先抓八十萬，主要放在醫師研討會和線上廣告。"),
            (92, "speaker_1", "Do we have the split between the seminar and online ads?"),
            (98, "speaker_2", "研討會大概五十萬，線上三十萬，不過線上廣告的平台還沒決定。"),
            (112, "speaker_0", "平台下次再討論。預算八十萬先這樣定。另外上市記者會的日期還沒確定，請 speaker 二那邊提兩個日期給我。"),
            (130, "speaker_2", "好，我下週一前提供。"),
            (136, "speaker_0", "那今天就到這裡，謝謝大家。"),
        ]
        // 重複內容讓逐字稿超過 2,000 字，才能測到分段
        var segs: [TranscriptSegment] = []
        for round in 0..<3 {
            for (t, sp, text) in lines {
                let start = t + Double(round) * 150
                segs.append(TranscriptSegment(start: start, end: start + 10, speaker: sp,
                                              text: round == 0 ? text : "（重述）" + text))
            }
        }
        var transcript = Transcript(languageCode: "zho", segments: segs, engine: "synthetic")
        transcript.speakerNames = ["speaker_0": "林經理"]
        return .init(title: "Zentrova 上市會議（虛構測試資料）",
                     date: Date(timeIntervalSince1970: 1_790_000_000),
                     transcript: transcript,
                     template: NoteTemplate.builtIns[0],
                     outputLanguage: NoteLanguage.zhTW.rawValue,
                     glossary: ["Zentrova"],
                     remark: "實際開會時間是 2026 年 9 月 28 日下午，地點台北辦公室")
    }
}
