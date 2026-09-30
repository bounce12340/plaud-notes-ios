import XCTest
@testable import PlaudNotes

final class GlossaryAndSpeakerTests: XCTestCase {
    // MARK: - 詞庫解析

    func testParseGlossary() {
        let entries = Glossary.parse("""
        # 註解
        Etihad

        Syrenjit, Serenjit => Serengit
          C2 Pharma
        Etihad
        => 空別名
        """)
        XCTAssertEqual(entries.map(\.term), ["Etihad", "Serengit", "C2 Pharma", "空別名"])
        XCTAssertEqual(entries[1].aliases, ["Syrenjit", "Serenjit"])
        XCTAssertEqual(entries[0].aliases, [])
        XCTAssertEqual(entries[3].aliases, [])
    }

    func testCorrectionsPreferLongerAlias() {
        let entries = Glossary.parse("""
        Ajala, Jala => AJ Lab
        Syrenjit => Serengit
        """)
        XCTAssertEqual(Glossary.applyCorrections("Send to Ajala and Jala about Syrenjit.", entries: entries),
                       "Send to AJ Lab and AJ Lab about Serengit.")
    }

    func testApplyToTranscriptKeepsTimingAndSpeakers() {
        let t = Transcript(languageCode: "eng", segments: [
            .init(start: 1, end: 2, speaker: "speaker_0", text: "Syrenjit renewal"),
        ], engine: "test")
        let out = Glossary.apply(to: t, entries: Glossary.parse("Syrenjit => Serengit"))
        XCTAssertEqual(out.segments[0].text, "Serengit renewal")
        XCTAssertEqual(out.segments[0].start, 1)
        XCTAssertEqual(out.segments[0].speaker, "speaker_0")
    }

    // MARK: - ElevenLabs keyterms

    func testKeytermsFilter() {
        let long = String(repeating: "a", count: 50)
        let terms = Glossary.keyterms(from: ["Etihad", " C2 Pharma ", "", "bad<term>", "a b c d e f",
                                              long, "Etihad", "one two three four five"])
        XCTAssertEqual(terms, ["Etihad", "C2 Pharma", "one two three four five"])
        XCTAssertEqual(Glossary.keyterms(from: (0..<1200).map { "t\($0)" }).count, 1000)
    }

    func testFormFieldsRepeatKeyterms() {
        let fields = ElevenLabsProvider.formFields(
            model: "scribe_v2",
            options: TranscriptionOptions(languageCode: "en", keyterms: ["Etihad", "C2 Pharma", "x{y}"]))
        XCTAssertEqual(fields.filter { $0.0 == "keyterms" }.map(\.1), ["Etihad", "C2 Pharma"])
        XCTAssertTrue(fields.contains { $0.0 == "language_code" && $0.1 == "en" })
        XCTAssertTrue(fields.contains { $0.0 == "model_id" && $0.1 == "scribe_v2" })
        // 沒有詞庫時不送 keyterms（避免 20% 加價）
        let none = ElevenLabsProvider.formFields(model: "scribe_v2", options: TranscriptionOptions())
        XCTAssertFalse(none.contains { $0.0 == "keyterms" })
    }

