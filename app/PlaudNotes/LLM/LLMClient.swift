import Foundation

// MARK: - 共用型別

struct ChatMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case system, user, assistant }
    var role: Role
    var content: String
}

protocol LLMClient: Sendable {
    /// 送出對話並回傳模型的文字回覆。
    func complete(_ messages: [ChatMessage]) async throws -> String
    /// 串流回覆：依序回傳模型的思考片段與正文片段。
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<LLMDelta, Error>
}

/// 串流收到的一個片段。DeepSeek 等推理模型會先送思考內容（不屬於回覆），再送正文。
enum LLMDelta: Sendable, Equatable {
    case reasoning(String)
    case content(String)
}

extension LLMClient {
    /// 不支援串流的客戶端：等完整回覆後一次回傳。
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.content(try await complete(messages)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum LLMAPIStyle: String, Codable, Sendable, CaseIterable {
    /// POST {base}/chat/completions（OpenAI、DeepSeek、Gemini、Groq、OpenRouter、Ollama…）
    case openAICompatible
    /// POST {base}/v1/messages（Anthropic）
    case anthropic
}

/// 使用者可選的供應商預設值。網址依各家官方文件；模型名稱會變動，除了已查證的項目外都留空讓使用者填。
struct LLMPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let style: LLMAPIStyle
    let baseURL: String
    let defaultModel: String
    let requiresKey: Bool
    /// 一次送出的逐字稿字數上限；超過就分段整理再合併
    let maxInputCharacters: Int
    let note: String

    static let all: [LLMPreset] = [
        LLMPreset(id: "deepseek", name: "DeepSeek", style: .openAICompatible,
                  baseURL: "https://api.deepseek.com", defaultModel: "deepseek-flash",
                  requiresKey: true, maxInputCharacters: 300_000,
                  note: "官方文件：deepseek-flash 支援 1M context（2026-09-30 查閱）。"),
        LLMPreset(id: "openai", name: "OpenAI", style: .openAICompatible,
                  baseURL: "https://api.openai.com/v1", defaultModel: "",
                  requiresKey: true, maxInputCharacters: 150_000,
                  note: "請填入要使用的模型名稱。"),
        LLMPreset(id: "anthropic", name: "Anthropic（Claude）", style: .anthropic,
                  baseURL: "https://api.anthropic.com", defaultModel: "",
                  requiresKey: true, maxInputCharacters: 150_000,
                  note: "請填入要使用的模型名稱。"),
        LLMPreset(id: "gemini", name: "Google Gemini", style: .openAICompatible,
                  baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "",
                  requiresKey: true, maxInputCharacters: 300_000,
                  note: "使用 Gemini 的 OpenAI 相容端點。"),
        LLMPreset(id: "groq", name: "Groq", style: .openAICompatible,
                  baseURL: "https://api.groq.com/openai/v1", defaultModel: "",
                  requiresKey: true, maxInputCharacters: 60_000,
                  note: "可選 gpt-oss 等開放模型；模型名稱以 Groq 文件為準。"),
        LLMPreset(id: "openrouter", name: "OpenRouter", style: .openAICompatible,
                  baseURL: "https://openrouter.ai/api/v1", defaultModel: "",
                  requiresKey: true, maxInputCharacters: 60_000,
                  note: "模型名稱格式如「供應商/模型」。"),
        LLMPreset(id: "ollama", name: "Ollama（自架 gpt-oss）", style: .openAICompatible,
                  baseURL: "http://mac-mini.local:11434/v1", defaultModel: "gpt-oss:20b",
                  requiresKey: false, maxInputCharacters: 40_000,
                  note: "Mac mini 上的 Ollama。iPhone 需在同一個網路，或用 Tailscale 連回；不要把連接埠直接開放到網際網路。"),
        LLMPreset(id: "custom", name: "其他（OpenAI 相容）", style: .openAICompatible,
                  baseURL: "", defaultModel: "",
                  requiresKey: false, maxInputCharacters: 40_000,
                  note: "任何支援 /chat/completions 的服務。"),
    ]

    static func find(_ id: String) -> LLMPreset? { all.first { $0.id == id } }
}

struct LLMConfig: Codable, Sendable, Equatable {
    var presetID: String
    var style: LLMAPIStyle
    var baseURL: String
    var model: String
    var maxInputCharacters: Int

