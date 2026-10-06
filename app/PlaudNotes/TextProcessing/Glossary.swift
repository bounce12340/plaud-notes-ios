import Foundation
import Observation

/// 專有名詞詞庫：一行一個詞，可寫「錯誤寫法 => 正確寫法」做轉錄後的自動更正。
///
/// 用途：
/// 1. 轉錄：傳給 ElevenLabs `keyterms`，讓模型優先辨識這些詞（ElevenLabs 會加收 20% 轉錄費）
/// 2. 後處理：套用「=>」更正規則（區分大小寫、完整字串比對）
/// 3. 筆記：列入 prompt，要求 LLM 使用正確寫法
enum Glossary {
    struct Entry: Equatable, Sendable {
        var term: String
        var aliases: [String]
    }

    /// 解析使用者輸入。`#` 開頭為註解；「A, B => C」表示 A、B 都更正為 C。
    static func parse(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "=>")
            let term = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !seen.contains(term) else { continue }
            let aliases = parts.count > 1
                ? parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != term }
                : []
            seen.insert(term)
            out.append(Entry(term: term, aliases: aliases))
        }
        return out
    }

    /// ElevenLabs keyterms 限制（官方文件 2026-09-30）：最多 1000 個、每個少於 50 字元、最多 5 個詞、
    /// 不可含 < > { } [ ] \。不符合的詞直接略過（仍會用於更正與筆記）。
    static func keyterms(from terms: [String]) -> [String] {
        let forbidden = CharacterSet(charactersIn: "<>{}[]\\")
        var out: [String] = []
        for t in terms {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.count < 50,
                  s.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
                  s.split(whereSeparator: \.isWhitespace).count <= 5,
                  !out.contains(s) else { continue }
            out.append(s)
            if out.count == 1000 { break }
        }
        return out
    }

    /// 套用更正規則（先換較長的別名，避免短別名先吃掉長別名的一部分）。
    static func applyCorrections(_ text: String, entries: [Entry]) -> String {
        let pairs = entries.flatMap { e in e.aliases.map { ($0, e.term) } }
            .sorted { $0.0.count > $1.0.count }
        var out = text
        for (alias, term) in pairs { out = out.replacingOccurrences(of: alias, with: term) }
        return out
    }

    static func apply(to transcript: Transcript, entries: [Entry]) -> Transcript {
        guard entries.contains(where: { !$0.aliases.isEmpty }) else { return transcript }
        var t = transcript
        t.segments = t.segments.map { s in
            var s = s
            s.text = applyCorrections(s.text, entries: entries)
            return s
        }
        return t
    }
}

/// 詞庫文字（存在 App 容器，不同步）。
@MainActor
@Observable
final class GlossaryStore {
    var text: String {
        didSet { if !loading { save() } }
    }

    private let url: URL
    private var loading = false
    /// 檔案存在但讀不到（螢幕鎖定時被背景喚醒）；解鎖前不可存檔，避免用空白蓋掉詞庫
    private(set) var needsReload = false

    init(url: URL = URL.documentsDirectory.appending(path: "glossary.txt")) {
        self.url = url
        text = ""
        load()
    }

    var entries: [Glossary.Entry] { Glossary.parse(text) }

    func reloadIfNeeded() {
        if needsReload { load() }
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard FileManager.default.fileExists(atPath: url.path) else { needsReload = false; return }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            needsReload = false
        } catch {
            needsReload = true
        }
    }

    private func save() {
        guard !needsReload else { return }
        try? Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
