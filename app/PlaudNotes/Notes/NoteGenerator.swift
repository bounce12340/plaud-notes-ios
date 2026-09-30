import Foundation

/// 用 LLM 把逐字稿依範本整理成筆記。逐字稿太長時先分段摘要，再合併成最終筆記。
struct NoteGenerator: Sendable {
    let client: LLMClient
    let maxInputCharacters: Int

    struct Request: Sendable {
        var title: String
        var date: Date
        var transcript: Transcript
        var template: NoteTemplate
        /// 筆記輸出語言，例如「繁體中文（台灣）」「English」「日本語」
        var outputLanguage: String
        /// 說話者顯示名稱（speaker_0 → 王經理）；沒有對應就用原始 id
        var speakerNames: [String: String] = [:]
    }

    struct Result: Sendable {
        var markdown: String
        var chunkCount: Int
    }

    static let systemPrompt = """
    你是專業的會議與訪談筆記整理助理。規則：
    1. 只能根據使用者提供的逐字稿整理，不可加入逐字稿沒有的事實、數字、人名或結論。
    2. 逐字稿可能有語音辨識錯誤；無法確定的內容標註「【待確認 hh:mm:ss】」，不要自行猜測補完。
    3. 重點、決議、待辦盡量附上來源時間戳，格式為 [hh:mm:ss]。
    4. 專有名詞、產品名、法規名稱保留原文，必要時在括號加註譯名。
    5. 使用指定的輸出語言撰寫；若輸出語言是中文，一律使用台灣繁體中文與台灣用語。
    6. 只輸出筆記本身（Markdown），不要加前言或結語。
    """

    func generate(_ req: Request) async throws -> Result {
        let lines = Self.transcriptLines(req.transcript, names: req.speakerNames)
        let chunks = Self.chunk(lines, limit: max(2_000, maxInputCharacters))
        let values = Self.values(for: req)
        let instructions = req.template.render(values)

        if chunks.count <= 1 {
            let md = try await client.complete([
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: Self.finalPrompt(instructions: instructions, values: values,
                                                                 body: "逐字稿：\n" + (chunks.first ?? ""))),
            ])
            return Result(markdown: md, chunkCount: 1)
        }

        // Map：逐段抽出重點（保留時間戳），依序執行以免超過供應商的速率限制
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let part = try await client.complete([
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: """
                以下是一份長逐字稿的第 \(i + 1)/\(chunks.count) 段。請用\(req.outputLanguage)條列這一段的：
                重點（附時間戳）、決議、待辦（含負責人與期限，如有提到）、重要數字與專有名詞、關鍵引述。
                不要寫總結，也不要推測其他段落的內容。

                逐字稿第 \(i + 1) 段：
                \(chunk)
                """),
            ])
            partials.append("### 第 \(i + 1) 段重點\n\(part)")
        }

        // Reduce：依範本合併
        let md = try await client.complete([
            ChatMessage(role: .system, content: Self.systemPrompt),
            ChatMessage(role: .user, content: Self.finalPrompt(
                instructions: instructions, values: values,
                body: "以下是逐字稿各段的重點（依時間順序，已含時間戳）：\n\n" + partials.joined(separator: "\n\n"))),
        ])
        return Result(markdown: md, chunkCount: chunks.count)
    }

    // MARK: - 組 prompt

    static func values(for req: Request) -> [String: String] {
        let speakers = req.transcript.speakers.map { req.speakerNames[$0] ?? $0 }
        return [
            "title": req.title,
            "date": req.date.formatted(.iso8601.year().month().day()),
            "speakers": speakers.isEmpty ? "未標示" : speakers.joined(separator: "、"),
            "language": req.transcript.languageCode ?? "未知",
            "output_language": req.outputLanguage,
        ]
    }

    static func finalPrompt(instructions: String, values: [String: String], body: String) -> String {
        """
        \(instructions)

        輸出語言：\(values["output_language"] ?? "繁體中文（台灣）")

        \(body)
        """
    }

    /// 逐字稿轉成「[hh:mm:ss] 說話者：內容」一行一段。
    static func transcriptLines(_ t: Transcript, names: [String: String]) -> [String] {
        t.segments.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = s.speaker.map { names[$0] ?? $0 }.map { "\($0)：" } ?? ""
            return "[\(TranscriptExporter.timestamp(s.start))] \(who)\(text)"
        }
    }

    /// 依字數切段，不把同一行拆開（單行超過上限時才硬切）。
    static func chunk(_ lines: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for var line in lines {
            while line.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(String(line.prefix(limit)))
                line = String(line.dropFirst(limit))
            }
            if !current.isEmpty, current.count + 1 + line.count > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// 筆記輸出語言選項（也就是「翻譯」：英文會議可直接輸出中文筆記）
enum NoteLanguage: String, CaseIterable, Identifiable, Sendable {
    case zhTW = "繁體中文（台灣）"
    case en = "English"
    case ja = "日本語"
    case ko = "한국어"
    case sameAsSource = "與逐字稿相同的語言"

    var id: String { rawValue }
}
