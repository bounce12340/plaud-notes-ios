import Foundation

enum TranscriptExporter {
    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// 逐字稿 Markdown：每段附時間戳與說話者。
    static func markdown(title: String, transcript: Transcript) -> String {
        var out = "# \(title)\n\n"
        out += "- 轉錄引擎：\(transcript.engine)\n"
        if let lang = transcript.languageCode { out += "- 語言：\(lang)\n" }
        out += "\n## 逐字稿\n\n"
        for s in transcript.segments {
            let who = s.speaker.map { " \($0)" } ?? ""
            out += "**[\(timestamp(s.start))]\(who)**：\(s.text.trimmingCharacters(in: .whitespaces))\n\n"
        }
        return out
    }
}
