import XCTest
@testable import PlaudNotes

final class ElevenLabsParseTests: XCTestCase {
    func testMergesWordsBySpeakerAndSkipsAudioEvents() throws {
        let json = """
        {"language_code":"zh","text":"大家好今天開會",
         "words":[
          {"text":"大家","start":0.0,"end":0.4,"type":"word","speaker_id":"speaker_0"},
          {"text":"好","start":0.4,"end":0.6,"type":"word","speaker_id":"speaker_0"},
          {"text":"(笑聲)","start":0.6,"end":0.9,"type":"audio_event","speaker_id":"speaker_0"},
          {"text":"今天開會","start":1.0,"end":2.0,"type":"word","speaker_id":"speaker_1"}
         ]}
        """
        let t = try ElevenLabsProvider.parse(Data(json.utf8))
        XCTAssertEqual(t.languageCode, "zh")
        XCTAssertEqual(t.segments.count, 2)
        XCTAssertEqual(t.segments[0].text, "大家好")
        XCTAssertEqual(t.segments[0].end, 0.6)
        XCTAssertEqual(t.segments[1].speaker, "speaker_1")
    }

    // MARK: - 長段落切段

    /// 合成 ElevenLabs 回應：每個字詞 (text, start, end, type, speaker)
    private func response(_ words: [(String, Double, Double, String, String)]) -> Data {
        let items = words.map { w in
            #"{"text":"\#(w.0)","start":\#(w.1),"end":\#(w.2),"type":"\#(w.3)","speaker_id":"\#(w.4)"}"#
        }
        return Data(#"{"language_code":"zho","words":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    /// 一人連續講 90 秒：每秒一個字，每 8 秒一個句號（句號沒有長度）
    private func monologue(seconds: Int, sentenceEvery: Int?) -> [(String, Double, Double, String, String)] {
        var words: [(String, Double, Double, String, String)] = []
        for i in 0..<seconds {
            words.append(("字", Double(i), Double(i) + 0.9, "word", "speaker_0"))
            if let n = sentenceEvery, (i + 1) % n == 0 {
                words.append(("。", Double(i) + 0.9, Double(i) + 0.9, "word", "speaker_0"))
            }
        }
        return words
    }

    func testLongMonologueSplitsAtSentenceEnds() throws {
        let t = try ElevenLabsProvider.parse(response(monologue(seconds: 90, sentenceEvery: 8)))
        XCTAssertGreaterThan(t.segments.count, 2, "一人講 90 秒不可只有一段")
        for s in t.segments.dropLast() {
            XCTAssertTrue(s.text.hasSuffix("。"), "在句尾切段：\(s.text)")
            XCTAssertGreaterThanOrEqual(s.end - s.start, ElevenLabsProvider.Split.sentenceSeconds - 1)
        }
        XCTAssertEqual(t.segments.map(\.text).joined(), String(repeating: "字字字字字字字字。", count: 11) + "字字")
        XCTAssertEqual(t.segments[1].start, 24, "第二段從第 25 個字開始")
    }

    func testHardCapWithoutPunctuation() throws {
        let t = try ElevenLabsProvider.parse(response(monologue(seconds: 130, sentenceEvery: nil)))
        XCTAssertEqual(t.segments.count, 3)
        for s in t.segments { XCTAssertLessThanOrEqual(s.end - s.start, ElevenLabsProvider.Split.maxSeconds + 1) }
    }

    func testSplitsOnPauseButKeepsPunctuationWithSentence() throws {
        let t = try ElevenLabsProvider.parse(response([
            ("你", 0, 0.2, "word", "speaker_0"), ("好", 0.2, 0.4, "word", "speaker_0"),
            // 停頓後才出現的標點仍屬於前一句
            ("？", 3.0, 3.0, "word", "speaker_0"),
            ("今", 3.1, 3.3, "word", "speaker_0"), ("天", 3.3, 3.5, "word", "speaker_0"),
            ("開", 6.0, 6.2, "word", "speaker_0"), ("會", 6.2, 6.4, "word", "speaker_0"),
        ]))
        XCTAssertEqual(t.segments.map(\.text), ["你好？今天", "開會"])
        XCTAssertEqual(t.segments[1].start, 6.0)
    }

    func testSpacingNeverStartsSegment() throws {
        var words: [(String, Double, Double, String, String)] = []
        for i in 0..<30 {
            words.append(("word\(i).", Double(i), Double(i) + 0.8, "word", "speaker_0"))
            words.append((" ", Double(i) + 0.8, Double(i) + 1, "spacing", "speaker_0"))
        }
        let t = try ElevenLabsProvider.parse(response(words))
        XCTAssertEqual(t.segments.count, 2)
        XCTAssertTrue(t.segments[1].text.hasPrefix("word"), t.segments[1].text)
    }

    func testTimestampFormat() {
        XCTAssertEqual(TranscriptExporter.timestamp(3725.9), "01:02:05")
    }
}
