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
        /// 詞庫中的正確寫法（人名、藥名、公司名等）
        var glossary: [String] = []
        /// 使用者對這份錄音的備註（例如實際錄音時間、場合）
        var remark: String? = nil
    }

    struct Result: Sendable {
        var markdown: String
        var chunkCount: Int
    }

    /// 產生過程的進度（給畫面顯示）
    enum Progress: Sendable, Equatable {
        /// 長逐字稿分段整理中（已完成幾段／共幾段）
        case summarizing(done: Int, total: Int)
        /// 推理模型正在思考（還沒有正文），附目前已收到的思考字數，讓畫面看得出仍在進行。
        /// 樣本 C 實測：deepseek-flash 先思考約 97 秒才開始寫正文。
        case thinking(characters: Int)
        /// 最終筆記目前已收到的內容
        case writing(String)
    }

    typealias ProgressHandler = @MainActor @Sendable (Progress) -> Void

    static let systemPrompt = """
    你是專業的會議與訪談筆記整理助理。規則：
    1. 只能根據使用者提供的逐字稿整理，不可加入逐字稿沒有的事實、數字、人名或結論。
    2. 逐字稿可能有語音辨識錯誤；無法確定的內容標註「【待確認 hh:mm:ss】」，不要自行猜測補完。
    3. 重點、決議、待辦盡量附上來源時間戳，格式為 [hh:mm:ss]。
    4. 專有名詞、產品名、法規名稱保留原文，必要時在括號加註譯名。
    5. 使用指定的輸出語言撰寫；若輸出語言是中文，一律使用台灣繁體中文與台灣用語。
    6. 只輸出筆記本身（Markdown），不要加前言或結語。
    7. 說話者以逐字稿標示的名稱或代號（例如 speaker_0）稱呼。不可推測某個代號是哪一位與會者；逐字稿中被點名的人，只有在明確知道是誰時才寫進負責人，否則寫「未確認」。
    8. 日期只照逐字稿原話寫：原話沒有年份就不要補年份，也不要把不同句子的月、日、年拼成一個日期。會議日期以「基本資訊」提供的為準。
    9. 若有提供「專有名詞」清單，逐字稿中發音或拼寫相近的詞，請改用清單中的正確寫法。
    """

    /// `onProgress` 有值時，最後一次呼叫改用串流，邊收邊回報；沒有就一次取得完整回覆。
    func generate(_ req: Request, onProgress: ProgressHandler? = nil) async throws -> Result {
        let lines = Self.transcriptLines(req.transcript)
        let chunks = Self.chunk(lines, limit: max(2_000, maxInputCharacters))
        let values = Self.values(for: req)
        let instructions = req.template.render(values)

        if chunks.count <= 1 {
            let md = try await finalCall(onProgress: onProgress, [
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: Self.finalPrompt(instructions: instructions, values: values,
                                                                 body: "逐字稿：\n" + (chunks.first ?? ""))),
            ])
            return Result(markdown: md, chunkCount: 1)
        }

        // Map：逐段抽出重點（保留時間戳），依序執行以免超過供應商的速率限制
        let glossaryLine = req.glossary.isEmpty ? "" : "\n專有名詞（正確寫法）：" + req.glossary.joined(separator: "、")
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await onProgress?(.summarizing(done: i, total: chunks.count))
            let part = try await client.complete([
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: """
                以下是一份長逐字稿的第 \(i + 1)/\(chunks.count) 段。請用\(req.outputLanguage)條列這一段的：
                重點（附時間戳）、決議、待辦（含負責人與期限，如有提到）、重要數字與專有名詞、關鍵引述。
                不要寫總結，也不要推測其他段落的內容。\(glossaryLine)

                逐字稿第 \(i + 1) 段：
                \(chunk)
                """),
            ])
            partials.append("### 第 \(i + 1) 段重點\n\(part)")
        }

        // Reduce：依範本合併
        await onProgress?(.summarizing(done: chunks.count, total: chunks.count))
        let md = try await finalCall(onProgress: onProgress, [
            ChatMessage(role: .system, content: Self.systemPrompt),
            ChatMessage(role: .user, content: Self.finalPrompt(
                instructions: instructions, values: values,
                body: "以下是逐字稿各段的重點（依時間順序，已含時間戳）：\n\n" + partials.joined(separator: "\n\n"))),
        ])
        return Result(markdown: md, chunkCount: chunks.count)
    }

    /// 最終筆記：有進度回報就用串流（約每 0.15 秒更新一次畫面），否則一次取得。
    /// 串流還沒收到任何正文就失敗或結束時（例如供應商不支援串流、事件格式不符），改用一次性呼叫，
    /// 避免串流問題讓整份筆記產生失敗。已收到部分正文後才失敗則直接回報錯誤，不重送。
    private func finalCall(onProgress: ProgressHandler?, _ messages: [ChatMessage]) async throws -> String {
        guard let onProgress else { return try await client.complete(messages) }
        var text = ""
        var lastUpdate = ContinuousClock.now
        var thinkingCharacters = 0
        do {
            for try await delta in client.stream(messages) {
                switch delta {
                case .reasoning(let piece):
                    // 思考內容不屬於筆記，只把字數告訴畫面
                    let first = thinkingCharacters == 0
                    thinkingCharacters += piece.count
                    if first || ContinuousClock.now - lastUpdate >= .milliseconds(500) {
                        await onProgress(.thinking(characters: thinkingCharacters))
                        lastUpdate = .now
                    }
                    continue
                case .content(let piece):
                    text += piece
                }
                if ContinuousClock.now - lastUpdate >= .milliseconds(150) {
                    await onProgress(.writing(text))
                    lastUpdate = .now
                }
            }
        } catch {
            guard text.isEmpty, !(error is CancellationError) else { throw error }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            text = try await client.complete(messages)
        }
        await onProgress(.writing(text))
        return text
    }

    // MARK: - 組 prompt

    static func values(for req: Request) -> [String: String] {
        let speakers = req.transcript.speakers.compactMap { req.transcript.displayName($0) }
        return [
            "title": req.title,
            // ISO8601 格式預設用 UTC；台灣凌晨 0–8 點的錄音會被算成前一天，所以指定本地時區
            "date": req.date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()),
            "speakers": speakers.isEmpty ? "未標示" : speakers.joined(separator: "、"),
            "language": req.transcript.languageCode ?? "未知",
            "output_language": req.outputLanguage,
            "glossary": req.glossary.joined(separator: "、"),
            "remark": req.remark ?? "",
        ]
    }

    static func finalPrompt(instructions: String, values: [String: String], body: String) -> String {
        var s = """
        \(instructions)

        輸出語言：\(values["output_language"] ?? "繁體中文（台灣）")
        """
        if let g = values["glossary"], !g.isEmpty { s += "\n專有名詞（正確寫法）：\(g)" }
        if let r = values["remark"], !r.isEmpty { s += "\n錄音備註（使用者提供，可作為背景資訊，優先於逐字稿推測）：\(r)" }
        return s + "\n\n" + body
    }

    /// 逐字稿轉成「[hh:mm:ss] 說話者：內容」一行一段（說話者使用設定的名稱）。
    static func transcriptLines(_ t: Transcript) -> [String] {
        t.segments.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = t.displayName(s.speaker).map { "\($0)：" } ?? ""
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
