import Foundation

/// 依筆記（或逐字稿）內容請 LLM 建議錄音標題。
/// Plaud 匯出檔名取自當天行事曆事件，常與錄音內容不符；建議由使用者確認後才套用。
struct TitleSuggester: Sendable {
    let client: LLMClient
    /// 標題只需要大意，送出內容的字數上限
    var maxInputCharacters = 8_000

    func suggest(content: String, currentTitle: String, outputLanguage: String) async throws -> String? {
        let reply = try await client.complete([
            ChatMessage(role: .user, content: Self.prompt(content: content, currentTitle: currentTitle,
                                                         outputLanguage: outputLanguage,
                                                         limit: maxInputCharacters)),
        ])
        return Self.clean(reply)
    }

    static func prompt(content: String, currentTitle: String, outputLanguage: String, limit: Int) -> String {
        """
        請根據以下內容，替這份錄音取一個標題。
        規則：
        - 使用\(outputLanguage)；若是中文，使用台灣繁體中文。約 8 到 24 個字，點出主要議題（必要時含專案、產品或對象名稱）。
        - 只能根據內容，不可加入內容沒有的人名、公司或結論；不要加日期。
        - 只輸出標題本身，不要引號、編號、Markdown 或任何說明。
        目前的檔名（取自行事曆，可能與內容無關，僅供參考）：\(currentTitle)

        內容：
        \(content.prefix(limit))
        """
    }

    /// 取第一個非空行，去掉 Markdown 標題符號、「標題：」前綴、引號與結尾句號。
    static func clean(_ reply: String) -> String? {
        guard var s = reply.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["標題：", "標題:", "Title:", "title:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        // 引號與句號可能交錯（「…」。），反覆去除直到不再變動
        let wrappers = CharacterSet(charactersIn: "\"'“”‘’「」『』*` ")
        var previous = ""
        while previous != s {
            previous = s
            s = s.trimmingCharacters(in: wrappers)
            while let last = s.last, "。.".contains(last) { s.removeLast() }
        }
        return s.isEmpty ? nil : String(s.prefix(60))
    }

    /// 送出前去掉 App 加在筆記結尾的「由 … 產生」說明
    static func stripNotesFooter(_ notes: String) -> String {
        guard let r = notes.range(of: "\n\n---\n由 ", options: .backwards) else { return notes }
        return String(notes[..<r.lowerBound])
    }
}
