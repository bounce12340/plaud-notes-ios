import AVFoundation
import Foundation
import Observation

/// 一筆錄音（匯入或 App 內錄製）。音檔一律複製到 App 容器內的 Recordings/。
struct RecordingItem: Identifiable, Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case imported, recorded }

    let id: UUID
    var title: String
    let fileName: String
    let createdAt: Date
    let source: Source
    var durationSeconds: Double?
    /// 實際錄音時間（匯入檔從音檔 metadata 或檔案建立時間取得）；舊資料為 nil
    var recordedAt: Date? = nil
    /// true 表示錄音時間由使用者手動設定，自動偵測不可覆蓋
    var recordedAtIsManual: Bool? = nil
    /// 使用者備註，例如「語音備忘錄分享時間，實際錄音為 9/29 下午」；會提供給筆記整理參考
    var remark: String? = nil
    /// 匯入時的原始檔名（不含副檔名）；Plaud 匯出檔是當天行事曆事件名稱，改標題後仍保留
    var sourceFileName: String? = nil
    /// true 表示 recordedAt 只有日期（例如從檔名取得），時刻未知
    var recordedAtIsDateOnly: Bool? = nil

    /// 筆記上的日期：優先用錄音時間，沒有才用加入 App 的時間
    var noteDate: Date { recordedAt ?? createdAt }

    /// 畫面上顯示的錄音時間；只有日期時不顯示時刻
    var noteDateText: String {
        recordedAtIsDateOnly == true
            ? noteDate.formatted(date: .abbreviated, time: .omitted) + "（時刻未知）"
            : noteDate.formatted(date: .abbreviated, time: .shortened)
    }

    var trimmedRemark: String? {
        let s = remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}

/// 最小可用的錄音清單，存成 JSON。之後（M1）改用 SwiftData。
@MainActor
@Observable
final class RecordingLibrary {
    private(set) var items: [RecordingItem] = []
    var lastError: String?

    static let recordingsDirectory: URL = {
        let dir = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let indexURL: URL

    init(indexURL: URL = URL.documentsDirectory.appending(path: "library.json")) {
        self.indexURL = indexURL
        load()
    }

    func url(for item: RecordingItem) -> URL {
        Self.recordingsDirectory.appending(path: item.fileName)
    }

    /// 從檔案 App／分享匯入：複製一份到 App 容器，原檔不動。
    func importFile(at source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let dest = Self.recordingsDirectory.appending(path: "\(id.uuidString).\(ext)")
        // 複製前先讀原檔建立時間（複製後的檔案時間是現在）
        let fileDate = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let name = source.deletingPathExtension().lastPathComponent
        // 檔名開頭的日期（Plaud Web 匯出檔）比檔案建立時間（多半是下載時間）可靠
        let nameDate = FileNameDate.parse(name, reference: fileDate ?? .now)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            add(RecordingItem(id: id,
                              title: name,
                              fileName: dest.lastPathComponent,
                              createdAt: .now,
                              source: .imported,
                              recordedAt: nameDate ?? fileDate,
                              sourceFileName: name,
                              recordedAtIsDateOnly: nameDate == nil ? nil : true))
            // 音檔內嵌的錄音時間（例如語音備忘錄的 creation_time）比檔名、檔案時間可靠，有的話就覆蓋
            Task {
                if let date = await AudioMetadata.creationDate(of: dest) { setRecordedAt(date, for: id) }
            }
        } catch {
            lastError = "匯入失敗：\(error.localizedDescription)"
        }
    }

    func item(id: UUID) -> RecordingItem? { items.first { $0.id == id } }

    /// 自動偵測到的錄音時間；使用者手動設定過就不覆蓋
    func setRecordedAt(_ date: Date, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              items[i].recordedAtIsManual != true else { return }
        items[i].recordedAt = date
        items[i].recordedAtIsDateOnly = nil
        save()
    }

