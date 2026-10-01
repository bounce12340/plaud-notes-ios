import XCTest
@testable import PlaudNotes

final class DocxExporterTests: XCTestCase {
    static let sampleNotes = """
    # 會議記錄：A & B <C> 合作案

    - 日期：九月十二日
    - 與會者：王經理、speaker_2

    ## 討論摘要

    第一行
    第二行有 **粗體**、*斜體*、`code` 與 [官網](https://example.com)。
    3 * 4 * 5 不是斜體。

    1. 第一點
    2) 第二點
       - 巢狀項目

    ## 待辦事項

    | 事項 | 負責人 | 期限 |
    |---|:---:|---|
    | 寄出報價 | 王經理 | 未提及 |
    | 確認 a \\| b<br>第二行 | 未確認 |

    > 引述：日本語テキスト

    - [ ] 未完成項目
    - [x] 已完成項目

    ```
    let x = 1
    ```

    ---
    由 test-model 產生。
    """

    // MARK: - ZIP

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testZipRoundTrip() throws {
        var zip = ZipWriter()
        zip.add(path: "a.txt", contents: Data("hello".utf8))
        zip.add(path: "dir/中文.xml", contents: Data("<x>中文</x>".utf8))
        zip.add(path: "empty", contents: Data())
        let files = try unzip(zip.finalize())
        XCTAssertEqual(files["a.txt"], Data("hello".utf8))
        XCTAssertEqual(files["dir/中文.xml"], Data("<x>中文</x>".utf8))
        XCTAssertEqual(files["empty"], Data())
    }

    // MARK: - 整份文件

    func testDocumentPackageIsWellFormed() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let data = DocxExporter.document(title: "合作案 & <測試>", markdown: Self.sampleNotes, created: date)
        let files = try unzip(data)
        XCTAssertEqual(Set(files.keys), ["[Content_Types].xml", "_rels/.rels", "docProps/core.xml",
                                         "word/_rels/document.xml.rels", "word/styles.xml", "word/document.xml"])
        for (name, content) in files {
            let parser = XMLParser(data: content)
            XCTAssertTrue(parser.parse(), "\(name) 不是合法 XML：\(parser.parserError.map { "\($0)" } ?? "")")
        }
        // 同樣內容、同樣時間產生同樣的檔案
        XCTAssertEqual(data, DocxExporter.document(title: "合作案 & <測試>", markdown: Self.sampleNotes, created: date))

