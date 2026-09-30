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
}
