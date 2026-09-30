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

    func testTimestampFormat() {
        XCTAssertEqual(TranscriptExporter.timestamp(3725.9), "01:02:05")
    }
}
