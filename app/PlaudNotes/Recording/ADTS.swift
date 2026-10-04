import Foundation

/// AAC ADTS（.aac）檔的掃描與接合。
///
/// 錄音用 ADTS 而不是 M4A：M4A 要等停止錄音時才寫入索引（moov），App 中途被終止整個檔案會打不開；
/// ADTS 每一格都有自己的標頭，寫到哪裡就能讀到哪裡，而且多段直接頭尾相接仍是合法檔案。
/// 中途被終止時，最後一格可能只寫了一半，掃描到不完整的格就停，之後的位元組捨棄。
enum ADTS {
    struct Scan: Equatable {
        /// 完整格子的總位元組數（之後的不完整資料要捨棄）
        var validBytes: Int
        var frames: Int
        var samples: Int
        var sampleRate: Double

        var duration: Double { sampleRate > 0 ? Double(samples) / sampleRate : 0 }
    }

    static let sampleRates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                                        22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    struct Header: Equatable {
        var frameLength: Int
        var sampleRate: Double
        var samples: Int
    }

    /// 解析 7 位元組的 ADTS 標頭；不是合法標頭就回傳 nil
    static func header<C: RandomAccessCollection>(_ b: C) -> Header? where C.Element == UInt8, C.Index == Int {
        guard b.count >= 7 else { return nil }
        let s = b.startIndex
        // syncword 0xFFF、layer 必須是 0
        guard b[s] == 0xFF, b[s + 1] & 0xF6 == 0xF0 else { return nil }
        let rateIndex = Int((b[s + 2] >> 2) & 0x0F)
        guard rateIndex < sampleRates.count else { return nil }
        let length = (Int(b[s + 3] & 0x03) << 11) | (Int(b[s + 4]) << 3) | (Int(b[s + 5]) >> 5)
        let protectionAbsent = b[s + 1] & 0x01 == 1
        guard length >= (protectionAbsent ? 7 : 9) else { return nil }
        let blocks = Int(b[s + 6] & 0x03) + 1
        return Header(frameLength: length, sampleRate: sampleRates[rateIndex], samples: blocks * 1024)
    }

    static func scan(_ data: Data) -> Scan {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result = Scan(validBytes: 0, frames: 0, samples: 0, sampleRate: 0)
            var offset = 0
            while offset + 7 <= bytes.count,
                  let h = header(bytes[offset..<(offset + 7)]),
                  offset + h.frameLength <= bytes.count {
                offset += h.frameLength
                result.frames += 1
                result.samples += h.samples
                if result.sampleRate == 0 { result.sampleRate = h.sampleRate }
            }
            result.validBytes = offset
            return result
        }
    }

    static func scan(_ url: URL) throws -> Scan {
        // 以記憶體對應讀取，3 小時（約 86 MB）的檔案也不會整個載入記憶體
        try scan(Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// 把各段的完整格子依序寫到 `destination`。回傳合併後的掃描結果。
    @discardableResult
    static func concatenate(_ parts: [URL], into destination: URL, chunkSize: Int = 1 << 20) throws -> Scan {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var total = Scan(validBytes: 0, frames: 0, samples: 0, sampleRate: 0)
        for part in parts {
            let s = try scan(part)
            guard s.validBytes > 0 else { continue }
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            var remaining = s.validBytes
            while remaining > 0, let chunk = try input.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            total.validBytes += s.validBytes
            total.frames += s.frames
            // 各段取樣率相同（錄音設定固定），以第一段為準
            if total.sampleRate == 0 { total.sampleRate = s.sampleRate }
            total.samples += s.samples
        }
        return total
    }
}
