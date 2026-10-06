import XCTest
@testable import PlaudNotes

/// 主 App 匯入收件匣（iOS）：保留原始檔名與檔名日期，成功才從收件匣刪除；清單讀不到時不動。
@MainActor
final class SharedInboxImportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inboximport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportsPendingEntriesWithOriginalName() throws {
        let inbox = root.appending(path: "Inbox")
        let mp3 = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plaud_sample", withExtension: "mp3"))
        let entry = try SharedInbox.add(fileAt: mp3, originalName: "10-02 週會", in: inbox)

        let lib = RecordingLibrary(indexURL: root.appending(path: "library.json"))
        XCTAssertEqual(lib.importSharedInbox(from: inbox), 1)
        let item = try XCTUnwrap(lib.items.first)
        defer { lib.delete(item) }
        XCTAssertEqual(item.title, "10-02 週會")
        XCTAssertEqual(item.sourceFileName, "10-02 週會")
        XCTAssertEqual(item.recordedAtIsDateOnly, true, "檔名日期")
        XCTAssertTrue(item.fileName.hasSuffix(".mp3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.url(for: item).path))
        XCTAssertTrue(SharedInbox.pending(in: inbox).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SharedInbox.audioURL(entry, in: inbox).path))
    }

    func testLockedLibraryLeavesInboxUntouched() throws {
        let inbox = root.appending(path: "Inbox")
        let mp3 = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plaud_sample", withExtension: "mp3"))
        try SharedInbox.add(fileAt: mp3, originalName: "x", in: inbox)
        let index = root.appending(path: "library.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)   // 模擬讀不到
        let lib = RecordingLibrary(indexURL: index)
        XCTAssertEqual(lib.importSharedInbox(from: inbox), 0)
        XCTAssertEqual(SharedInbox.pending(in: inbox).count, 1)
    }

    /// 模擬器上 App Group 容器要能取得（entitlements 與 Info.plist 的 PlaudNotesAppGroup 一致）
    func testAppGroupContainerIsAvailable() {
        XCTAssertEqual(SharedInbox.groupIdentifier, "group.com.example.plaudnotes.PlaudNotes")
        XCTAssertNotNil(SharedInbox.defaultDirectory)
    }
}
