import XCTest
@testable import PlaudNotes

/// 停止錄音後加入清單的流程：清單確定存檔才刪記錄檔；存不了檔（裝置鎖定）時留到之後再加。
@MainActor
final class RecordingStopFlowTests: XCTestCase {
    private var created: [URL] = []
    private var indexDir: URL!

    override func setUp() async throws {
        indexDir = FileManager.default.temporaryDirectory.appending(path: "stopflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for url in created { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: indexDir)
    }

    private func pendingSession(stopped: Bool?) throws -> RecordingSession {
        let dir = RecordingLibrary.recordingsDirectory
        var s = RecordingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        s.parts = [s.fileName]
        s.stopped = stopped
        try RecordingSessionStore.save(s, in: dir)
        try RecordingRecoveryTests.frames(100).write(to: dir.appending(path: s.fileName))
        created += [dir.appending(path: s.fileName), RecordingSessionStore.markerURL(s.id, in: dir)]
        return s
    }

    func testStoppedRecordingIsAddedAndMarkerRemoved() throws {
        let session = try pendingSession(stopped: true)
        let library = RecordingLibrary(indexURL: indexDir.appending(path: "library.json"))
        XCTAssertEqual(RecordingRecovery.recover(into: library, skipping: nil), 1)
        let item = try XCTUnwrap(library.item(id: session.id))
        XCTAssertFalse(item.title.contains("救回"))
        XCTAssertEqual(item.durationSeconds ?? 0, 100 * 1024 / 48_000, accuracy: 1e-6)
        XCTAssertEqual(item.recordedAt, session.startedAt)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: RecordingSessionStore.markerURL(session.id, in: RecordingLibrary.recordingsDirectory).path))
    }

    func testCrashedRecordingIsMarkedRecovered() throws {
        let session = try pendingSession(stopped: nil)
        let library = RecordingLibrary(indexURL: indexDir.appending(path: "library.json"))
        RecordingRecovery.recover(into: library, skipping: nil)
        XCTAssertTrue(library.item(id: session.id)?.title.hasSuffix("（中斷後救回）") ?? false)
    }

    func testActiveRecordingIsSkipped() throws {
        let session = try pendingSession(stopped: nil)
        let library = RecordingLibrary(indexURL: indexDir.appending(path: "library.json"))
        XCTAssertEqual(RecordingRecovery.recover(into: library, skipping: session.id), 0)
        XCTAssertNil(library.item(id: session.id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RecordingSessionStore.markerURL(session.id, in: RecordingLibrary.recordingsDirectory).path))
    }

    func testUnsavableLibraryKeepsMarkerForLater() throws {
        let session = try pendingSession(stopped: true)
        // 清單檔讀不到（模擬鎖定）：不加入、記錄檔保留
        let index = indexDir.appending(path: "library.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let library = RecordingLibrary(indexURL: index)
        XCTAssertEqual(RecordingRecovery.recover(into: library, skipping: nil), 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RecordingSessionStore.markerURL(session.id, in: RecordingLibrary.recordingsDirectory).path))

        // 「解鎖」後再試
        try FileManager.default.removeItem(at: index)
        library.reloadIfNeeded()
        XCTAssertEqual(RecordingRecovery.recover(into: library, skipping: nil), 1)
        XCTAssertNotNil(library.item(id: session.id))
    }

    func testActivityStateTimer() {
        let now = Date(timeIntervalSince1970: 1_000)
        let s = RecordingActivityAttributes.ContentState(phase: .recording, elapsed: 90, now: now)
        XCTAssertEqual(s.timerStart, Date(timeIntervalSince1970: 910), "Text(timerInterval:) 從這裡開始走秒")
        XCTAssertEqual(RecordingActivityAttributes.ContentState(phase: .interrupted, elapsed: 5).label,
                       "中斷中，結束後自動繼續")
    }
}
