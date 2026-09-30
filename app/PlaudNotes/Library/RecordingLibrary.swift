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
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        save()
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
