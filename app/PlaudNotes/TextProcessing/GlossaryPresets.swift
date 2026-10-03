import Foundation

/// 可一鍵加入詞庫的預設詞組。只加入使用者詞庫裡還沒有的行，之後可自由刪改。
///
/// 注意：詞庫有詞時，ElevenLabs 轉錄會另收 20% 費用（keyterms），所以預設不自動加入。
enum GlossaryPresets {
    struct Preset: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let summary: String
        let lines: [String]
    }

    static let all: [Preset] = [
        Preset(name: "台灣藥政法規", summary: "主管機關、法規與送件用語（TFDA、CDE、PIC/S GMP、CTD…）", lines: [
            "衛生福利部", "食品藥物管理署", "TFDA", "中央健康保險署", "健保署",
            "醫藥品查驗中心", "CDE", "藥事法", "查驗登記", "藥品許可證", "仿單",
            "臨床試驗", "生體相等性試驗", "藥價基準", "健保給付", "藥物安全監視", "風險管理計畫",
            "ICH", "PIC/S GMP", "GMP", "GDP", "PMF", "DMF", "CEP", "CTD", "eCTD",
            "NDA", "ANDA", "BLA", "IND", "FDA", "EMA",
        ]),
        Preset(name: "簡轉繁常見誤轉", summary: "OpenCC 轉換後仍需更正的寫法（樣本實測）", lines: [
            // 2026-10-03 樣本 C：「骨松」「冲冲冲」經 OpenCC s2tw 後仍不正確
            "骨松 => 骨鬆",
            "沖沖衝 => 衝衝衝",
        ]),
    ]

    /// 把預設詞組加到現有詞庫文字最後；已存在的詞（以正確寫法比對）不重複加入。回傳新文字與加入的行數。
    static func merge(_ preset: Preset, into text: String) -> (text: String, added: Int) {
        let existing = Set(Glossary.parse(text).map(\.term))
        let newLines = preset.lines.filter { line in
            guard let term = Glossary.parse(line).first?.term else { return false }
            return !existing.contains(term)
        }
        guard !newLines.isEmpty else { return (text, 0) }
        var out = text
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        out += "# \(preset.name)\n" + newLines.joined(separator: "\n") + "\n"
        return (out, newLines.count)
    }
}
