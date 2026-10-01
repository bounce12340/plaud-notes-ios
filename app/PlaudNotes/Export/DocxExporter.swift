import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Markdown（LLM 筆記、逐字稿）轉成 Word .docx（Office Open XML）。
///
/// 支援：標題、段落、項目／編號清單（含巢狀、核取方塊）、表格、引言、分隔線、程式碼區塊；
/// 行內粗體、斜體、程式碼、連結、`<br>`。
/// 清單不用 Word 自動編號，而是以「•」或原本的編號文字加凸排，保留 LLM 寫的編號不被重排。
/// 中日韓字型：東亞字型設 Microsoft JhengHei、語言 zh-TW；沒有該字型的環境（Pages）會自動替代。
enum DocxExporter {
    static func document(title: String, markdown: String, created: Date = .now) -> Data {
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", contents: Data(contentTypes.utf8))
        zip.add(path: "_rels/.rels", contents: Data(rootRels.utf8))
        zip.add(path: "docProps/core.xml", contents: Data(coreXML(title: title, created: created).utf8))
        zip.add(path: "word/_rels/document.xml.rels", contents: Data(documentRels.utf8))
        zip.add(path: "word/styles.xml", contents: Data(styles.utf8))
        zip.add(path: "word/document.xml", contents: Data(documentXML(markdown: markdown).utf8))
        return zip.finalize()
    }

    static func documentXML(markdown: String) -> String {
        xmlHeader
            + #"<w:document xmlns:w="\#(wNS)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>"#
            + bodyXML(markdown)
            // A4、邊界 2.54 cm
            + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>"#
            + "</w:body></w:document>"
    }

    // MARK: - 區塊