        let text = try XCTUnwrap(DocxText.extract(files["word/document.xml"]))
        for expected in ["會議記錄：A & B <C> 合作案", "與會者：王經理、speaker_2", "第一行\n第二行有 粗體、斜體、code 與 官網 (https://example.com)。",
                         "3 * 4 * 5 不是斜體。", "1.\t第一點", "2)\t第二點", "•\t巢狀項目", "寄出報價", "未提及",
                         "確認 a | b\n第二行", "引述：日本語テキスト", "☐\t未完成項目", "☑\t已完成項目", "let x = 1", "由 test-model 產生。"] {
            XCTAssertTrue(text.contains(expected), "找不到「\(expected)」：\n\(text)")
        }
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("```"))
        XCTAssertFalse(text.contains("|---"))

        let core = String(decoding: try XCTUnwrap(files["docProps/core.xml"]), as: UTF8.self)
        XCTAssertTrue(core.contains("<dc:title>合作案 &amp; &lt;測試&gt;</dc:title>"))

        // 給 CI 用 macOS textutil 再讀一次（見 .github/workflows/ios.yml）
        try data.write(to: URL.temporaryDirectory.appending(path: "plaudnotes-docx-sample.docx"))
    }

    func testTranscriptDocx() throws {
        let t = Transcript(languageCode: "zho", segments: [
            .init(start: 1, end: 2, speaker: "speaker_0", text: "今天討論預算。"),
            .init(start: 3725, end: 3730, speaker: "speaker_1", text: "好的。"),
        ], engine: "test", speakerNames: ["speaker_0": "王經理"])
        let md = TranscriptExporter.markdown(title: "週會", transcript: t)
        let files = try unzip(DocxExporter.document(title: "週會", markdown: md))
        let text = try XCTUnwrap(DocxText.extract(files["word/document.xml"]))
        XCTAssertTrue(text.contains("[00:00:01] 王經理：今天討論預算。"), text)
        XCTAssertTrue(text.contains("[01:02:05] speaker_1：好的。"), text)
    }

    // MARK: - 區塊與行內

    func testHeadings() {
        XCTAssertEqual(DocxExporter.heading("## 決議 ##")?.level, 2)
        XCTAssertEqual(DocxExporter.heading("## 決議 ##")?.text, "決議")
        XCTAssertEqual(DocxExporter.heading("###### 很深")?.level, 4)
        XCTAssertNil(DocxExporter.heading("#hashtag"))
        XCTAssertNil(DocxExporter.heading("####### 七個"))
        XCTAssertTrue(DocxExporter.bodyXML("# 標題").contains(#"<w:pStyle w:val="Heading1"/>"#))
    }

    func testRules() {
        XCTAssertTrue(DocxExporter.isRule("---"))
        XCTAssertTrue(DocxExporter.isRule("* * *"))
        XCTAssertFalse(DocxExporter.isRule("--"))
        XCTAssertFalse(DocxExporter.isRule("-*-"))
    }

    func testListItems() {
        typealias Item = DocxExporter.ListItem
        XCTAssertEqual(DocxExporter.listItem("- 項目"), Item(level: 0, marker: "•", text: "項目"))
        XCTAssertEqual(DocxExporter.listItem("    * 巢狀"), Item(level: 2, marker: "•", text: "巢狀"))
        XCTAssertEqual(DocxExporter.listItem("12. 第十二"), Item(level: 0, marker: "12.", text: "第十二"))
        XCTAssertEqual(DocxExporter.listItem("  - [ ] 寄出"), Item(level: 1, marker: "☐", text: "寄出"))
        XCTAssertEqual(DocxExporter.listItem("- [X] 完成"), Item(level: 0, marker: "☑", text: "完成"))
        XCTAssertNil(DocxExporter.listItem("**粗體開頭**"))
        XCTAssertNil(DocxExporter.listItem("-沒有空白"))
        XCTAssertNil(DocxExporter.listItem("3.14 是圓周率"))
    }

    func testTables() {
        XCTAssertEqual(DocxExporter.cells("| a | b \\| c |"), ["a", "b | c"])
        XCTAssertEqual(DocxExporter.cells("|只有一格|"), ["只有一格"])
        XCTAssertTrue(DocxExporter.isTableSeparator("|---|:--:| --- |"))
        XCTAssertFalse(DocxExporter.isTableSeparator("| a | b |"))

        let xml = DocxExporter.bodyXML("| A | B |\n|---|---|\n| 1 |")
        XCTAssertEqual(xml.components(separatedBy: "<w:tc>").count - 1, 4) // 短的列補空格
        XCTAssertTrue(xml.contains("<w:tblHeader/>"))
        XCTAssertTrue(xml.hasSuffix("</w:tbl><w:p/>"), "表格後要有段落")
        // 沒有分隔列就不是表格
        XCTAssertFalse(DocxExporter.bodyXML("| A | B |\n一般文字").contains("<w:tbl>"))
    }

    func testInline() {
        let styled = DocxExporter.inline("**粗** *斜* `碼`")
        XCTAssertTrue(styled.contains("<w:b/>"))
        XCTAssertTrue(styled.contains("<w:i/>"))
        XCTAssertTrue(styled.contains("Courier New"))
        XCTAssertFalse(DocxExporter.inline("3 * 4 * 5").contains("<w:i/>"))
        XCTAssertFalse(DocxExporter.inline("speaker_0 與 speaker_1").contains("<w:i/>"))
        XCTAssertFalse(DocxExporter.inline("**沒有結尾").contains("<w:b/>"))
        XCTAssertTrue(DocxExporter.inline("a<br/>b").contains("<w:br/>"))
        XCTAssertTrue(DocxExporter.inline("\\*字面星號\\*").contains(">*字面星號*<"))
        XCTAssertTrue(DocxExporter.inline("a\tb").contains("<w:tab/>"))
    }

    func testEscapeRemovesInvalidXMLCharacters() {
        XCTAssertEqual(DocxExporter.escape("a & <b> \"q\"\u{1}\u{FFFF}c"), "a &amp; &lt;b&gt; &quot;q&quot;c")
    }

    func testSafeFileName() {
        XCTAssertEqual(DocxFile.safeFileName("9/30 會議: 結論?.docx"), "9-30 會議- 結論-.docx")
        XCTAssertEqual(DocxFile.safeFileName("  "), "未命名.docx")
    }

    // MARK: - 測試輔助

    /// 最小 ZIP 讀取器（只支援 stored），用來驗證 ZipWriter 的輸出
    private func unzip(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let eocd = b.count - 22
        XCTAssertEqual(u32(eocd), 0x0605_4B50)
        let count = u16(eocd + 10)
        XCTAssertEqual(u32(eocd + 16) + u32(eocd + 12), eocd, "central directory 應緊接在 EOCD 前")
        var p = u32(eocd + 16)
        var files: [String: Data] = [:]
        for _ in 0..<count {
            XCTAssertEqual(u32(p), 0x0201_4B50)
            let method = u16(p + 10), crc = u32(p + 16), size = u32(p + 20)
            let nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            XCTAssertEqual(method, 0)
            XCTAssertEqual(u32(local), 0x0403_4B50)
            XCTAssertEqual(u32(local + 14), crc)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let content = Data(b[start..<(start + size)])
            XCTAssertEqual(UInt32(crc), CRC32.checksum(content), name)
            files[name] = content
            p += 46 + nameLength + extra + comment
        }
        return files
    }
}

/// 從 document.xml 取出純文字：<w:t> 內容、<w:tab/> → \t、<w:br/> → \n、段落結尾 → \n
private final class DocxText: NSObject, XMLParserDelegate {
    private var text = ""
    private var inText = false

    static func extract(_ data: Data?) -> String? {
        guard let data else { return nil }
        let collector = DocxText()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        return parser.parse() ? collector.text : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:t": inText = true
        case "w:tab": text += "\t"
        case "w:br": text += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "w:t" { inText = false }
        if elementName == "w:p" { text += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }
}
