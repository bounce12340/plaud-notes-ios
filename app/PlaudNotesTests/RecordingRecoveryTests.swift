import Foundation
import XCTest
@testable import PlaudNotes

/// ADTS 掃描、分段接合、閃退後救回。用手工組的 ADTS 格子測邏輯（不需要解碼器）；
/// 真正的 AAC 編碼檔由 RecorderFileTests（iOS）驗證。
final class RecordingRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "rec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 一格 ADTS：48 kHz（索引 3）、單聲道、1024 個取樣
    static func frame(payload: Int, fill: UInt8 = 0xAB, rateIndex: UInt8 = 3) -> Data {
        let len = 7 + payload
        let header: [UInt8] = [
            0xFF, 0xF1,
            (1 << 6) | (rateIndex << 2),
            (1 << 6) | UInt8((len >> 11) & 0x03),
            UInt8((len >> 3) & 0xFF),
            UInt8((len & 0x07) << 5) | 0x1F,
            0xFC,
        ]
        return Data(header) + Data(repeating: fill, count: payload)
    }

    static func frames(_ n: Int, fill: UInt8 = 0xAB) -> Data {
        (0..<n).reduce(into: Data()) { d, i in d += frame(payload: 150 + i % 40, fill: fill) }
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    // MARK: - ADTS

    func testHeaderParsing() {
        let h = ADTS.header([UInt8](Self.frame(payload: 200).prefix(7)))
        XCTAssertEqual(h, ADTS.Header(frameLength: 207, sampleRate: 48_000, samples: 1024))
        XCTAssertNil(ADTS.header([0xFF, 0xF1, 0x4C, 0x40, 0x00, 0x1F, 0xFC]), "長度小於標頭")
        XCTAssertNil(ADTS.header([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00]), "ID3 不是 ADTS")
        XCTAssertNil(ADTS.header([0xFF, 0xF1, 0x4C]))
    }

    func testScanStopsAtTruncatedFrame() {
        let full = Self.frames(100)
        let s = ADTS.scan(full)
        XCTAssertEqual(s.frames, 100)
        XCTAssertEqual(s.validBytes, full.count)
        XCTAssertEqual(s.duration, 100 * 1024 / 48_000, accuracy: 1e-9)

        // 閃退：最後一格只寫了一半
        let cut = full.prefix(full.count - 60)
        let c = ADTS.scan(cut)
        XCTAssertEqual(c.frames, 99)
        XCTAssertLessThan(c.validBytes, cut.count)
        XCTAssertEqual(ADTS.scan(Data()).frames, 0)
    }

    func testConcatenateDropsPartialTails() throws {
        let a = try write(Self.frames(50, fill: 0x11).dropLast(30), "a.aac")
        let b = try write(Self.frames(20, fill: 0x22), "b.aac")
        let out = dir.appending(path: "out.aac")
        let s = try ADTS.concatenate([a, b], into: out, chunkSize: 97)
        XCTAssertEqual(s.frames, 49 + 20)
        let joined = try Data(contentsOf: out)
        XCTAssertEqual(joined.count, s.validBytes)
        XCTAssertEqual(ADTS.scan(joined).frames, 69, "接合後每一格都完整")
    }

    // MARK: - 救回

    func testFinalizeSinglePartTruncatesTail() throws {
        var session = RecordingSession(id: UUID(), startedAt: .now)
        session.parts = [session.nextPartName()]
        try RecordingSessionStore.save(session, in: dir)
        _ = try write(Self.frames(80).dropLast(10), session.fileName)
        XCTAssertEqual(RecordingSessionStore.pending(in: dir), [session])

        let result = try XCTUnwrap(RecordingSessionStore.finalize(session, in: dir))
        XCTAssertEqual(result.fileName, session.fileName)
        XCTAssertEqual(result.duration, 79 * 1024 / 48_000, accuracy: 1e-9)
        let data = try Data(contentsOf: dir.appending(path: session.fileName))
        XCTAssertEqual(ADTS.scan(data).validBytes, data.count, "不完整的尾巴已切掉")
        XCTAssertTrue(RecordingSessionStore.pending(in: dir).isEmpty, "記錄已刪除")
    }

    func testFinalizeJoinsPartsAndCleansUp() throws {
        var session = RecordingSession(id: UUID(), startedAt: .now)
        session.parts = [session.nextPartName()]
        session.parts.append(session.nextPartName())
        XCTAssertEqual(session.parts, ["\(session.id.uuidString).aac", "\(session.id.uuidString).part2.aac"])
        try RecordingSessionStore.save(session, in: dir)
        _ = try write(Self.frames(30, fill: 0x11).dropLast(5), session.parts[0])
        _ = try write(Self.frames(40, fill: 0x22), session.parts[1])

        let result = try XCTUnwrap(RecordingSessionStore.finalize(session, in: dir))
        XCTAssertEqual(result.duration, Double(29 + 40) * 1024 / 48_000, accuracy: 1e-9)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files, [session.fileName], "只留下合併後的檔案")
    }

    func testFinalizeWithoutAudioRemovesEverything() throws {
        var session = RecordingSession(id: UUID(), startedAt: .now)
        session.parts = [session.nextPartName()]
        try RecordingSessionStore.save(session, in: dir)
        _ = try write(Data([0xFF, 0xF1, 0x4C]), session.fileName)   // 剛開始就被終止
        XCTAssertNil(try RecordingSessionStore.finalize(session, in: dir))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testFinalizeAfterInterruptedMergeDoesNotDuplicate() throws {
        // 上次合併到一半被終止：合併檔已換上、記錄已改成只剩一段，但第二段還沒刪
        var session = RecordingSession(id: UUID(), startedAt: .now)
        session.parts = [session.fileName]
        try RecordingSessionStore.save(session, in: dir)
        _ = try write(Self.frames(60), session.fileName)
        _ = try write(Self.frames(40), "\(session.id.uuidString).part2.aac")
        let result = try XCTUnwrap(RecordingSessionStore.finalize(session, in: dir))
        XCTAssertEqual(result.duration, 60 * 1024 / 48_000, accuracy: 1e-9)
    }
}