    /// API key 在 Keychain 裡的帳號名稱（每個供應商各存一把）
    var keychainAccount: String { "llm.\(presetID)" }

    var host: String { URL(string: baseURL)?.host() ?? baseURL }

    init(preset: LLMPreset) {
        presetID = preset.id
        style = preset.style
        baseURL = preset.baseURL
        model = preset.defaultModel
        maxInputCharacters = preset.maxInputCharacters
    }

    static let `default` = LLMConfig(preset: LLMPreset.all[0])
}

enum LLMError: LocalizedError, Equatable {
    case notConfigured(String)
    case http(Int, String)
    case emptyResponse
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): "LLM 尚未設定：\(what)"
        case .http(let code, let msg): "LLM 服務回應 HTTP \(code)：\(msg)"
        case .emptyResponse: "LLM 沒有回傳內容"
        case .badResponse: "LLM 回應格式無法解析"
        }
    }
}

enum LLMClientFactory {
    static func make(config: LLMConfig, apiKey: String?, session: URLSession = .shared) throws -> LLMClient {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), url.scheme != nil, url.host() != nil else {
            throw LLMError.notConfigured("服務網址")
        }
        guard !config.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLMError.notConfigured("模型名稱")
        }
        let preset = LLMPreset.find(config.presetID)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset?.requiresKey ?? false, key?.isEmpty ?? true {
            throw LLMError.notConfigured("API key")
        }
        switch config.style {
        case .openAICompatible:
            return OpenAICompatibleClient(baseURL: url, model: config.model, apiKey: key, session: session)
        case .anthropic:
            return AnthropicClient(baseURL: url, model: config.model, apiKey: key ?? "", session: session)
        }
    }
}

// MARK: - OpenAI 相容

struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String?
    var session: URLSession = .shared

    func complete(_ messages: [ChatMessage]) async throws -> String {
        let request = try makeRequest(messages)
        let (data, response) = try await session.data(for: request)
        try LLMHTTP.check(response, data)
        return try Self.parse(data)
    }

    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<LLMDelta, Error> {
        LLMHTTP.sse(session: session, request: { try makeRequest(messages, stream: true) },
                    parse: SSE.openAIDelta)
    }

    func makeRequest(_ messages: [ChatMessage], stream: Bool = false) throws -> URLRequest {
        var r = URLRequest(url: LLMHTTP.join(baseURL, "chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // 只送必要欄位：不同供應商對 temperature / max_tokens 的支援不一致
        struct Body: Encodable { let model: String; let messages: [ChatMessage]; let stream: Bool }
        r.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, stream: stream))
        return r
    }

    static func parse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw LLMError.badResponse }
        guard let text = r.choices?.first?.message?.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }
}

// MARK: - Anthropic

struct AnthropicClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String
    /// 一次性呼叫的輸出上限。Claude 4.6 以後的模型預設會先思考，思考也算在 max_tokens 內，
    /// 8192 對長筆記不夠；官方建議非串流約 16000、串流約 64000（2026-10-04 依 Anthropic 文件）。
    var maxTokens = 16_000
    var streamingMaxTokens = 64_000
    var session: URLSession = .shared

    func complete(_ messages: [ChatMessage]) async throws -> String {
        let request = try makeRequest(messages)
        let (data, response) = try await session.data(for: request)
        try LLMHTTP.check(response, data)
        return try Self.parse(data)
    }

    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<LLMDelta, Error> {
        LLMHTTP.sse(session: session, request: { try makeRequest(messages, stream: true) },
                    parse: SSE.anthropicDelta)
    }

    func makeRequest(_ messages: [ChatMessage], stream: Bool = false) throws -> URLRequest {
        var r = URLRequest(url: LLMHTTP.join(baseURL, "v1/messages"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        struct Msg: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let system: String?
            let messages: [Msg]
            let stream: Bool?
        }
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let rest = messages.filter { $0.role != .system }.map { Msg(role: $0.role.rawValue, content: $0.content) }
        r.httpBody = try JSONEncoder().encode(Body(model: model, max_tokens: stream ? streamingMaxTokens : maxTokens,
                                                   system: system.isEmpty ? nil : system,
                                                   messages: rest, stream: stream ? true : nil))
        return r
    }

    static func parse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw LLMError.badResponse }
        let text = (r.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}

