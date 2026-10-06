import Foundation
import XCTest
@testable import PlaudNotes

/// Share Extension ↔ 主 App 的收件匣。
final class SharedInboxTests: XCTestCase {
    private var dir: URL!
    private var source: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        source = FileManager.default.temporaryDirectory.appending(path: "src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: source)
    }

    private func audio(_ name: String, bytes: Int = 64) throws -> URL {
        let url = source.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testAddKeepsOriginalNameAndListsInOrder() throws {
        let a = try SharedInbox.add(fileAt: audio("tmp1.m4a"), originalName: "10-02 週會",
                                    in: dir, now: Date(timeIntervalSince1970: 20))
        let b = try SharedInbox.add(fileAt: audio("語音備忘錄 3.M4A"), originalName: nil,
                                    in: dir, now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(a.originalName, "10-02 週會")
        XCTAssertEqual(b.originalName, "語音備忘錄 3")
        XCTAssertTrue(b.fileName.hasSuffix(".m4a"), "副檔名統一小寫")
        XCTAssertEqual(SharedInbox.pending(in: dir).map(\.id), [b.id, a.id], "依分享時間排序")
        XCTAssertEqual(try Data(contentsOf: SharedInbox.audioURL(a, in: dir)).count, 64)

        SharedInbox.remove(a, in: dir)
        XCTAssertEqual(SharedInbox.pending(in: dir), [b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SharedInbox.audioURL(a, in: dir).path))
    }

    func testIncompleteCopyIsIgnoredAndPurgedLater() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 複製到一半被中斷：只有音檔、沒有說明檔
        let orphan = dir.appending(path: "\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: orphan)
        XCTAssertTrue(SharedInbox.pending(in: dir).isEmpty)

        SharedInbox.purgeIncomplete(in: dir, now: .now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "可能還在複製中，一天內不刪")
        SharedInbox.purgeIncomplete(in: dir, now: .now.addingTimeInterval(2 * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testEntryWithoutAudioIsIgnored() throws {
        let e = try SharedInbox.add(fileAt: audio("x.mp3"), originalName: "x", in: dir)
        try FileManager.default.removeItem(at: SharedInbox.audioURL(e, in: dir))
        XCTAssertTrue(SharedInbox.pending(in: dir).isEmpty)
    }

    func testCleanName() {
        XCTAssertEqual(SharedInbox.cleanName("  a/b  "), "a-b")
        XCTAssertNil(SharedInbox.cleanName("   "))
        XCTAssertNil(SharedInbox.cleanName(nil))
        XCTAssertEqual(SharedInbox.cleanName(String(repeating: "長", count: 200))?.count, 120)
    }
}
