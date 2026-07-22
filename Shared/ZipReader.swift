import Compression
import Foundation

/// 最小限の ZIP 読み取り。中央ディレクトリを走査し、格納(無圧縮)/ deflate の
/// エントリを展開する。pixiv のうごイラ ZIP の展開だけを目的とした軽量実装で、
/// 暗号化・ZIP64・分割アーカイブなどには対応しない。
enum ZipReader {

    /// ZIP バイト列を { エントリ名: 中身 } に展開して返す
    static func entries(in data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)

        guard let eocd = findEOCD(bytes) else { throw UgoiraError.badZip }
        let entryCount = readU16(bytes, eocd + 10)
        var offset = readU32(bytes, eocd + 16) // 中央ディレクトリの開始位置

        var result: [String: Data] = [:]
        for _ in 0..<entryCount {
            // 中央ディレクトリレコードのシグネチャ
            guard offset + 46 <= bytes.count, readU32(bytes, offset) == 0x02014b50 else { break }

            let method = readU16(bytes, offset + 10)
            let compSize = readU32(bytes, offset + 20)
            let uncompSize = readU32(bytes, offset + 24)
            let nameLen = readU16(bytes, offset + 28)
            let extraLen = readU16(bytes, offset + 30)
            let commentLen = readU16(bytes, offset + 32)
            let localOffset = readU32(bytes, offset + 42)

            let nameStart = offset + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<nameStart + nameLen], encoding: .utf8) ?? ""

            // ローカルヘッダから実データの開始位置を求める(名前・extra 長はローカル側を使う)
            if localOffset + 30 <= bytes.count, readU32(bytes, localOffset) == 0x04034b50 {
                let localNameLen = readU16(bytes, localOffset + 26)
                let localExtraLen = readU16(bytes, localOffset + 28)
                let dataStart = localOffset + 30 + localNameLen + localExtraLen

                if dataStart + compSize <= bytes.count, !name.isEmpty, !name.hasSuffix("/") {
                    let compressed = bytes[dataStart..<dataStart + compSize]
                    if method == 0 {
                        result[name] = Data(compressed)
                    } else if method == 8 {
                        result[name] = try inflate(Array(compressed), expectedSize: uncompSize)
                    }
                }
            }

            offset = nameStart + nameLen + extraLen + commentLen
        }

        guard !result.isEmpty else { throw UgoiraError.badZip }
        return result
    }

    /// 末尾から End Of Central Directory レコード(0x06054b50)を探す
    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var p = bytes.count - 22
        // コメントは最大 65535 バイト。それより前は見ない
        let limit = max(0, bytes.count - 22 - 0xFFFF)
        while p >= limit {
            if readU32(bytes, p) == 0x06054b50 { return p }
            p -= 1
        }
        return nil
    }

    /// 生 deflate を展開する(Apple の COMPRESSION_ZLIB はヘッダ無しの raw deflate)
    private static func inflate(_ compressed: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destination.deallocate() }

        let written = compressed.withUnsafeBufferPointer { src in
            compression_decode_buffer(
                destination, expectedSize,
                src.baseAddress!, compressed.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { throw UgoiraError.badZip }
        return Data(bytes: destination, count: written)
    }

    // MARK: - リトルエンディアン読み取り

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
    }
}
