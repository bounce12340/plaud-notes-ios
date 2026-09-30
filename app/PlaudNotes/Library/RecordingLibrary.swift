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

    /// 筆記上的日期：優先用錄音時間，沒有才用加入 App 的時間
    var noteDate: Date { recordedAt ?? createdAt }
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

    private let indexURL = URL.documentsDirectory.appending(path: "library.json")

    init() { load() }

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
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            add(RecordingItem(id: id,
                              title: source.deletingPathExtension().lastPathComponent,
                              fileName: dest.lastPathComponent,
                              createdAt: .now,
                              source: .imported,
                              recordedAt: fileDate))
            // 音檔內嵌的錄音時間（例如語音備忘錄的 creation_time）比檔案時間可靠，有的話就覆蓋
            Task {
                if let date = await AudioMetadata.creationDate(of: dest) { setRecordedAt(date, for: id) }
            }
        } catch {
            lastError = "匯入失敗：\(error.localizedDescription)"
        }
    }

    func setRecordedAt(_ date: Date, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].recordedAt = date
        save()
    }

    func add(_ item: RecordingItem) {
        items.insert(item, at: 0)
        save()
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

    func saveTranscript(_ t: Transcript, for item: RecordingItem) {
        do {
            try JSONEncoder().encode(t).write(to: transcriptURL(for: item), options: [.atomic, .completeFileProtection])
        } catch {
            lastError = "儲存逐字稿失敗：\(error.localizedDescription)"
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        items = (try? JSONDecoder().decode([RecordingItem].self, from: data)) ?? []
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
        } catch {
            lastError = "儲存清單失敗：\(error.localizedDescription)"
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