    /// 使用者手動設定錄音時間與備註。時間沒改（只改備註）就維持原本的自動偵測狀態。
    func updateInfo(id: UUID, recordedAt: Date, remark: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if recordedAt != items[i].noteDate || items[i].recordedAt == nil {
            items[i].recordedAt = recordedAt
            items[i].recordedAtIsManual = true
            items[i].recordedAtIsDateOnly = nil
        }
        items[i].remark = remark
        save()
    }

    /// 只改備註，不動錄音時間
    func setRemark(id: UUID, remark: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].remark = remark
        save()
    }

    func rename(id: UUID, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = t
        save()
    }

    /// 改回自動偵測（先用檔名日期，再以音檔容器時間覆蓋）
    func resetRecordedAt(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].recordedAtIsManual = false
        if let name = items[i].sourceFileName,
           let d = FileNameDate.parse(name, reference: items[i].createdAt) {
            items[i].recordedAt = d
            items[i].recordedAtIsDateOnly = true
        }
        let url = url(for: items[i])
        save()
        Task {
            if let date = await AudioMetadata.creationDate(of: url) { setRecordedAt(date, for: id) }
        }
    }

    /// 回傳是否已寫入清單檔。存檔失敗（例如裝置鎖定）時不留在畫面上，
    /// 讓呼叫端知道要保留原始資料（例如錄音記錄檔）稍後再加。
    @discardableResult
    func add(_ item: RecordingItem) -> Bool {
        items.insert(item, at: 0)
        guard save() else {
            items.removeAll { $0.id == item.id }
            return false
        }
        return true
    }

    func delete(_ item: RecordingItem) {
        let fm = FileManager.default
        try? fm.removeItem(at: url(for: item))
        try? fm.removeItem(at: transcriptURL(for: item))
        try? fm.removeItem(at: notesURL(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - 逐字稿與筆記（與音檔放在同一個資料夾）

    func transcriptURL(for item: RecordingItem) -> URL {
        Self.recordingsDirectory.appending(path: "\(item.id.uuidString).transcript.json")
    }

    func notesURL(for item: RecordingItem) -> URL {
        Self.recordingsDirectory.appending(path: "\(item.id.uuidString).notes.md")
    }

    func loadTranscript(for item: RecordingItem) -> Transcript? {
        guard let data = try? Data(contentsOf: transcriptURL(for: item)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    @discardableResult
    func saveTranscript(_ t: Transcript, for item: RecordingItem) -> Bool {
        do {
            try JSONEncoder().encode(t).write(to: transcriptURL(for: item), options: [.atomic, .completeFileProtection])
            return true
        } catch {
            lastError = "儲存逐字稿失敗：\(error.localizedDescription)"
            return false
        }
    }

    func loadNotes(for item: RecordingItem) -> String? {
        try? String(contentsOf: notesURL(for: item), encoding: .utf8)
    }

    func saveNotes(_ md: String, for item: RecordingItem) {
        do {
            try Data(md.utf8).write(to: notesURL(for: item), options: [.atomic, .completeFileProtection])
        } catch {
            lastError = "儲存筆記失敗：\(error.localizedDescription)"
        }
    }

    /// 清單檔存在但讀不到（例如 App 在螢幕鎖定時被背景喚醒，完整保護的檔案無法讀取）。
    /// 這時不可存檔，否則會用空清單蓋掉原本的資料；解鎖後再重新讀取。
    private(set) var needsReload = false

    func reloadIfNeeded() {
        guard needsReload else { return }
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { needsReload = false; return }
        do {
            let data = try Data(contentsOf: indexURL)
            items = (try? JSONDecoder().decode([RecordingItem].self, from: data)) ?? []
            needsReload = false
        } catch {
            needsReload = true
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !needsReload else {
            lastError = "裝置鎖定中，暫時無法儲存清單；解鎖後請再試一次。"
            return false
        }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            lastError = "儲存清單失敗：\(error.localizedDescription)"
            return false
        }
    }
}

enum AudioMetadata {
    /// 讀取音檔 metadata 的建立時間（QuickTime／MP4 的 creationDate）。
    static func creationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }
}
