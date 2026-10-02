import AVFoundation
import XCTest
@testable import PlaudNotes

/// Plaud Web 匯出的 MP3（樣本 B，2026-10-02）：16 kHz 單聲道 32 kbps、ID3v2.4、沒有錄音時間，
/// 檔名是「MM-DD 當天行事曆事件」。Fixtures/plaud_sample.mp3 是用 ffmpeg 產生的同規格 2 秒測試音。
final class PlaudImportTests: XCTestCase {
    private let calendar = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - 檔名日期

    func testFileNameDateWithoutYear() {
        let ref = day(2026, 10, 2).addingTimeInterval(9 * 3600)
        XCTAssertEqual(FileNameDate.parse("10-02 週會", reference: ref), day(2026, 10, 2))
        XCTAssertEqual(FileNameDate.parse("9-30_訪談", reference: ref), day(2026, 9, 30))
        XCTAssertEqual(FileNameDate.parse("10-03", reference: ref), day(2026, 10, 3), "容許一天誤差")
        // 1 月匯出去年 12 月的錄音
        XCTAssertEqual(FileNameDate.parse("12-28 年終會議", reference: day(2027, 1, 5)), day(2026, 12, 28))
    }

    func testFileNameDateWithYear() {
        XCTAssertEqual(FileNameDate.parse("2025-03-15 客戶拜訪", reference: day(2026, 10, 2)), day(2025, 3, 15))
    }

    func testFileNameDateRejectsOtherNames() {
        let ref = day(2026, 10, 2)
        XCTAssertNil(FileNameDate.parse("New Recording 3", reference: ref))
        XCTAssertNil(FileNameDate.parse("02-30 不存在的日期", reference: ref))
        XCTAssertNil(FileNameDate.parse("13-01 月份錯誤", reference: ref))
        XCTAssertNil(FileNameDate.parse("10-021 不是日期", reference: ref))
        XCTAssertNil(FileNameDate.parse("會議 10-02", reference: ref), "日期必須在開頭")
    }

    func testDateOnlyText() {
        var item = RecordingItem(id: UUID(), title: "t", fileName: "f.mp3", createdAt: .now, source: .imported,
                                 recordedAt: day(2026, 10, 2), recordedAtIsDateOnly: true)
        XCTAssertTrue(item.noteDateText.hasSuffix("（時刻未知）"))
        item.recordedAtIsDateOnly = nil
        XCTAssertFalse(item.noteDateText.contains("時刻未知"))
    }

    // MARK: - 匯入