    func testMultipartBodyContainsRepeatedFields() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mp-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let body = try Multipart.body(boundary: "B", fields: [("keyterms", "A"), ("keyterms", "B")],
                                      fileField: "file", fileURL: url)
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(s.components(separatedBy: "name=\"keyterms\"").count - 1, 2)
        XCTAssertTrue(s.hasSuffix("--B--\r\n"))
    }

    // MARK: - 說話者名稱

    func testDisplayName() {
        var t = Transcript(languageCode: nil, segments: [
            .init(start: 0, end: 1, speaker: "speaker_0", text: "a"),
            .init(start: 1, end: 2, speaker: "speaker_1", text: "b"),
            .init(start: 2, end: 3, speaker: nil, text: "c"),
        ], engine: "test")
        XCTAssertEqual(t.displayName("speaker_0"), "speaker_0")
        t.speakerNames = ["speaker_0": " 王經理 ", "speaker_1": "  "]
        XCTAssertEqual(t.displayName("speaker_0"), "王經理")
        XCTAssertEqual(t.displayName("speaker_1"), "speaker_1")
        XCTAssertNil(t.displayName(nil))

        let lines = NoteGenerator.transcriptLines(t)
        XCTAssertEqual(lines, ["[00:00:00] 王經理：a", "[00:00:01] speaker_1：b", "[00:00:02] c"])
        XCTAssertTrue(TranscriptExporter.markdown(title: "x", transcript: t).contains("**[00:00:00] 王經理**：a"))
    }

    func testSpeakerNamesCleaned() {
        XCTAssertEqual(SpeakerNamesEditor.cleaned(["a": " 王 ", "b": "", "c": "  "]), ["a": "王"])
    }

    func testOldTranscriptJSONStillDecodes() throws {
        // v0.7 之前存的逐字稿沒有 speakerNames / postProcessing
        let old = #"{"languageCode":"eng","segments":[{"start":0,"end":1,"speaker":"speaker_0","text":"hi"}],"engine":"elevenlabs"}"#
        let t = try JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        XCTAssertNil(t.speakerNames)
        XCTAssertEqual(t.displayName("speaker_0"), "speaker_0")
    }

    // MARK: - 錄音日期

    func testNoteDatePrefersRecordedAt() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let recorded = Date(timeIntervalSince1970: 1_900_000_000)
        var item = RecordingItem(id: UUID(), title: "t", fileName: "f.m4a", createdAt: created, source: .imported)
        XCTAssertEqual(item.noteDate, created)
        item.recordedAt = recorded
        XCTAssertEqual(item.noteDate, recorded)
    }

    @MainActor
    func testRecordingInfoManualOverrideAndRemark() {
        // 用獨立的暫存清單檔，不動到真正的資料
        let lib = RecordingLibrary(indexURL: FileManager.default.temporaryDirectory
            .appending(path: "lib-\(UUID().uuidString).json"))
        let id = UUID()
        lib.add(RecordingItem(id: id, title: "t", fileName: "none.m4a", createdAt: .now, source: .imported))
        defer { if let it = lib.item(id: id) { lib.delete(it) } }
        let manual = Date(timeIntervalSince1970: 1_789_000_000)
        lib.updateInfo(id: id, recordedAt: manual, remark: "實際錄音 9/28")
        // 自動偵測不可覆蓋手動設定
        lib.setRecordedAt(Date(timeIntervalSince1970: 1_790_000_000), for: id)
        XCTAssertEqual(lib.item(id: id)?.noteDate, manual)
        XCTAssertEqual(lib.item(id: id)?.recordedAtIsManual, true)
        XCTAssertEqual(lib.item(id: id)?.trimmedRemark, "實際錄音 9/28")
    }

    func testRemarkGoesIntoPrompt() {
        let values = ["output_language": "繁體中文（台灣）", "glossary": "", "remark": "實際錄音 9/28"]
        let p = NoteGenerator.finalPrompt(instructions: "X", values: values, body: "B")
        XCTAssertTrue(p.contains("錄音備註（使用者提供，可作為背景資訊，優先於逐字稿推測）：實際錄音 9/28"))
        XCTAssertFalse(NoteGenerator.finalPrompt(instructions: "X", values: ["remark": ""], body: "B").contains("錄音備註"))
        let t = NoteTemplate(id: UUID(), name: "x", prompt: "備註：{{remark}}", isBuiltIn: false)
        XCTAssertEqual(t.render(["remark": "9/28"]), "備註：9/28")
    }

    func testOldRecordingItemJSONStillDecodes() throws {
        let old = #"{"id":"6B0F2E0A-0001-4000-8000-000000000009","title":"t","fileName":"f.m4a","createdAt":0,"source":"imported"}"#
        let item = try JSONDecoder().decode(RecordingItem.self, from: Data(old.utf8))
        XCTAssertNil(item.recordedAt)
        XCTAssertNil(item.remark)
        XCTAssertNil(item.recordedAtIsManual)
        XCTAssertEqual(item.noteDate, item.createdAt)
    }

    func testAudioMetadataReadsContainerCreationDate() async throws {
        // AVURLAsset.creationDate 讀的是音檔容器（mvhd）記錄的建立時間。
        // AVAssetWriter 會把它設成寫檔當下，所以預期讀回「寫檔時間」。
        // （2026-09-30 CI 實測：自訂的 QuickTime creationDate metadata 項目不會被 m4a 採用。）
        let url = FileManager.default.temporaryDirectory.appending(path: "meta-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = Date()
        try await TestAudio.writeSilentM4A(to: url, creationDate: Date(timeIntervalSince1970: 1_790_000_000))
        let read = await AudioMetadata.creationDate(of: url)
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 60)
    }
}