    static func bodyXML(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out = ""
        var para: [String] = []
        var endsWithTable = false
        func emit(_ xml: String, table: Bool = false) { out += xml; endsWithTable = table }
        func flush() {
            if !para.isEmpty { emit(paragraph(lines: para)); para = [] }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }

            if trimmed.hasPrefix("```") {
                flush(); i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // 結尾的 ```（沒有就到檔尾）
                emit(codeBlock(code))
                continue
            }
            if let h = heading(trimmed) {
                flush(); emit(paragraph(style: "Heading\(h.level)", content: inline(h.text))); i += 1; continue
            }
            if isRule(trimmed) {
                flush()
                emit(#"<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="auto"/></w:pBdr></w:pPr></w:p>"#)
                i += 1; continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                var rows = [cells(trimmed)]
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row)); i += 1
                }
                emit(table(rows), table: true)
                continue
            }
            if let item = listItem(line) {
                flush(); emit(listParagraph(item)); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                emit(paragraph(lines: quote, style: "Quote"))
                continue
            }
            para.append(trimmed)
            i += 1
        }
        flush()
        // Word 要求表格後面還有段落，否則部分版本會判定檔案損毀
        if endsWithTable { out += "<w:p/>" }
        return out
    }

    private static func paragraph(style: String? = nil, properties: String = "", content: String) -> String {
        let styleXML = style.map { #"<w:pStyle w:val="\#($0)"/>"# } ?? ""
        let pPr = styleXML + properties
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + content + "</w:p>"
    }

    /// 連續的文字行合成一段，行與行之間換行（中文不能像英文 Markdown 那樣以空白相接）。
    private static func paragraph(lines: [String], style: String? = nil) -> String {
        paragraph(style: style, content: lines.map { inline($0) }.joined(separator: lineBreak))
    }

    private static func codeBlock(_ lines: [String]) -> String {
        paragraph(style: "Code", content: lines.map { run($0, .init()) }.joined(separator: lineBreak))
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // 去掉結尾的 #（ATX 收尾寫法）
        while text.hasSuffix("#") { text.removeLast() }
        return (min(hashes, 4), text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    // MARK: - 清單

    struct ListItem: Equatable {
        var level: Int
        var marker: String
        var text: String
    }

    static func listItem(_ line: String) -> ListItem? {
        var indent = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            indent += c == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        let level = min(indent / 2, 3)
        var marker: String
        if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " " {
            marker = "•"
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, let p = after.first, p == "." || p == ")",
                  after.dropFirst().first == " " else { return nil }
            marker = "\(digits)\(p)"
            rest = after.dropFirst(2)
        }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if marker == "•" {
            if text.hasPrefix("[ ] ") || text == "[ ]" {
                marker = "☐"; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" {
                marker = "☑"; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ListItem(level: level, marker: marker, text: text)
    }

    private static func listParagraph(_ item: ListItem) -> String {
        // 凸排：編號在左、內文對齊；Word 會把凸排位置當成第一個定位點
        let left = 420 * (item.level + 1)
        let props = #"<w:spacing w:after="60"/><w:ind w:left="\#(left)" w:hanging="420"/>"#
        return paragraph(properties: props,
                         content: run(item.marker, .init()) + "<w:r><w:tab/></w:r>" + inline(item.text))
    }

    // MARK: - 表格

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    /// `| a | b \| c |` → ["a", "b | c"]
    static func cells(_ row: String) -> [String] {
        var body = Substring(row.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for c in body {
            if escaped {
                if c != "|" { current.append("\\") }
                current.append(c); escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func table(_ rows: [[String]]) -> String {
        let columns = max(rows.map(\.count).max() ?? 1, 1)
        let width = 9026 / columns // A4 寬 11906 − 左右邊界 2×1440
        var xml = #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="5000" w:type="pct"/></w:tblPr><w:tblGrid>"#
        xml += String(repeating: #"<w:gridCol w:w="\#(width)"/>"#, count: columns)
        xml += "</w:tblGrid>"
        for (r, row) in rows.enumerated() {
            let header = r == 0
            xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for c in 0..<columns {
                let text = c < row.count ? row[c] : ""
                xml += #"<w:tc><w:tcPr><w:tcW w:w="\#(width)" w:type="dxa"/></w:tcPr>"#
                xml += paragraph(content: inline(text, InlineStyle(bold: header)))
                xml += "</w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    // MARK: - 行內格式

    struct InlineStyle {
        var bold = false
        var italic = false
        var code = false
    }

    private static let lineBreak = "<w:r><w:br/></w:r>"

    static func inline(_ text: String, _ style: InlineStyle = .init()) -> String {
        let c = Array(text)
        var out = ""
        var buffer = ""
        func flush() { if !buffer.isEmpty { out += run(buffer, style); buffer = "" } }

        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, "\\`*_[]()#+-.!|<>~".contains(c[i + 1]) {
                buffer.append(c[i + 1]); i += 2; continue
            }
            if ch == "`", let j = find(["`"], in: c, from: i + 1), j > i + 1 {
                flush()
                var s = style; s.code = true
                out += run(String(c[(i + 1)..<j]), s)
                i = j + 1; continue
            }
            if ch == "*", i + 1 < c.count, c[i + 1] == "*",
               let j = find(["*", "*"], in: c, from: i + 2), j > i + 2 {
                flush()
                var s = style; s.bold = true
                out += inline(String(c[(i + 2)..<j]), s)
                i = j + 2; continue
            }
            // 單一 * 斜體：開頭後面不能是空白（避免把「3 * 4」當斜體），結尾前面不能是空白
            if ch == "*", i + 1 < c.count, c[i + 1] != " ", c[i + 1] != "*",
               let j = closingStar(in: c, from: i + 1) {
                flush()
                var s = style; s.italic = true
                out += inline(String(c[(i + 1)..<j]), s)
                i = j + 1; continue
            }
            if ch == "[", let close = find(["]"], in: c, from: i + 1), close + 1 < c.count, c[close + 1] == "(",
               let paren = find([")"], in: c, from: close + 2) {
                flush()
                let label = String(c[(i + 1)..<close])
                let url = String(c[(close + 2)..<paren]).trimmingCharacters(in: .whitespaces)
                out += inline(label, style)
                if !url.isEmpty, url != label { out += run(" (\(url))", style) }
                i = paren + 1; continue
            }
            if ch == "<", let len = lineBreakTag(in: c, at: i) {
                flush(); out += lineBreak; i += len; continue
            }
            buffer.append(ch)
            i += 1
        }
        flush()
        return out
    }

    private static func find(_ pattern: [Character], in c: [Character], from start: Int) -> Int? {
        guard start <= c.count - pattern.count else { return nil }
        for j in start...(c.count - pattern.count) where Array(c[j..<(j + pattern.count)]) == pattern {
            return j
        }
        return nil
    }

    private static func closingStar(in c: [Character], from start: Int) -> Int? {
        var j = start + 1
        while j < c.count {
            if c[j] == "*" {
                if j + 1 < c.count, c[j + 1] == "*" { j += 2; continue } // 跳過內層的 **
                if c[j - 1] != " " { return j }
            }
            j += 1
        }
        return nil
    }

    /// `<br>`、`<br/>`、`<br />`（LLM 常在表格儲存格裡用）；回傳標籤長度
    private static func lineBreakTag(in c: [Character], at i: Int) -> Int? {
        for tag in ["<br>", "<br/>", "<br />"] {
            let t = Array(tag)
            if i + t.count <= c.count, String(c[i..<(i + t.count)]).lowercased() == tag { return t.count }
        }
        return nil
    }

    private static func run(_ text: String, _ style: InlineStyle) -> String {
        var rPr = ""
        if style.code { rPr += #"<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>"# }
        if style.bold { rPr += "<w:b/>" }
        if style.italic { rPr += "<w:i/>" }
        let head = "<w:r>" + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")
        // Tab 要用 <w:tab/>，寫在 <w:t> 裡 Word 會當成空白
        return text.components(separatedBy: "\t").map { part in
            part.isEmpty ? "" : #"<w:t xml:space="preserve">\#(escape(part))</w:t>"#
        }.joined(separator: "<w:tab/>").wrapped(head, "</w:r>")
    }

    /// XML 跳脫，並移除 XML 1.0 不允許的控制字元（否則 Word 會拒絕開啟）。
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    // MARK: - 套件中的固定檔案

    private static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let wNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private static let contentTypes = xmlHeader + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    private static let rootRels = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    private static let documentRels = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    </Relationships>
    """

    private static func coreXML(title: String, created: Date) -> String {
        let stamp = created.formatted(.iso8601)
        return xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    private static func headingStyle(_ level: Int, size: Int) -> String {
        #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="heading \#(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>"#
            + #"<w:pPr><w:keepNext/><w:spacing w:before="\#(level == 1 ? 360 : 240)" w:after="120"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr>"#
            + #"<w:rPr><w:b/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
    }

    private static let borders = ["top", "left", "bottom", "right", "insideH", "insideV"]
        .map { #"<w:\#($0) w:val="single" w:sz="4" w:space="0" w:color="auto"/>"# }.joined()

    // 用陣列組合，避免一長串 + 讓型別檢查變慢
    private static let styles = [
        xmlHeader,
        #"<w:styles xmlns:w="\#(wNS)">"#,
        #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Microsoft JhengHei" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-TW"/></w:rPr></w:rPrDefault>"#,
        #"<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#,
        #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#,
        headingStyle(1, size: 32) + headingStyle(2, size: 28) + headingStyle(3, size: 24) + headingStyle(4, size: 22),
        #"<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="A0A0A0"/></w:pBdr><w:ind w:left="360"/></w:pPr><w:rPr><w:color w:val="595959"/></w:rPr></w:style>"#,
        #"<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/><w:spacing w:after="120" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>"#,
        #"<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>"#,
        #"<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="59"/><w:pPr><w:spacing w:before="40" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders>\#(borders)</w:tblBorders></w:tblPr></w:style>"#,
        "</w:styles>",
    ].joined()
}

private extension String {
    func wrapped(_ head: String, _ tail: String) -> String { head + self + tail }
}

// MARK: - 分享

extension UTType {
    static let docx = UTType(filenameExtension: "docx") ?? .data
}

/// 分享時才產生 .docx 暫存檔（ShareLink 用）。
struct DocxFile: Transferable {
    let fileName: String
    let title: String
    let markdown: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .docx) { file in
            // 每次放在獨立資料夾，同名檔案不會互相覆蓋
            let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: file.fileName)
            try DocxExporter.document(title: file.title, markdown: file.markdown)
                .write(to: url, options: [.atomic, .completeFileProtection])
            return SentTransferredFile(url)
        }
    }

    /// 標題可能含「/」「:」等不能當檔名的字元
    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名.docx" : cleaned
    }
}
