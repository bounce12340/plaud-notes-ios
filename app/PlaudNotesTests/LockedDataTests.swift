import XCTest
@testable import PlaudNotes

/// App 在螢幕鎖定時被背景喚醒（接收轉錄結果）時，完整保護的資料檔讀不到。
/// 這時不可用空資料蓋掉原檔，解鎖後要能重新讀取。用「路徑是資料夾」模擬讀取失敗。
@MainActor
final class LockedDataTests: XCTestCase {
    func testLibraryDoesNotOverwriteUnreadableIndexAndReloadsLater() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "locked-\(UUID().uuidString)")
        let index = dir.appending(path: "library.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lib = RecordingLibrary(indexURL: index)
        XCTAssertTrue(lib.needsReload)
        lib.add(RecordingItem(id: UUID(), title: "新錄音", fileName: "x.m4a", createdAt: .now, source: .recorded))
        XCTAssertNotNil(lib.lastError, "讀不到時不存檔，並提示")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path, isDirectory: &isDir) && isDir.boolValue,
                      "原檔不可被覆蓋")

        // 「解鎖」：檔案變得可讀
        try FileManager.default.removeItem(at: index)
        let saved = RecordingItem(id: UUID(), title: "原有錄音", fileName: "a.m4a", createdAt: .now, source: .imported)
        try JSONEncoder().encode([saved]).write(to: index)
        lib.reloadIfNeeded()
        XCTAssertFalse(lib.needsReload)
        XCTAssertEqual(lib.items.map(\.title), ["原有錄音"])
    }

    func testGlossaryDoesNotOverwriteUnreadableFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "locked-\(UUID().uuidString)")
        let url = dir.appending(path: "glossary.txt")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = GlossaryStore(url: url)
        XCTAssertTrue(store.needsReload)
        store.text = "不該寫入"
        try FileManager.default.removeItem(at: url)
        try Data("骨松 => 骨鬆".utf8).write(to: url)
        store.reloadIfNeeded()
        XCTAssertEqual(store.entries.first?.term, "骨鬆")
    }

    func testMissingFilesAreNotTreatedAsLocked() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        XCTAssertFalse(RecordingLibrary(indexURL: dir.appending(path: "library.json")).needsReload)
        XCTAssertFalse(GlossaryStore(url: dir.appending(path: "glossary.txt")).needsReload)
    }
}
