import Foundation

/// 使用者設定：逐字稿要不要做簡→繁。
enum ChineseConversionSetting: String, CaseIterable, Identifiable, Sendable {
    case off
    case s2tw
    case s2twp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "不轉換"
        case .s2tw: "簡→繁（只轉字形，建議）"
        case .s2twp: "簡→繁＋台灣用語（软件→軟體；文件→檔案）"
        }
    }

    var mode: ChineseConverter.Mode? {
        switch self {
        case .off: nil
        case .s2tw: .s2tw
        case .s2twp: .s2twp
        }
    }

    static let storageKey = "chineseConversion"
}

enum TranscriptPostProcessor {
    /// 逐段轉換。只轉「含漢字、且不含日文假名或韓文」的段落，避免把日文漢字（国→國）或韓文夾雜的漢字誤轉。
    static func process(_ transcript: Transcript, with converter: ChineseConverter?) -> Transcript {
        guard let converter else { return transcript }
        var t = transcript
        t.segments = t.segments.map { seg in
            guard shouldConvert(seg.text) else { return seg }
            var s = seg
            s.text = converter.convert(seg.text)
            return s
        }
        t.postProcessing = "opencc-\(converter.mode.rawValue)"
        return t
    }

    static func shouldConvert(_ text: String) -> Bool {
        var hasHan = false
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:   // 平假名、片假名
                return false
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:   // 韓文字母、音節
                return false
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                hasHan = true
            default:
                continue
            }
        }
        return hasHan
    }
}