    func testPlaudMP3HasNoContainerDateAndIsReadable() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plaud_sample", withExtension: "mp3"))
        let date = await AudioMetadata.creationDate(of: url)
        XCTAssertNil(date, "Plaud MP3 沒有錄音時間，不可蓋掉檔名日期")
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.2)
    }

    @MainActor
    func testImportUsesFileNameDateAndKeepsSourceName() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plaud_sample", withExtension: "mp3"))
        let dir = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "10-02 週會.mp3")
        try FileManager.default.copyItem(at: fixture, to: source)

        let lib = RecordingLibrary(indexURL: dir.appending(path: "lib.json"))
        lib.importFile(at: source)
        let item = try XCTUnwrap(lib.items.first)
        defer { lib.delete(item) }

        let fileDate = try XCTUnwrap(source.resourceValues(forKeys: [.creationDateKey]).creationDate)
        XCTAssertEqual(item.recordedAt, FileNameDate.parse("10-02", reference: fileDate))
        XCTAssertEqual(item.recordedAtIsDateOnly, true)
        XCTAssertEqual(item.sourceFileName, "10-02 週會")
        XCTAssertEqual(item.title, "10-02 週會")
        XCTAssertTrue(item.fileName.hasSuffix(".mp3"))
    }

    @MainActor
    func testRenameRemarkAndInfoKeepAutoDate() {
        let lib = RecordingLibrary(indexURL: FileManager.default.temporaryDirectory
            .appending(path: "lib-\(UUID().uuidString).json"))
        let id = UUID()
        let d = day(2026, 10, 2)
        lib.add(RecordingItem(id: id, title: "10-02 週會", fileName: "none.mp3", createdAt: .now, source: .imported,
                              recordedAt: d, sourceFileName: "10-02 週會", recordedAtIsDateOnly: true))
        defer { if let it = lib.item(id: id) { lib.delete(it) } }

        lib.rename(id: id, title: "  ")
        XCTAssertEqual(lib.item(id: id)?.title, "10-02 週會", "空白標題不套用")
        lib.rename(id: id, title: " 新藥查驗登記進度討論 ")
        XCTAssertEqual(lib.item(id: id)?.title, "新藥查驗登記進度討論")
        XCTAssertEqual(lib.item(id: id)?.sourceFileName, "10-02 週會")

        // 只改備註：時間維持自動、只有日期
        lib.updateInfo(id: id, recordedAt: d, remark: "地點：台北")
        XCTAssertNotEqual(lib.item(id: id)?.recordedAtIsManual, true)
        XCTAssertEqual(lib.item(id: id)?.recordedAtIsDateOnly, true)
        lib.setRemark(id: id, remark: "原檔名（行事曆）：10-02 週會")
        XCTAssertEqual(lib.item(id: id)?.remark, "原檔名（行事曆）：10-02 週會")

        // 補上時刻：變成手動、不再是只有日期
        lib.updateInfo(id: id, recordedAt: d.addingTimeInterval(14 * 3600), remark: "")
        XCTAssertEqual(lib.item(id: id)?.recordedAtIsManual, true)
        XCTAssertNil(lib.item(id: id)?.recordedAtIsDateOnly)

        // 改回自動：重新取檔名日期
        lib.resetRecordedAt(id: id)
        XCTAssertEqual(lib.item(id: id)?.recordedAt, FileNameDate.parse("10-02", reference: lib.item(id: id)!.createdAt))
        XCTAssertEqual(lib.item(id: id)?.recordedAtIsDateOnly, true)
    }

    func testOldItemJSONDecodesWithoutNewFields() throws {
        let old = #"{"id":"6B0F2E0A-0001-4000-8000-000000000009","title":"t","fileName":"f.m4a","createdAt":0,"source":"imported"}"#
        let item = try JSONDecoder().decode(RecordingItem.self, from: Data(old.utf8))
        XCTAssertNil(item.sourceFileName)
        XCTAssertNil(item.recordedAtIsDateOnly)
    }

    // MARK: - 筆記日期

    func testNoteDateUsesLocalDay() {
        // ISO8601 預設 UTC：本地凌晨或深夜的錄音不可跑到前／後一天
        for hour in [0, 7, 23] {
            let d = day(2026, 10, 2).addingTimeInterval(Double(hour) * 3600 + 1800)
            let req = NoteGenerator.Request(title: "t", date: d,
                                            transcript: Transcript(languageCode: nil, segments: [], engine: "x"),
                                            template: NoteTemplate(id: UUID(), name: "x", prompt: "", isBuiltIn: false),
                                            outputLanguage: "繁體中文（台灣）")
            XCTAssertEqual(NoteGenerator.values(for: req)["date"], "2026-10-02", "\(hour):30")
        }
    }

    // MARK: - AI 標題

    func testTitleCleanup() {
        XCTAssertEqual(TitleSuggester.clean("新藥查驗登記進度討論"), "新藥查驗登記進度討論")
        XCTAssertEqual(TitleSuggester.clean("\n## 標題：「新藥查驗登記進度討論」。\n說明…"), "新藥查驗登記進度討論")
        XCTAssertEqual(TitleSuggester.clean("Title: \"Q3 Budget Review\"."), "Q3 Budget Review")
        XCTAssertEqual(TitleSuggester.clean("**季度預算檢討**"), "季度預算檢討")
        XCTAssertNil(TitleSuggester.clean("  \n「」\n"))
        XCTAssertEqual(TitleSuggester.clean(String(repeating: "長", count: 100))?.count, 60)
    }

    func testStripNotesFooter() {
        XCTAssertEqual(TitleSuggester.stripNotesFooter("# 筆記\n\n內容\n\n---\n由 m（h）依範本「x」產生。\n"), "# 筆記\n\n內容")
        XCTAssertEqual(TitleSuggester.stripNotesFooter("沒有頁尾"), "沒有頁尾")
    }

    func testSuggestSendsContentAndCurrentTitle() async throws {
        let llm = MockLLM()
        let title = try await TitleSuggester(client: llm, maxInputCharacters: 5)
            .suggest(content: "一二三四五六七八", currentTitle: "10-02 週會", outputLanguage: "繁體中文（台灣）")
        XCTAssertEqual(title, "回覆1")
        let prompt = try XCTUnwrap(llm.calls.first?.first?.content)
        XCTAssertTrue(prompt.contains("10-02 週會"))
        XCTAssertTrue(prompt.contains("一二三四五"))
        XCTAssertFalse(prompt.contains("六"), "內容依上限截斷")
        XCTAssertTrue(prompt.contains("不可加入內容沒有的"))
    }
}
