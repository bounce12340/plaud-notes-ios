import XCTest
@testable import PlaudNotes

final class ChineseConverterTests: XCTestCase {
    private struct Case: Decodable { let id: String; let input: String; let expected: String }

    // 字典載入約需數百毫秒，同一個測試程序內共用（XCTest 依序執行測試方法）
    nonisolated(unsafe) private static var cache: [ChineseConverter.Mode: ChineseConverter] = [:]

    private func converter(_ mode: ChineseConverter.Mode) throws -> ChineseConverter {
        if let c = Self.cache[mode] { return c }
        // 字典打包在 App bundle 的 OpenCC/ 資料夾
        let c = try ChineseConverter(mode: mode, bundle: Bundle(for: RecordingLibrary.self))
        Self.cache[mode] = c
        return c
    }

    private func cases(_ name: String) throws -> [Case] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"),
                                "找不到測試資料 \(name).json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    /// OpenCC 1.4.2 官方 testcases.json 中所有 s2twp 案例
    func testOfficialS2TWPCases() throws {
        let conv = try converter(.s2twp)
        let all = try cases("opencc_s2twp_cases")
        XCTAssertEqual(all.count, 85)
        for c in all {
            XCTAssertEqual(conv.convert(c.input), c.expected, c.id)
        }
    }

    /// OpenCC 1.4.2 官方 testcases.json 中所有 s2tw 案例
    func testOfficialS2TWCases() throws {
        let conv = try converter(.s2tw)
        let all = try cases("opencc_s2tw_cases")
        XCTAssertEqual(all.count, 65)
        for c in all {
            XCTAssertEqual(conv.convert(c.input), c.expected, c.id)
        }
    }

    func testMeetingSnippet() throws {
        XCTAssertEqual(try converter(.s2tw).convert("对，二四六八。这个软件的服务器"),
                       "對，二四六八。這個軟件的服務器")
        XCTAssertEqual(try converter(.s2twp).convert("对，二四六八。这个软件的服务器"),
                       "對，二四六八。這個軟體的伺服器")
    }

    func testNonChineseUnchanged() throws {
        let conv = try converter(.s2twp)
        for s in ["", "Hello, API 2.0!", "  \n", "😀👍🏽 emoji", "한국어"] {
            XCTAssertEqual(conv.convert(s), s)
        }
    }

    func testPostProcessorSkipsJapaneseAndKorean() throws {
        XCTAssertTrue(TranscriptPostProcessor.shouldConvert("这是中文"))
        XCTAssertFalse(TranscriptPostProcessor.shouldConvert("日本の国際会議"))
        XCTAssertFalse(TranscriptPostProcessor.shouldConvert("韩国 한국어"))
        XCTAssertFalse(TranscriptPostProcessor.shouldConvert("English only"))

        let t = Transcript(languageCode: "zho", segments: [
            .init(start: 0, end: 1, speaker: "speaker_0", text: "这个会议"),
            .init(start: 1, end: 2, speaker: "speaker_1", text: "国際会議です"),
            .init(start: 2, end: 3, speaker: "speaker_0", text: "OK"),
        ], engine: "test")
        let out = TranscriptPostProcessor.process(t, with: try converter(.s2tw))
        XCTAssertEqual(out.segments.map(\.text), ["這個會議", "国際会議です", "OK"])
        XCTAssertEqual(out.postProcessing, "opencc-s2tw")
        XCTAssertEqual(out.segments.map(\.start), [0, 1, 2])
    }
}
