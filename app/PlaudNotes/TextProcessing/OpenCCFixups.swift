import Foundation

/// OpenCC 轉換後的 App 修正。`ChineseConverter.convert` 保持與 OpenCC 官方結果一致，修正另外套用。
///
/// OpenCC 字典有「是只 → 是隻」（這是只猫 → 這是隻貓），但口語常見的「不是只有」「就是只要」也會被轉成「隻」。
/// 2026-10-03 以樣本 C（23 分鐘中文報告）確認：逐字稿 5 個「隻」有 4 個是這種誤轉；官方 opencc 套件結果相同。
/// 只修有實例的情況，不改字典本身。
enum OpenCCFixups {
    static func apply(_ text: String) -> String {
        guard text.contains("是隻") else { return text }
        // 「是隻」後面接動詞、副詞或助動詞時，量詞「隻」不成立 → 改回「只」；「這是隻貓」不受影響
        return text.replacing(/是隻(?=[有要能會是看靠想做用給把讓為對說講跟和在剩限需])/, with: "是只")
    }
}

extension ChineseConverter {
    /// OpenCC 轉換＋App 修正。App 內的逐字稿、筆記、標題一律用這個。
    func convertWithFixups(_ text: String) -> String {
        OpenCCFixups.apply(convert(text))
    }
}
