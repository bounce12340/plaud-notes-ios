import Foundation

/// 分享收件匣：Share Extension 把音檔放進 App Group 共用資料夾，主 App 開啟時匯入。
///
/// Extension 讀不到主 App 的容器，只能透過 App Group 交換檔案。每筆是一個音檔加一個說明檔
/// （`<id>.json`）；說明檔最後才寫入，所以只有說明檔存在的才是完整的一筆，複製到一半被中斷的不會被匯入。
enum SharedInbox {
    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        /// 原始檔名（不含副檔名），例如「10-02 週會」
        let originalName: String
        /// 收件匣裡的音檔檔名
        let fileName: String
        let sharedAt: Date
    }

    /// Info.plist 的 `PlaudNotesAppGroup`（由 project.yml 的 APP_GROUP_ID 帶入，與 entitlements 一致）
    static var groupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "PlaudNotesAppGroup") as? String
    }

    #if !canImport(FoundationNetworking)
    /// App Group 沒設定好時為 nil
    static var defaultDirectory: URL? {
        guard let id = groupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return container.appending(path: "Inbox", directoryHint: .isDirectory)
    }
    #endif

    /// 複製音檔進收件匣。`originalName` 為 nil 時用來源檔名。
    @discardableResult
    static func add(fileAt source: URL, originalName: String?, in dir: URL, now: Date = .now) throws -> Entry {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = cleanName(originalName) ?? cleanName(source.deletingPathExtension().lastPathComponent) ?? "分享的錄音"
        let entry = Entry(id: id, originalName: name, fileName: "\(id.uuidString).\(ext)", sharedAt: now)
        let audio = dir.appending(path: entry.fileName)
        do {
            try FileManager.default.copyItem(at: source, to: audio)
            try JSONEncoder().encode(entry).write(to: dir.appending(path: "\(id.uuidString).json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: audio)
            throw error
        }
        return entry
    }

    /// 完整的待匯入項目（依分享時間排序）
    static func pending(in dir: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appending(path: name)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  FileManager.default.fileExists(atPath: dir.appending(path: entry.fileName).path) else { return nil }
            return entry
        }.sorted { $0.sharedAt < $1.sharedAt }
    }

    static func audioURL(_ entry: Entry, in dir: URL) -> URL { dir.appending(path: entry.fileName) }

    static func remove(_ entry: Entry, in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appending(path: "\(entry.id.uuidString).json"))
        try? FileManager.default.removeItem(at: dir.appending(path: entry.fileName))
    }

    /// 刪掉沒有說明檔、且超過一天的音檔（複製到一半被中斷留下的）
    static func purgeIncomplete(in dir: URL, olderThan age: TimeInterval = 86_400, now: Date = .now) {
        let fm = FileManager.default
        let keep = Set(pending(in: dir).map(\.fileName))
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasSuffix(".json") && !keep.contains(name) {
            let url = dir.appending(path: name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }

    /// 去掉路徑字元與前後空白；空字串回傳 nil
    static func cleanName(_ name: String?) -> String? {
        guard let name else { return nil }
        let s = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(120))
    }
}
