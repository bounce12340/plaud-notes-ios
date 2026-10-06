import Foundation
import Observation

/// 筆記範本。`prompt` 可用變數：
/// `{{title}}` `{{date}}` `{{speakers}}` `{{language}}` `{{output_language}}` `{{remark}}`；逐字稿會另外附在後面。
struct NoteTemplate: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var prompt: String
    var isBuiltIn: Bool

    static let variables = ["{{title}}", "{{date}}", "{{speakers}}", "{{language}}", "{{output_language}}", "{{remark}}"]

    func render(_ values: [String: String]) -> String {
        var out = prompt
        for (k, v) in values { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }
}

extension NoteTemplate {
    // 固定 UUID，讓內建範本在更新 App 後仍保持同一個 id
    static let builtIns: [NoteTemplate] = [
        NoteTemplate(id: UUID(uuidString: "6B0F2E0A-0001-4000-8000-000000000001")!, name: "會議記錄", prompt: """
        請把以下會議逐字稿整理成會議記錄，使用 Markdown，依序包含：
        ## 基本資訊（會議名稱：{{title}}；日期：{{date}}；與會者：{{speakers}}）
        ## 議題與討論摘要（依議題分小節，每點附時間戳）
        ## 決議事項
        ## 待辦事項（表格：事項｜負責人｜期限｜時間戳；逐字稿沒提到的欄位填「未提及」）
        ## 未決問題與後續追蹤
        """, isBuiltIn: true),
        NoteTemplate(id: UUID(uuidString: "6B0F2E0A-0002-4000-8000-000000000002")!, name: "訪談", prompt: """
        請把以下訪談逐字稿整理成訪談筆記，使用 Markdown，依序包含：
        ## 訪談資訊（主題：{{title}}；日期：{{date}}；參與者：{{speakers}}）
        ## 受訪者背景
        ## 問答重點（Q／A 條列，每題附時間戳）
        ## 關鍵引述（原文照錄，附時間戳）
        ## 洞察與觀察
        ## 後續追蹤事項
        """, isBuiltIn: true),
        NoteTemplate(id: UUID(uuidString: "6B0F2E0A-0003-4000-8000-000000000003")!, name: "講座", prompt: """
        請把以下講座逐字稿整理成學習筆記，使用 Markdown，依序包含：
        ## 講座資訊（主題：{{title}}；日期：{{date}}；講者：{{speakers}}）
        ## 大綱
        ## 重點概念（每個概念用 2–4 句說明，附時間戳）
        ## 名詞解釋
        ## 講者引述
        ## 延伸問題
        """, isBuiltIn: true),
        NoteTemplate(id: UUID(uuidString: "6B0F2E0A-0005-4000-8000-000000000005")!, name: "報告／簡報", prompt: """
        請把以下工作報告或簡報的逐字稿整理成報告摘要，使用 Markdown，依序包含：
        ## 報告資訊（主題：{{title}}；日期：{{date}}；報告人與與會者：{{speakers}}）
        ## 報告大綱
        ## 重點內容（依報告段落分小節，每點附時間戳）
        ## 數據與成果（表格：項目｜數字｜比較基準或期間｜時間戳；逐字稿沒提到的欄位填「未提及」）
        ## 做法與經驗（具體做了什麼、為什麼有效）
        ## 困難與因應
        ## 提問、回饋與後續事項（若沒有就寫「無」）
        """, isBuiltIn: true),
        NoteTemplate(id: UUID(uuidString: "6B0F2E0A-0004-4000-8000-000000000004")!, name: "一般摘要", prompt: """
        請把以下逐字稿整理成摘要，使用 Markdown，依序包含：
        ## TL;DR（3 句以內）
        ## 重點（條列，每點附時間戳）
        ## 待辦事項（若沒有就寫「無」）
        """, isBuiltIn: true),
    ]

    static func builtIn(named name: String) -> NoteTemplate? { builtIns.first { $0.name == name } }

    static func newCustom() -> NoteTemplate {
        NoteTemplate(id: UUID(), name: "自訂範本", prompt: """
        請把以下逐字稿整理成筆記，使用 Markdown：
        ## 重點
        ## 待辦事項
        """, isBuiltIn: false)
    }
}

/// 內建範本＋使用者自訂範本（存成 JSON）。內建範本不可刪除，但可以「複製後修改」。
@MainActor
@Observable
final class TemplateStore {
    private(set) var custom: [NoteTemplate] = []
    var lastError: String?

    private let url: URL

    init(url: URL = URL.documentsDirectory.appending(path: "templates.json")) {
        self.url = url
        load()
    }

    var all: [NoteTemplate] { NoteTemplate.builtIns + custom }

    func template(id: UUID) -> NoteTemplate? { all.first { $0.id == id } }

    func upsert(_ t: NoteTemplate) {
        guard !t.isBuiltIn else { return }
        if let i = custom.firstIndex(where: { $0.id == t.id }) { custom[i] = t } else { custom.append(t) }
        save()
    }

    func duplicate(_ t: NoteTemplate) -> NoteTemplate {
        let copy = NoteTemplate(id: UUID(), name: t.name + "（副本）", prompt: t.prompt, isBuiltIn: false)
        upsert(copy)
        return copy
    }

    func delete(_ t: NoteTemplate) {
        custom.removeAll { $0.id == t.id }
        save()
    }

    /// 檔案存在但讀不到（螢幕鎖定時被背景喚醒）；解鎖前不可存檔，避免蓋掉自訂範本
    private(set) var needsReload = false

    func reloadIfNeeded() {
        if needsReload { load() }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { needsReload = false; return }
        do {
            let data = try Data(contentsOf: url)
            custom = ((try? JSONDecoder().decode([NoteTemplate].self, from: data)) ?? []).filter { !$0.isBuiltIn }
            needsReload = false
        } catch {
            needsReload = true
        }
    }

    private func save() {
        guard !needsReload else {
            lastError = "裝置鎖定中，暫時無法儲存範本；解鎖後請再試一次。"
            return
        }
        do {
            try JSONEncoder().encode(custom).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            lastError = "儲存範本失敗：\(error.localizedDescription)"
        }
    }
}
