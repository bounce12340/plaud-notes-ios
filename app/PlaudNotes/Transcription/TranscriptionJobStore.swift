import Foundation

/// 一筆背景轉錄工作（每段錄音最多一筆）。
struct TranscriptionJob: Codable, Sendable, Equatable {
    enum Status: Codable, Sendable, Equatable {
        case uploading
        /// ElevenLabs 的原始回應已存到 response.json，等 App 解鎖後再整理成逐字稿
        case finished
        case failed(String)
    }

    let recordingID: UUID
    var attempt: Int
    var status: Status
    let startedAt: Date
}

/// 背景轉錄的暫存資料：`<root>/<錄音 ID>/` 內有 job.json、body.multipart（上傳本文）、response.json。
///
/// 這些檔案在螢幕鎖定時也要能寫入（App 可能在鎖定時被喚醒接收結果），所以使用預設的
/// 「第一次解鎖後可存取」保護等級；逐字稿等使用者資料仍用完整保護，等解鎖後才寫入。
final class TranscriptionJobStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try? url.setResourceValues(values)
    }

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "TranscriptionJobs", directoryHint: .isDirectory)
    }

    func directory(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func bodyURL(_ id: UUID) -> URL { directory(id).appending(path: "body.multipart") }
    func responseURL(_ id: UUID) -> URL { directory(id).appending(path: "response.json") }
    private func jobURL(_ id: UUID) -> URL { directory(id).appending(path: "job.json") }

    /// 清掉同一段錄音的舊工作，建立新資料夾
    func prepare(_ id: UUID) throws {
        remove(id)
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
    }

    func save(_ job: TranscriptionJob) throws {
        try JSONEncoder().encode(job).write(to: jobURL(job.recordingID), options: .atomic)
    }

    func job(_ id: UUID) -> TranscriptionJob? {
        guard let data = try? Data(contentsOf: jobURL(id)) else { return nil }
        return try? JSONDecoder().decode(TranscriptionJob.self, from: data)
    }

    func allJobs() -> [TranscriptionJob] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { UUID(uuidString: $0.lastPathComponent).flatMap(job) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func update(_ id: UUID, _ change: (inout TranscriptionJob) -> Void) throws {
        guard var job = job(id) else { return }
        change(&job)
        try save(job)
    }

    /// 存下回應並刪掉上傳本文（可能數十 MB）
    func saveResponse(_ data: Data, for id: UUID) throws {
        try data.write(to: responseURL(id), options: .atomic)
        try? FileManager.default.removeItem(at: bodyURL(id))
        try update(id) { $0.status = .finished }
    }

    func markFailed(_ id: UUID, message: String) {
        try? FileManager.default.removeItem(at: bodyURL(id))
        try? update(id) { $0.status = .failed(message) }
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(id))
    }
}
