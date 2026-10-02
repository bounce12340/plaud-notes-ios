import Foundation

/// 從檔名開頭解析錄音日期。
/// Plaud Web 匯出的 MP3 沒有錄音時間 metadata，檔名是「MM-DD 當天行事曆事件」，例如「10-02 週會」
/// （樣本 B，2026-10-02）。也接受「YYYY-MM-DD …」。只有日期、沒有時刻。
enum FileNameDate {
    /// 回傳該日 00:00（本地時區）。檔名沒有年份時取 `reference` 的年份；
    /// 若因此落在 `reference` 之後（例如 1 月匯出去年 12 月的錄音）就改用前一年。
    static func parse(_ fileName: String, reference: Date, calendar: Calendar = .current) -> Date? {
        guard let m = fileName.firstMatch(of: /^(?:(\d{4})-)?(\d{1,2})-(\d{1,2})(?!\d)/),
              let month = Int(m.2), let day = Int(m.3) else { return nil }
        if let y = m.1.flatMap({ Int($0) }) {
            return date(year: y, month: month, day: day, calendar: calendar)
        }
        let year = calendar.component(.year, from: reference)
        guard let d = date(year: year, month: month, day: day, calendar: calendar) else { return nil }
        // 容許一天誤差（時區、午夜前後匯出）
        if d > reference.addingTimeInterval(86_400) {
            return date(year: year - 1, month: month, day: day, calendar: calendar)
        }
        return d
    }

    /// 不合法的日期（例如 02-30）回傳 nil，而不是讓 Calendar 自動進位成 3 月
    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let d = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return c.year == year && c.month == month && c.day == day ? d : nil
    }
}
