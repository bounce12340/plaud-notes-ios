import XCTest
@testable import PlaudNotes

final class TemplateAndGlossaryPresetTests: XCTestCase {
    /// 合成逐字稿：(說話者, 內容) 依序排列
    private func transcript(_ lines: [(String, String)]) -> Transcript {
        Transcript(languageCode: "zho", segments: lines.enumerated().map { i, l in
            .init(start: Double(i) * 10, end: Double(i) * 10 + 9, speaker: l.0, text: l.1)
        }, engine: "test")
    }

    private let filler = String(repeating: "今天跟大家分享我們這一季的做法。", count: 8)

    // MARK: - 範本建議

    func testMonologueReportSuggestsReportTemplate() throws {
        let t = transcript([
            ("speaker_0", "今年業績目標是一千四百萬，目前成長二成。" + filler),
            ("speaker_0", filler + "客戶回饋很好。"),
            ("speaker_1", "有。"),
            ("speaker_0", filler),
        ])
        let s = try XCTUnwrap(TemplateSuggester.suggest(for: t))
        XCTAssertEqual(s.templateName, "報告／簡報")
        XCTAssertTrue(s.reason.contains("speaker_0"), s.reason)
        XCTAssertTrue(s.reason.contains("業績"), s.reason)
    }

    func testMonologueWithoutWorkTermsSuggestsLecture() throws {
        let lecture = String(repeating: "光合作用是植物利用光能把二氧化碳和水轉成養分的過程。", count: 6)
        let t = transcript([("speaker_0", lecture), ("speaker_0", lecture), ("speaker_1", "好。")])
        XCTAssertEqual(TemplateSuggester.suggest(for: t)?.templateName, "講座")
    }

    func testInterviewSuggestsInterview() throws {
        let answer = String(repeating: "我們當初選擇這個市場，是因為需求很明確。", count: 4)
        let t = transcript([
            ("speaker_1", "可以先介紹一下您的背景嗎？我們很好奇您一路走來的經歷與轉折。"), ("speaker_0", answer),
            ("speaker_1", "為什麼選擇這個市場？當時還有其他選項，最後是怎麼決定的。"), ("speaker_0", answer),
            ("speaker_1", "遇到最大的困難是什麼？後來團隊是怎麼一步一步克服過來的。"), ("speaker_0", answer),
        ])
        let s = try XCTUnwrap(TemplateSuggester.suggest(for: t))
        XCTAssertEqual(s.templateName, "訪談")
        XCTAssertTrue(s.reason.contains("3 次"), s.reason)
    }

    func testMultiSpeakerSuggestsMeeting() throws {
        let line = String(repeating: "這部分我負責，下週三前完成。", count: 4)
        let t = transcript([("speaker_0", line), ("speaker_1", line), ("speaker_2", line),
                            ("speaker_0", line), ("speaker_1", line), ("speaker_2", line)])
        XCTAssertEqual(TemplateSuggester.suggest(for: t)?.templateName, "會議記錄")
    }

    func testTooShortOrNoSpeakersGivesNoSuggestion() {
        XCTAssertNil(TemplateSuggester.suggest(for: transcript([("speaker_0", "你好。")])))
        let noSpeaker = Transcript(languageCode: nil, segments: [.init(start: 0, end: 1, speaker: nil, text: filler + filler)],
                                   engine: "test")
        XCTAssertNil(TemplateSuggester.suggest(for: noSpeaker))
    }

    func testSuggestedNamesExistAsBuiltIns() {
        for name in ["報告／簡報", "講座", "訪談", "會議記錄"] {
            XCTAssertNotNil(NoteTemplate.builtIn(named: name), name)
        }
        XCTAssertEqual(Set(NoteTemplate.builtIns.map(\.id)).count, NoteTemplate.builtIns.count, "內建範本 id 不可重複")
    }

    // MARK: - 預設詞庫

    func testPresetMergeAddsOnlyMissingTerms() throws {
        let preset = try XCTUnwrap(GlossaryPresets.all.first { $0.name == "台灣藥政法規" })
        let first = GlossaryPresets.merge(preset, into: "Etihad\nTFDA")
        XCTAssertEqual(first.added, preset.lines.count - 1, "TFDA 已存在，不重複加入")
        XCTAssertTrue(first.text.hasPrefix("Etihad\nTFDA\n# 台灣藥政法規\n"))
        let again = GlossaryPresets.merge(preset, into: first.text)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.text, first.text)
    }

    func testPresetTermsAreValidKeytermsAndCorrectionsWork() throws {
        for preset in GlossaryPresets.all {
            let entries = Glossary.parse(preset.lines.joined(separator: "\n"))
            XCTAssertEqual(entries.count, preset.lines.count, "\(preset.name) 每行都要能解析")
            XCTAssertEqual(Glossary.keyterms(from: entries.map(\.term)).count, entries.count,
                           "\(preset.name) 的詞都要符合 ElevenLabs keyterms 限制")
        }
        let fixes = Glossary.parse(try XCTUnwrap(GlossaryPresets.all.first { $0.name == "簡轉繁常見誤轉" })
            .lines.joined(separator: "\n"))
        XCTAssertEqual(Glossary.applyCorrections("她有骨松症狀，我就沖沖衝", entries: fixes), "她有骨鬆症狀，我就衝衝衝")
    }
}
