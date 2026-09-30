import Foundation

/// 簡體 → 台灣繁體（OpenCC 1.4.2 `s2tw` / `s2twp` 的 Swift 移植）。
///
/// 流程（與 OpenCC 設定檔 s2tw.json / s2twp.json 相同）：
/// 1. 正規化：CJK 相容表意字
/// 2. 斷詞：以 STPhrases ∪ STPhrases_GeneratedFromRegionalPhrases 做最長匹配
/// 3. 每個片段依序套用轉換鏈；每一步都是「最長前綴匹配，找不到就原樣輸出一個 code point」
///    - 第 1 步：(STPhrases ∪ Generated) → STCharacters（short-circuit）
///    - 第 2 步：s2twp = TWPhrases → TWVariantsPhrases → TWVariants；s2tw 不含 TWPhrases
///
/// 以 Unicode scalar（code point）為單位比對，與 OpenCC 一致；刻意不用 Swift `String` 當字典鍵，
/// 因為 `String` 相等採 Unicode 正規等價，會把相容表意字和一般漢字視為相同。
///
/// 注意：輸入已是繁體時大多不變，但「台」會轉成「臺」（OpenCC 行為）；
/// s2twp 會把「文件」轉成「檔案」、「软件」轉成「軟體」，會議內容容易誤轉，所以 App 預設用 s2tw。
public final class ChineseConverter: @unchecked Sendable {
    public enum Mode: String, Sendable, CaseIterable, Codable {
        /// 只轉字形（簡→繁、台灣異體字）
        case s2tw
        /// 字形＋台灣慣用詞（软件→軟體、服务器→伺服器）
        case s2twp
    }

    public let mode: Mode

    private let normalization: Matcher
    private let segmentation: Matcher
    private let chain: [Matcher]

    /// 從 bundle 載入字典（先找 `OpenCC/` 子資料夾，再找 bundle 根目錄）。
    public convenience init(mode: Mode, bundle: Bundle = .main) throws {
        try self.init(mode: mode) { name in
            guard let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "OpenCC")
                    ?? bundle.url(forResource: name, withExtension: "txt") else {
                throw ConverterError.missingDictionary(name)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// 以自訂的讀檔函式載入字典。
    public init(mode: Mode, loader: (String) throws -> String) throws {
        self.mode = mode
        func dict(_ name: String) throws -> Matcher { .lexicon(Lexicon.parse(try loader(name))) }

        normalization = try dict("CJK_Compatibility_Ideographs")
        let stPhrases = Matcher.union([try dict("STPhrases"),
                                       try dict("STPhrases_GeneratedFromRegionalPhrases")])
        segmentation = stPhrases
        let step1 = Matcher.shortCircuit([stPhrases, try dict("STCharacters")])
        var twDicts: [Matcher] = []
        if mode == .s2twp { twDicts.append(try dict("TWPhrases")) }
        twDicts.append(try dict("TWVariantsPhrases"))
        twDicts.append(try dict("TWVariants"))
        chain = [step1, .shortCircuit(twDicts)]
    }

    public func convert(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let normalized = Self.apply(normalization, to: Array(text.unicodeScalars))
        var out = String.UnicodeScalarView()
        for segment in Self.segment(normalized, with: segmentation) {
            var scalars = segment
            for step in chain { scalars = Self.apply(step, to: scalars) }
            out.append(contentsOf: scalars)
        }
        return String(out)
    }

    // MARK: - 演算法

    typealias Scalars = [Unicode.Scalar]

    private static func apply(_ m: Matcher, to s: Scalars) -> Scalars {
        var out = Scalars()
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if let hit = m.match(s, at: i) {
                out.append(contentsOf: hit.value)
                i += hit.length
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    private static func segment(_ s: Scalars, with m: Matcher) -> [Scalars] {
        var segments: [Scalars] = []
        var buffer = Scalars()
        var i = 0
        while i < s.count {
            if let hit = m.match(s, at: i) {
                if !buffer.isEmpty { segments.append(buffer); buffer = [] }
                segments.append(Array(s[i..<(i + hit.length)]))
                i += hit.length
            } else {
                buffer.append(s[i])
                i += 1
            }
        }
        if !buffer.isEmpty { segments.append(buffer) }
        return segments
    }

    struct Hit {
        let length: Int
        let value: Scalars
    }

    /// 單一字典：鍵 → 第一個候選值
    struct Lexicon {
        let map: [Scalars: Scalars]
        let maxKeyLength: Int
        let firstScalars: Set<Unicode.Scalar>

        static func parse(_ text: String) -> Lexicon {
            var map: [Scalars: Scalars] = [:]
            var maxLen = 0
            var first = Set<Unicode.Scalar>()
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#") { continue }
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2,
                      let value = parts[1].split(separator: " ").first else { continue }
                let key = Array(parts[0].unicodeScalars)
                guard let f = key.first, map[key] == nil else { continue }
                map[key] = Array(value.unicodeScalars)
                maxLen = max(maxLen, key.count)
                first.insert(f)
            }
            return Lexicon(map: map, maxKeyLength: maxLen, firstScalars: first)
        }

        func match(_ s: Scalars, at i: Int) -> Hit? {
            guard firstScalars.contains(s[i]) else { return nil }
            var len = min(maxKeyLength, s.count - i)
            while len > 0 {
                if let v = map[Array(s[i..<(i + len)])] { return Hit(length: len, value: v) }
                len -= 1
            }
            return nil
        }
    }

    enum Matcher {
        case lexicon(Lexicon)
        /// 取所有字典中最長的匹配（長度相同時取前者）
        case union([Matcher])
        /// 依序找，第一個有匹配的字典就用它
        case shortCircuit([Matcher])

        func match(_ s: Scalars, at i: Int) -> Hit? {
            switch self {
            case .lexicon(let d):
                return d.match(s, at: i)
            case .union(let ms):
                var best: Hit?
                for m in ms {
                    if let h = m.match(s, at: i), h.length > (best?.length ?? 0) { best = h }
                }
                return best
            case .shortCircuit(let ms):
                for m in ms {
                    if let h = m.match(s, at: i) { return h }
                }
                return nil
            }
        }
    }

    public enum ConverterError: LocalizedError {
        case missingDictionary(String)

        public var errorDescription: String? {
            switch self {
            case .missingDictionary(let n): "找不到 OpenCC 字典：\(n).txt"
            }
        }
    }
}

/// App 內共用的轉換器。第一次使用時在背景載入約 1 MB 字典，之後重複使用。
actor ChineseConverterCache {
    static let shared = ChineseConverterCache()
    private var cache: [ChineseConverter.Mode: ChineseConverter] = [:]

    func converter(_ mode: ChineseConverter.Mode) -> ChineseConverter? {
        if let c = cache[mode] { return c }
        guard let c = try? ChineseConverter(mode: mode) else { return nil }
        cache[mode] = c
        return c
    }
}
