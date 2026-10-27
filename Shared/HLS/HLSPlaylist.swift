import Foundation

/// m3u8 プレイリストの最小パーサ。
///
/// 対応するのは VOD の基本形のみ。ライブ(EXT-X-ENDLIST なし)、
/// 暗号化(EXT-X-KEY)、バイトレンジ指定(EXT-X-BYTERANGE)は扱わない。
enum HLSPlaylist {

    /// マスタープレイリストの 1 画質
    struct Variant {
        let url: URL
        let bandwidth: Int
        let height: Int?
        /// EXT-X-STREAM-INF の AUDIO=。音声が別プレイリストに分離されている場合に入る
        let audioGroupID: String?
    }

    /// EXT-X-MEDIA で宣言された音声レンディション
    struct Rendition {
        let groupID: String
        let url: URL
        let isDefault: Bool
    }

    /// セグメント一覧を持つメディアプレイリスト
    struct Media {
        /// EXT-X-MAP:URI。fMP4 の初期化セグメントで、先頭に連結する必要がある
        let initSegment: URL?
        let segments: [URL]
        /// EXT-X-KEY で METHOD=NONE 以外が指定されているか
        let isEncrypted: Bool
        /// EXT-X-ENDLIST がない = ライブ配信
        let isLive: Bool
    }

    static func isMaster(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    /// マスタープレイリストから画質一覧を読む
    static func variants(in text: String, baseURL: URL) -> [Variant] {
        var result: [Variant] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            let attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            // 属性行の次に来る最初の非コメント行が URI
            var uriIndex = index + 1
            while uriIndex < lines.count {
                let candidate = lines[uriIndex].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty && !candidate.hasPrefix("#") { break }
                uriIndex += 1
            }
            if uriIndex < lines.count,
               let url = resolve(lines[uriIndex].trimmingCharacters(in: .whitespaces), against: baseURL) {
                result.append(
                    Variant(
                        url: url,
                        bandwidth: attributes["BANDWIDTH"].flatMap { Int($0) } ?? 0,
                        height: attributes["RESOLUTION"]
                            .flatMap { $0.split(separator: "x").last }
                            .flatMap { Int($0) },
                        audioGroupID: attributes["AUDIO"]
                    )
                )
            }
            index = uriIndex + 1
        }
        return result
    }

    /// マスタープレイリストから音声レンディションを読む
    static func audioRenditions(in text: String, baseURL: URL) -> [Rendition] {
        var result: [Rendition] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attributes["TYPE"] == "AUDIO",
                  let groupID = attributes["GROUP-ID"],
                  // URI を持たないレンディションは多重化済み(映像と同じセグメントに入っている)
                  let uri = attributes["URI"],
                  let url = resolve(uri, against: baseURL) else {
                continue
            }
            result.append(
                Rendition(groupID: groupID, url: url, isDefault: attributes["DEFAULT"] == "YES")
            )
        }
        return result
    }

    /// メディアプレイリストからセグメント一覧を読む
    static func media(in text: String, baseURL: URL) -> Media {
        var initSegment: URL?
        var segments: [URL] = []
        var isEncrypted = false
        var isLive = true

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                if let method = attributes["METHOD"], method != "NONE" {
                    isEncrypted = true
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                initSegment = attributes["URI"].flatMap { resolve($0, against: baseURL) }
            } else if line == "#EXT-X-ENDLIST" {
                isLive = false
            } else if !line.hasPrefix("#") {
                if let url = resolve(line, against: baseURL) {
                    segments.append(url)
                }
            }
        }
        return Media(initSegment: initSegment, segments: segments, isEncrypted: isEncrypted, isLive: isLive)
    }

    // MARK: - Helpers

    /// `KEY=VALUE,KEY="VALUE,WITH,COMMAS"` 形式の属性リストを辞書にする
    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false

        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty {
                result[trimmedKey] = value.trimmingCharacters(in: .whitespaces)
            }
            key = ""
            value = ""
            readingKey = true
        }

        for character in text {
            if inQuotes {
                if character == "\"" {
                    inQuotes = false
                } else {
                    value.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "=" && readingKey {
                readingKey = false
            } else if character == "," {
                commit()
            } else if readingKey {
                key.append(character)
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }

    private static func resolve(_ uri: String, against baseURL: URL) -> URL? {
        guard !uri.isEmpty else { return nil }
        return URL(string: uri, relativeTo: baseURL)?.absoluteURL
    }
}
