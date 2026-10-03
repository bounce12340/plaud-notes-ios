import XCTest
@testable import PlaudNotes

/// 記錄收到的訊息並依序回覆的假 LLM。
final class MockLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[ChatMessage]] = []
    var calls: [[ChatMessage]] { lock.withLock { _calls } }

    func complete(_ messages: [ChatMessage]) async throws -> String {
        let n = lock.withLock { _calls.append(messages); return _calls.count }
        return "回覆\(n)"
    }
}

final class LLMTests: XCTestCase {
    // MARK: - 請求格式

    func testOpenAIRequest() throws {
        let c = OpenAICompatibleClient(baseURL: URL(string: "https://api.deepseek.com/")!,
                                       model: "deepseek-flash", apiKey: "sk-test")
        let r = try c.makeRequest([ChatMessage(role: .system, content: "S"), ChatMessage(role: .user, content: "U")])
        XCTAssertEqual(r.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"]! }, ["system", "user"])
    }

    func testOpenAIRequestWithoutKeyHasNoAuthHeader() throws {
        let c = OpenAICompatibleClient(baseURL: URL(string: "http://mac-mini.local:11434/v1")!,
                                       model: "gpt-oss:20b", apiKey: nil)
        let r = try c.makeRequest([ChatMessage(role: .user, content: "hi")])
        XCTAssertEqual(r.url?.absoluteString, "http://mac-mini.local:11434/v1/chat/completions")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicRequestMovesSystemPrompt() throws {
        let c = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, model: "m", apiKey: "k")
        let r = try c.makeRequest([ChatMessage(role: .system, content: "S1"),
                                   ChatMessage(role: .system, content: "S2"),
                                   ChatMessage(role: .user, content: "U")])
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "S1\n\nS2")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.count, 1)
        XCTAssertNotNil(body["max_tokens"])
    }

    // MARK: - 回應解析

    func testParseOpenAIResponse() throws {
        // 注意：原始字串 #"…"# 內不可出現 `"#`，所以內容不用 Markdown 標題符號
        let json = #"{"choices":[{"message":{"role":"assistant","content":"- 筆記","reasoning_content":"思考"}}]}"#
        XCTAssertEqual(try OpenAICompatibleClient.parse(Data(json.utf8)), "- 筆記")
        XCTAssertThrowsError(try OpenAICompatibleClient.parse(Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)))
        XCTAssertThrowsError(try OpenAICompatibleClient.parse(Data("not json".utf8)))
    }

    func testParseAnthropicResponse() throws {
        let json = #"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#
        XCTAssertEqual(try AnthropicClient.parse(Data(json.utf8)), "AB")
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(LLMHTTP.errorMessage(Data(#"{"error":{"message":"Invalid key"}}"#.utf8)), "Invalid key")
        XCTAssertEqual(LLMHTTP.errorMessage(Data(String(repeating: "x", count: 500).utf8)).count, 300)
    }

    // MARK: - 設定檢查

    func testFactoryValidation() {
        var c = LLMConfig(preset: LLMPreset.find("deepseek")!)
        XCTAssertThrowsError(try LLMClientFactory.make(config: c, apiKey: nil)) {
            XCTAssertEqual($0 as? LLMError, .notConfigured("API key"))
        }
        XCTAssertNoThrow(try LLMClientFactory.make(config: c, apiKey: "sk"))
        c.model = " "
        XCTAssertThrowsError(try LLMClientFactory.make(config: c, apiKey: "sk"))
        c = LLMConfig(preset: LLMPreset.find("custom")!)
        c.model = "m"
        XCTAssertThrowsError(try LLMClientFactory.make(config: c, apiKey: nil)) {
            XCTAssertEqual($0 as? LLMError, .notConfigured("服務網址"))
        }
        c.baseURL = "http://192.168.1.10:11434/v1"
        XCTAssertNoThrow(try LLMClientFactory.make(config: c, apiKey: nil))
    }

    // MARK: - 範本與分段

    func testTemplateRender() {
        let t = NoteTemplate(id: UUID(), name: "x", prompt: "{{title}}/{{date}}/{{speakers}}/{{unknown}}", isBuiltIn: false)
        XCTAssertEqual(t.render(["title": "週會", "date": "2026-09-30", "speakers": "A、B"]),
                       "週會/2026-09-30/A、B/{{unknown}}")
    }

    func testChunkKeepsLinesAndLimit() {
        let lines = (0..<50).map { "[00:00:\(String(format: "%02d", $0))] speaker_0：" + String(repeating: "字", count: 30) }
        let chunks = NoteGenerator.chunk(lines, limit: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 500 })
        XCTAssertEqual(chunks.joined(separator: "\n"), lines.joined(separator: "\n"))
        // 單行超過上限時硬切
        let long = NoteGenerator.chunk([String(repeating: "a", count: 1_250)], limit: 500)
        XCTAssertEqual(long.map(\.count), [500, 500, 250])
    }

    func testGenerateSingleCall() async throws {
        let llm = MockLLM()
        let gen = NoteGenerator(client: llm, maxInputCharacters: 10_000)
        let r = try await gen.generate(Self.request(segments: 3))
        XCTAssertEqual(r.chunkCount, 1)
        XCTAssertEqual(r.markdown, "回覆1")
        XCTAssertEqual(llm.calls.count, 1)
        let user = llm.calls[0][1].content
        XCTAssertTrue(user.contains("[00:00:00] 王經理：內容0"))
        XCTAssertTrue(user.contains("與會者：王經理、speaker_1"))
        XCTAssertTrue(user.contains("輸出語言：繁體中文（台灣）"))
        XCTAssertTrue(user.contains("專有名詞（正確寫法）：Etihad、C2 Pharma"))
        XCTAssertFalse(user.contains("{{"))
        XCTAssertEqual(llm.calls[0][0].role, .system)
        // 系統指示必須禁止推測負責人與補年份
        XCTAssertTrue(llm.calls[0][0].content.contains("不可推測某個代號是哪一位與會者"))
        XCTAssertTrue(llm.calls[0][0].content.contains("原話沒有年份就不要補年份"))
    }

    func testGenerateMapReduce() async throws {
        let llm = MockLLM()
        let gen = NoteGenerator(client: llm, maxInputCharacters: 2_000)
        let r = try await gen.generate(Self.request(segments: 120))
        XCTAssertGreaterThan(r.chunkCount, 1)
        XCTAssertEqual(llm.calls.count, r.chunkCount + 1)
        let final = llm.calls.last![1].content
        XCTAssertTrue(final.contains("### 第 1 段重點"))
        XCTAssertTrue(final.contains("### 第 \(r.chunkCount) 段重點"))
        // 分段抽重點時也要帶詞庫
        XCTAssertTrue(llm.calls[0][1].content.contains("專有名詞（正確寫法）：Etihad、C2 Pharma"))
    }

    private static func request(segments n: Int) -> NoteGenerator.Request {
        let padding = String(repeating: "。", count: 40)
        var segs: [TranscriptSegment] = []
        for i in 0..<n {
            let start = Double(i) * 10
            let speaker: String = i % 2 == 0 ? "speaker_0" : "speaker_1"
            let text: String = "內容\(i)" + padding
            segs.append(TranscriptSegment(start: start, end: start + 9, speaker: speaker, text: text))
        }
        var transcript = Transcript(languageCode: "zho", segments: segs, engine: "test")
        transcript.speakerNames = ["speaker_0": "王經理", "speaker_1": "  "]
        return .init(title: "週會", date: Date(timeIntervalSince1970: 1_790_000_000),
                     transcript: transcript,
                     template: NoteTemplate.builtIns[0], outputLanguage: NoteLanguage.zhTW.rawValue,
                     glossary: ["Etihad", "C2 Pharma"])
    }

    // MARK: - 串流

    /// DeepSeek deepseek-flash 實際串流回應（2026-10-03，問題為虛構的「介紹台北」；思考片段只保留前 3 個）
    private func deepseekStream() throws -> [String] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "deepseek_stream", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    func testOpenAIStreamParsing() throws {
        var reasoning = 0
        var content = ""
        var done = false
        for line in try deepseekStream() {
            guard let payload = SSE.payload(line) else { continue }
            switch try SSE.openAIDelta(payload) {
            case .delta(.reasoning): reasoning += 1
            case .delta(.content(let t)): XCTAssertFalse(done); content += t
            case .done: done = true
            case .ignore: break
            }
        }
        XCTAssertEqual(reasoning, 3)
        XCTAssertTrue(done)
        XCTAssertEqual(content, "台北是台灣的政治、經濟與文化中心，也是一座充滿活力的現代都市。這裡有台北101、故宮博物院、夜市小吃與便捷捷運，融合傳統底蘊與創新風貌，展現獨特的城市魅力。")
        XCTAssertNil(SSE.payload(": keep-alive"))
        XCTAssertThrowsError(try SSE.openAIDelta(#"{"error":{"message":"rate limited"}}"#))
    }

    func testAnthropicStreamParsing() throws {
        // 依 Anthropic Messages API 串流文件的事件格式（未實際呼叫）
        let events = [
            #"{"type":"message_start","message":{"id":"m"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"想"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"好"}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"message_stop"}"#,
        ]
        let parsed = try events.map(SSE.anthropicDelta)
        XCTAssertEqual(parsed, [.ignore, .ignore, .delta(.reasoning("想")), .delta(.content("你")),
                                .delta(.content("好")), .ignore, .done])
        XCTAssertThrowsError(try SSE.anthropicDelta(#"{"type":"error","error":{"message":"overloaded"}}"#))
    }

    func testStreamRequestBodies() throws {
        let o = OpenAICompatibleClient(baseURL: URL(string: "https://api.deepseek.com")!, model: "m", apiKey: "k")
        let ob = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(o.makeRequest([], stream: true).httpBody)) as? [String: Any])
        XCTAssertEqual(ob["stream"] as? Bool, true)
        let a = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, model: "m", apiKey: "k")
        let ab = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(a.makeRequest([], stream: true).httpBody)) as? [String: Any])
        XCTAssertEqual(ab["stream"] as? Bool, true)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(a.makeRequest([]).httpBody)) as? [String: Any])
        XCTAssertNil(plain["stream"], "不串流時不送 stream 欄位")
        XCTAssertEqual(ab["max_tokens"] as? Int, 64_000)
        XCTAssertEqual(plain["max_tokens"] as? Int, 16_000)
    }

    @MainActor
    func testGeneratorStreamsFinalNotes() async throws {
        let llm = StreamingMockLLM(pieces: [.reasoning("思考"), .content("## 標題\n"), .content("內容")])
        var events: [NoteGenerator.Progress] = []
        let result = try await NoteGenerator(client: llm, maxInputCharacters: 100_000)
            .generate(Self.request(segments: 3)) { events.append($0) }
        XCTAssertEqual(result.markdown, "## 標題\n內容")
        XCTAssertEqual(events.first, .thinking(characters: 2))
        XCTAssertEqual(events.last, .writing("## 標題\n內容"))
        XCTAssertFalse(events.contains(.writing("思考")), "思考內容不可出現在筆記")
    }

    @MainActor
    func testGeneratorReportsMapProgress() async throws {
        let llm = StreamingMockLLM(pieces: [.content("合併結果")])
        var events: [NoteGenerator.Progress] = []
        let result = try await NoteGenerator(client: llm, maxInputCharacters: 2_000)
            .generate(Self.request(segments: 120)) { events.append($0) }
        XCTAssertGreaterThan(result.chunkCount, 1)
        let summarizing = events.compactMap { e -> Int? in
            if case .summarizing(let done, _) = e { return done } else { return nil }
        }
        XCTAssertEqual(summarizing, Array(0...result.chunkCount))
        XCTAssertEqual(events.last, .writing("合併結果"))
    }

    @MainActor
    func testStreamFailureBeforeContentFallsBackToComplete() async throws {
        // 例如供應商不支援串流（HTTP 400）或事件格式不符
        let llm = StreamingMockLLM(pieces: [.reasoning("想")], streamError: LLMError.http(400, "stream not supported"),
                                   completeReply: "## 一次性結果")
        var last: NoteGenerator.Progress?
        let result = try await NoteGenerator(client: llm, maxInputCharacters: 100_000)
            .generate(Self.request(segments: 3)) { last = $0 }
        XCTAssertEqual(result.markdown, "## 一次性結果")
        XCTAssertEqual(llm.completeCalls, 1)
        XCTAssertEqual(last, .writing("## 一次性結果"))
    }

    @MainActor
    func testStreamEndingWithoutContentFallsBackToComplete() async throws {
        let llm = StreamingMockLLM(pieces: [], completeReply: "## 一次性結果")
        let result = try await NoteGenerator(client: llm, maxInputCharacters: 100_000)
            .generate(Self.request(segments: 3)) { _ in }
        XCTAssertEqual(result.markdown, "## 一次性結果")
        XCTAssertEqual(llm.completeCalls, 1)
    }

    func testStreamFailureAfterContentIsReported() async {
        let llm = StreamingMockLLM(pieces: [.content("寫到一半")], streamError: LLMError.http(0, "連線中斷"))
        do {
            _ = try await NoteGenerator(client: llm, maxInputCharacters: 100_000).generate(Self.request(segments: 3)) { _ in }
            XCTFail("已收到部分內容後失敗，應回報錯誤而不是重送")
        } catch {
            XCTAssertEqual(error as? LLMError, .http(0, "連線中斷"))
            XCTAssertEqual(llm.completeCalls, 0)
        }
    }

    func testGeneratorEmptyStreamThrows() async {
        let llm = StreamingMockLLM(pieces: [.reasoning("只有思考")])
        do {
            _ = try await NoteGenerator(client: llm, maxInputCharacters: 100_000).generate(Self.request(segments: 3)) { _ in }
            XCTFail("應丟出 emptyResponse")
        } catch {
            XCTAssertEqual(error as? LLMError, .emptyResponse)
        }
    }

}

/// 依序串流固定片段的假 LLM；可在送出片段後丟出錯誤。complete() 回傳 completeReply 或正文合併結果。
final class StreamingMockLLM: LLMClient, @unchecked Sendable {
    let pieces: [LLMDelta]
    let streamError: Error?
    let completeReply: String?
    private let lock = NSLock()
    private var _completeCalls = 0
    var completeCalls: Int { lock.withLock { _completeCalls } }

    init(pieces: [LLMDelta], streamError: Error? = nil, completeReply: String? = nil) {
        self.pieces = pieces
        self.streamError = streamError
        self.completeReply = completeReply
    }

    func complete(_ messages: [ChatMessage]) async throws -> String {
        lock.withLock { _completeCalls += 1 }
        let text = completeReply ?? pieces.compactMap { if case .content(let t) = $0 { t } else { nil } }.joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { c in
            for p in pieces { c.yield(p) }
            c.finish(throwing: streamError)
        }
    }
}
