import Foundation

/// 動画共有サイト (pornhub.com) の動画からメディアを抽出する。
///
/// 視聴ページに埋め込まれたプレイヤー変数 `flashvars_<id>` から `mediaDefinitions` を読む。
/// この配列には HLS の各画質と、progressive mp4 の一覧を返す `get_media` エンドポイントの
/// URL が入っている。HLS は iOS 側で結合できないため、progressive mp4 だけを使う。
///
/// 動作確認メモ (2026-07):
/// - `get_media` は視聴ページのレスポンスで発行された Cookie がないと空配列 `[]` を返す。
///   そのためページ取得とエンドポイント呼び出しを Cookie 共有の同一セッションで行う。
/// - CDN (phncdn.com) の mp4 URL は視聴ページを指す `Referer` がないと 404 になる。
///   Cookie は不要なので、ダウンロード時のヘッダには Referer だけを渡す。
/// - mp4 URL は発行から約 2 時間・要求元 IP に紐づく。抽出したらそのまま落とすこと。
struct AdultVideoExtractor: MediaExtractor {

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isSupportedHost = host == "pornhub.com" || host.hasSuffix(".pornhub.com")
        return isSupportedHost && Self.videoKey(from: url) != nil
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        guard let key = Self.videoKey(from: url),
              let pageURL = URL(string: "https://www.pornhub.com/view_video.php?viewkey=\(key)") else {
            throw ExtractError.unsupportedURL
        }

        // ページで発行された Cookie をエンドポイント呼び出しまで引き継ぐ
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let vars = try await Self.fetchPlayerVars(pageURL: pageURL, session: session)
        if vars.videoUnavailableCountry == "true" {
            throw ExtractError.apiError("この動画は地域制限により取得できません")
        }
        if vars.videoUnavailable == "true" {
            throw ExtractError.notFound
        }

        let definitions = vars.mediaDefinitions ?? []
        let mp4Definitions = definitions.filter { $0.format == "mp4" }

        // format が mp4 で quality を持たないエントリは、画質一覧を返すエンドポイント。
        // quality を持つものは直リンクなので、そのまま候補にする
        var candidates = mp4Definitions.filter { $0.quality != nil }
        for endpoint in mp4Definitions where endpoint.quality == nil {
            guard let urlString = endpoint.videoUrl, let endpointURL = URL(string: urlString) else {
                continue
            }
            candidates += try await Self.fetchMediaList(
                endpointURL: endpointURL, pageURL: pageURL, session: session)
        }

        // 最高画質を選ぶ
        let best = candidates
            .filter { $0.videoUrl != nil }
            .max { ($0.quality ?? 0, $0.height ?? 0) < ($1.quality ?? 0, $1.height ?? 0) }
        guard let best, let urlString = best.videoUrl, let videoURL = URL(string: urlString) else {
            // HLS しか配信されていない動画はここに来る
            throw ExtractError.noMedia
        }

        return [
            MediaItem(
                url: videoURL,
                type: .video,
                filenameBase: "ph_\(key)",
                thumbnailURL: vars.imageUrl.flatMap { URL(string: $0) },
                httpHeaders: ["Referer": pageURL.absoluteString]
            )
        ]
    }

    // MARK: - Fetching

    private static func fetchPlayerVars(pageURL: URL, session: URLSession) async throws -> PlayerVars {
        var request = URLRequest(url: pageURL)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 404 || http.statusCode == 410 {
            throw ExtractError.notFound
        }
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8),
              let json = playerVarsJSON(in: html) else {
            // 年齢確認や同意画面が返された場合もここに来る
            throw ExtractError.apiError("ページを解析できませんでした")
        }
        do {
            return try JSONDecoder().decode(PlayerVars.self, from: json)
        } catch {
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }
    }

    private static func fetchMediaList(
        endpointURL: URL,
        pageURL: URL,
        session: URLSession
    ) async throws -> [MediaDefinition] {
        var request = URLRequest(url: endpointURL)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        return (try? JSONDecoder().decode([MediaDefinition].self, from: data)) ?? []
    }

    // MARK: - Parsing

    /// `var flashvars_123 = {...};` の JSON オブジェクト部分を取り出す。
    /// 中身に他のオブジェクトや文字列が入るため、括弧の対応を数えて終端を探す
    private static func playerVarsJSON(in html: String) -> Data? {
        guard let match = html.range(of: #"var flashvars_\d+\s*=\s*\{"#, options: .regularExpression) else {
            return nil
        }
        let start = html.index(before: match.upperBound) // "{" の位置
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < html.endIndex {
            let character = html[index]
            if isEscaped {
                isEscaped = false
            } else if inString {
                if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{", "[":
                    depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 {
                        return String(html[start...index]).data(using: .utf8)
                    }
                default:
                    break
                }
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// 視聴ページ (`view_video.php?viewkey=`) と埋め込み (`/embed/<key>`) の両形式に対応する
    static func videoKey(from url: URL) -> String? {
        let candidate: String?
        if let viewkey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "viewkey" })?.value {
            candidate = viewkey
        } else {
            let components = url.pathComponents.dropFirst()
            candidate = components.first == "embed" ? components.dropFirst().first : nil
        }
        guard let candidate,
              (8...32).contains(candidate.count),
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return candidate
    }
}

// MARK: - Response models

private struct PlayerVars: Decodable {
    let videoUnavailable: String?
    let videoUnavailableCountry: String?
    let imageUrl: String?
    let mediaDefinitions: [MediaDefinition]?

    enum CodingKeys: String, CodingKey {
        case videoUnavailable = "video_unavailable"
        case videoUnavailableCountry = "video_unavailable_country"
        case imageUrl = "image_url"
        case mediaDefinitions
    }
}

private struct MediaDefinition: Decodable {
    let format: String?
    let videoUrl: String?
    let height: Int?
    /// 画質。数値文字列 ("1080") で入るが、値を持たないエントリでは空配列で返るため
    /// 型を決め打ちにできない
    let quality: Int?

    private enum CodingKeys: String, CodingKey {
        case format, videoUrl, height, quality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try? container.decode(String.self, forKey: .format)
        videoUrl = try? container.decode(String.self, forKey: .videoUrl)
        height = try? container.decode(Int.self, forKey: .height)
        if let text = try? container.decode(String.self, forKey: .quality) {
            quality = Int(text)
        } else {
            quality = try? container.decode(Int.self, forKey: .quality)
        }
    }
}
