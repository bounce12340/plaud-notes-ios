import Foundation

/// 最小 ZIP 寫入器，只用 stored（不壓縮），足以產生 .docx。
/// 不引入第三方套件；筆記與逐字稿只有數百 KB，不壓縮也無妨。
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    /// 固定時間 1980-01-01 00:00（ZIP 最早可表示的日期），讓同樣內容產生同樣的檔案
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

    mutating func add(path: String, contents: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        let size = UInt32(contents.count)
        let offset = UInt32(body.count)

        // Local file header
        body.append(le32: 0x0403_4B50)
        body.append(le16: 20)              // version needed
        body.append(le16: 0)               // flags
        body.append(le16: 0)               // method: stored
        body.append(le16: Self.dosTime)
        body.append(le16: Self.dosDate)
        body.append(le32: crc)
        body.append(le32: size)            // compressed
        body.append(le32: size)            // uncompressed
        body.append(le16: UInt16(name.count))
        body.append(le16: 0)               // extra length
        body.append(name)
        body.append(contents)

        // Central directory entry
        central.append(le32: 0x0201_4B50)
        central.append(le16: 20)           // version made by
        central.append(le16: 20)           // version needed
        central.append(le16: 0)
        central.append(le16: 0)
        central.append(le16: Self.dosTime)
        central.append(le16: Self.dosDate)
        central.append(le32: crc)
        central.append(le32: size)
        central.append(le32: size)
        central.append(le16: UInt16(name.count))
        central.append(le16: 0)            // extra length
        central.append(le16: 0)            // comment length
        central.append(le16: 0)            // disk number
        central.append(le16: 0)            // internal attributes
        central.append(le32: 0)            // external attributes
        central.append(le32: offset)
        central.append(name)
        count += 1
    }

    func finalize() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: count)
        out.append(le16: count)
        out.append(le32: UInt32(central.count))
        out.append(le32: cdOffset)
        out.append(le16: 0)                // comment length
        return out
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
