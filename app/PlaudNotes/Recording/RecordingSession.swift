import Foundation

/// 進行中的錄音。開始錄音時寫一個記錄檔（`<id>.recording.json`），正常停止後刪除；
/// App 中途被終止時記錄會留下來，下次開啟 App 時據此把已錄的部分救回清單。
///
/// 一般只有一段 `<id>.aac`；中斷後原本的錄音器無法繼續時會開新的一段（`<id>.part2.aac`…），
/// 停止或救回時再接成一個檔案。
struct RecordingSession: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var parts: [String] = []
    /// 使用者按了停止（相對於 App 中途被終止）；舊記錄檔沒有這個欄位
    var stopped: Bool? = nil

    var fileName: String { "\(id.uuidString).aac" }

    func nextPartName() -> String {
        parts.isEmpty ? fileName : "\(id.uuidString).part\(parts.count + 1).aac"
    }
}

enum RecordingSessionStore {
    static let markerSuffix = ".recording.json"

    static func markerURL(_ id: UUID, in dir: URL) -> URL {
        dir.appending(path: id.uuidString + markerSuffix)
    }

    static func save(_ session: RecordingSession, in dir: URL) throws {
        try JSONEncoder().encode(session).write(to: markerURL(session.id, in: dir), options: .atomic)
    }

    static func remove(_ id: UUID, in dir: URL) {
        try? FileManager.default.removeItem(at: markerURL(id, in: dir))
    }

    /// 留下記錄、沒有正常結束的錄音
    static func pending(in dir: URL) -> [RecordingSession] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(markerSuffix) }.compactMap { name in
            (try? Data(contentsOf: dir.appending(path: name)))
                .flatMap { try? JSONDecoder().decode(RecordingSession.self, from: $0) }
        }.sorted { $0.startedAt < $1.startedAt }
    }

    struct Finalized: Equatable {
        var fileName: String
        var duration: Double
    }

    /// 把各段接成 `<id>.aac`（捨棄最後一格不完整的資料），刪除分段。完全沒有錄到聲音就回傳 nil。
    /// 每一步都可以在中途被終止：先換成合併後的檔案、更新記錄，再刪其他分段。
    /// 記錄檔由呼叫端在錄音確實加進清單後才刪（`keepMarker`），清單存檔失敗時下次還能再救回。
    static func finalize(_ session: RecordingSession, in dir: URL, keepMarker: Bool = false) throws -> Finalized? {
        let fm = FileManager.default
        let dest = dir.appending(path: session.fileName)
        let parts = session.parts.map { dir.appending(path: $0) }.filter { fm.fileExists(atPath: $0.path) }
        let scan: ADTS.Scan
        if parts == [dest] {
            scan = try ADTS.scan(dest)
            let size = (try fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
            if scan.validBytes < size {
                let h = try FileHandle(forWritingTo: dest)
                try h.truncate(atOffset: UInt64(scan.validBytes))
                try h.close()
            }
        } else {
            let tmp = dir.appending(path: "\(session.id.uuidString).joining.aac")
            scan = try ADTS.concatenate(parts, into: tmp)
            // rename(2) 會原子性地蓋掉第一段：不會出現兩個檔案都不在的瞬間
            guard rename(tmp.path, dest.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
            }
            var merged = session
            merged.parts = [session.fileName]
            try save(merged, in: dir)
            for p in parts where p != dest { try? fm.removeItem(at: p) }
        }
        guard scan.frames > 0 else {
            remove(session.id, in: dir)
            try? fm.removeItem(at: dest)
            return nil
        }
        if !keepMarker { remove(session.id, in: dir) }
        return Finalized(fileName: session.fileName, duration: scan.duration)
    }
}