// MARK: - 共用 HTTP

enum LLMHTTP {
    static func join(_ base: URL, _ path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/" + path)!
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, errorMessage(data))
        }
    }

    /// 送出串流請求，逐行解析 Server-Sent Events。
    static func sse(session: URLSession, request: @escaping @Sendable () throws -> URLRequest,
                    parse: @escaping @Sendable (String) throws -> SSE.Event) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // Linux 的 Foundation 沒有 URLSession.bytes；App 只在 Apple 平台執行
                    throw LLMError.badResponse
                    #else
                    let (bytes, response) = try await session.bytes(for: try request())
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count >= 4096 { break }
                        }
                        throw LLMError.http(http.statusCode, errorMessage(data))
                    }
                    lines: for try await line in bytes.lines {
                        guard let payload = SSE.payload(line) else { continue }
                        switch try parse(payload) {
                        case .delta(let d): continuation.yield(d)
                        case .done: break lines
                        case .ignore: continue
                        }
                    }
                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 取出錯誤訊息（OpenAI／Anthropic 都用 {"error":{"message":…}}），最多 300 字，不回傳原始請求內容。
    static func errorMessage(_ data: Data) -> String {
        struct E: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        if let e = try? JSONDecoder().decode(E.self, from: data), let m = e.error?.message {
            return String(m.prefix(300))
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

// MARK: - Server-Sent Events 解析

enum SSE {
    enum Event: Equatable {
        case delta(LLMDelta)
        case done
        case ignore
    }

    /// 取出 `data:` 行的內容；其他行（event:、註解、空行）回傳 nil。
    static func payload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    }

    /// OpenAI 相容格式：choices[0].delta.content／reasoning_content，結尾是 [DONE]。
    /// 2026-10-03 以 DeepSeek deepseek-flash 實測：先送 reasoning_content，再送 content。
    static func openAIDelta(_ payload: String) throws -> Event {
        if payload == "[DONE]" { return .done }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String?; let reasoning_content: String? }
                let delta: Delta?
            }
            struct Err: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Err?
        }
        guard let c = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return .ignore }
        if let e = c.error { throw LLMError.http(0, String((e.message ?? "串流中斷").prefix(300))) }
        let d = c.choices?.first?.delta
        if let text = d?.content, !text.isEmpty { return .delta(.content(text)) }
        if let text = d?.reasoning_content, !text.isEmpty { return .delta(.reasoning(text)) }
        return .ignore
    }

    /// Anthropic Messages API 串流（依官方文件）：content_block_delta 的 text_delta／thinking_delta，結尾 message_stop。
    static func anthropicDelta(_ payload: String) throws -> Event {
        struct Chunk: Decodable {
            struct Delta: Decodable { let type: String?; let text: String?; let thinking: String? }
            struct Err: Decodable { let message: String? }
            let type: String
            let delta: Delta?
            let error: Err?
        }
        guard let c = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return .ignore }
        switch c.type {
        case "message_stop": return .done
        case "error": throw LLMError.http(0, String((c.error?.message ?? "串流中斷").prefix(300)))
        case "content_block_delta":
            if let t = c.delta?.text, !t.isEmpty { return .delta(.content(t)) }
            if let t = c.delta?.thinking, !t.isEmpty { return .delta(.reasoning(t)) }
            return .ignore
        default: return .ignore
        }
    }
}
