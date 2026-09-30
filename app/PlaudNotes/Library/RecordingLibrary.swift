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
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            add(RecordingItem(id: id,
                              title: source.deletingPathExtension().lastPathComponent,
                              fileName: dest.lastPathComponent,
                              createdAt: .now,
                              source: .imported))
        } catch {
            lastError = "匯入失敗：\(error.localizedDescription)"
        }
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
