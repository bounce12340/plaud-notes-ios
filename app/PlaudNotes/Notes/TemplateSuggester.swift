import Foundation

/// 依逐字稿在本機推測適合的內建範本（不呼叫 AI、不上傳）。
///
/// 規則以說話比例為主、用詞為輔：
/// - 一人說話佔 80% 以上 → 報告／簡報（提到業績、目標、專案等工作用詞）或講座
/// - 兩人、較少說話的一方常發問 → 訪談
/// - 其他多人對話 → 會議記錄
/// 樣本 C（2026-10-03，一人業務報告，主講約 99%）原本套用「會議記錄」，決議與待辦都是空的。
enum TemplateSuggester {
    struct Suggestion: Equatable, Sendable {
        var templateName: String
        var reason: String
    }

    /// 工作報告常見用詞；一人主講時出現夠多就判斷為報告而不是講座
    static let reportKeywords = ["業績", "目標", "達成", "成長", "營收", "專案", "進度", "客戶", "季度", "報告", "KPI"]

    static func suggest(for transcript: Transcript) -> Suggestion? {
        var chars: [String: Int] = [:]
        var questions: [String: Int] = [:]
        for s in transcript.segments {
            guard let sp = s.speaker else { continue }
            chars[sp, default: 0] += s.text.count
            questions[sp, default: 0] += s.text.filter { $0 == "？" || $0 == "?" }.count
        }
        let total = chars.values.reduce(0, +)
        guard total >= 300 else { return nil }   // 太短無法判斷
        let ranked = chars.sorted { $0.value > $1.value }
        let top = ranked[0]
        let topShare = Double(top.value) / Double(total)
        let name = { (sp: String) in transcript.displayName(sp) ?? sp }
        let percent = { (share: Double) in "\(Int((share * 100).rounded()))%" }

        if topShare >= 0.8 {
            let text = transcript.plainText
            let hits = reportKeywords.filter { text.contains($0) }
            if hits.count >= 3 {
                return Suggestion(templateName: "報告／簡報",
                                  reason: "\(name(top.key)) 說話約佔 \(percent(topShare))，且提到\(hits.prefix(3).joined(separator: "、"))等工作用詞")
            }
            return Suggestion(templateName: "講座", reason: "\(name(top.key)) 說話約佔 \(percent(topShare))，以一人主講為主")
        }

        // 只算說話比例 10% 以上的人，偶爾插話的不算
        let major = ranked.filter { Double($0.value) / Double(total) >= 0.1 }
        if major.count == 2 {
            let asker = major[1]
            if questions[asker.key, default: 0] >= 3 {
                return Suggestion(templateName: "訪談",
                                  reason: "兩人對話，\(name(asker.key)) 提問 \(questions[asker.key, default: 0]) 次")
            }
        }
        return Suggestion(templateName: "會議記錄", reason: "\(max(major.count, 2)) 人以上的對話")
    }
}
