import Foundation

/// iwara の動画からメディアを抽出する。
/// 公式 API (api.iwara.tv) を使う 2 段構え:
/// 1. `/video/<id>` で動画情報を取り、期限付きの `fileUrl` を得る
/// 2. `fileUrl` を叩くと画質ごとの配信 URL 一覧が返るので、最高画質の
///    `src.download` をダウンロード対象にする
///
/// 動作確認メモ (2026-07):
/// - 未ログインでは原本が 4K でも 360p しか一覧に返らない。ログイン時の
///   アクセストークンを付けると Source(原本)を含む全画質が返る
/// - `preview` は数秒の切り抜きなので候補から除外する
/// - 配信 URL は protocol-relative ("//host/download?…") で返るため補完が必要
/// - CDN 側は署名付き URL なので、ダウンロード時に追加ヘッダは要らない
struct IwaraExtractor: MediaExtractor {

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isSupportedHost = host == "iwara.tv" || host.hasSuffix(".iwara.tv")
        return isSupportedHost && Self.videoID(from: url) != nil
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        guard let videoID = Self.videoID(from: url) else {
            throw ExtractError.unsupportedURL
        }

        // ログインしていれば全画質が返る。未ログインなら nil のまま 360p で続行する
        let accessToken = await IwaraTokenProvider.shared.accessToken()

        let video = try await Self.fetchVideo(id: videoID, accessToken: accessToken)
        guard let fileURLString = video.fileUrl, let fileURL = URL(string: fileURLString) else {
            if video.embedUrl?.isEmpty == false {
                throw ExtractError.apiError("外部サイトの埋め込み動画のため取得できません")
            }
            throw video.isPrivate == true ? ExtractError.loginRequired : ExtractError.noMedia
        }

        let sources = try await Self.fetchSources(fileURL: fileURL, accessToken: accessToken)
        // 数値が大きいほど高画質。Source は原本なので最優先
        let best = sources
            .filter { Self.rank(of: $0.name) != nil && $0.src?.download != nil }
            .max { (Self.rank(of: $0.name) ?? 0) < (Self.rank(of: $1.name) ?? 0) }
        guard let best, let downloadURL = best.src?.download.flatMap(Self.absoluteURL) else {
            throw ExtractError.noMedia
        }

        return [
            MediaItem(
                url: downloadURL,
                type: .video,
                filenameBase: "iwara_\(videoID)",
                thumbnailURL: Self.thumbnailURL(for: video)
            )
        ]
    }

    // MARK: - API

    private static func fetchVideo(id: String, accessToken: String?) async throws -> VideoResponse {
        guard let url = URL(string: "https://api.iwara.tv/video/\(id)") else {
            throw ExtractError.unsupportedURL
        }
        let (data, http) = try await get(url, accessToken: accessToken)
        switch http.statusCode {
        case 200:
            break
        case 404:
            throw ExtractError.notFound
        case 401, 403:
            throw ExtractError.loginRequired
        default:
            throw ExtractError.apiError("iwara API HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(VideoResponse.self, from: data)
        } catch {
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }
    }

    private static func fetchSources(fileURL: URL, accessToken: String?) async throws -> [Source] {
        let (data, http) = try await get(fileURL, accessToken: accessToken)
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("配信URLの取得に失敗しました (HTTP \(http.statusCode))")
        }
        guard let sources = try? JSONDecoder().decode([Source].self, from: data) else {
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }
        return sources
    }

    private static func get(_ url: URL, accessToken: String?) async throws -> (Data, HTTPURLResponse) {
        var headers: [String: String] = [:]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return try await HTTP.get(url, headers: headers)
    }

    // MARK: - Helpers

    /// 画質の優先度。`preview` は本編ではないので nil を返して候補から外す
    private static func rank(of name: String?) -> Int? {
        guard let name else { return nil }
        if name == "Source" { return .max }
        if name.lowercased() == "preview" { return nil }
        return Int(name)
    }

    /// 配信 URL は "//host/path" 形式で返る
    private static func absoluteURL(_ string: String) -> URL? {
        if string.hasPrefix("//") {
            return URL(string: "https:" + string)
        }
        return URL(string: string)
    }

    /// 投稿者が設定したサムネイルがあればそれを、なければ動画から切り出された
    /// コマ画像を使う(`thumbnail` がそのコマ番号)
    private static func thumbnailURL(for video: VideoResponse) -> URL? {
        if let custom = video.customThumbnail, let id = custom.id, let name = custom.name {
            return URL(string: "https://i.iwara.tv/image/original/\(id)/\(name)")
        }
        guard let fileID = video.file?.id else { return nil }
        let index = String(format: "%02d", video.thumbnail ?? 1)
        return URL(string: "https://i.iwara.tv/image/thumbnail/\(fileID)/thumbnail-\(index).jpg")
    }

    /// `/video/<id>` と `/video/<id>/<slug>` の両形式に対応する
    static func videoID(from url: URL) -> String? {
        let components = url.pathComponents.dropFirst()
        guard components.first == "video", let candidate = components.dropFirst().first,
              (8...24).contains(candidate.count),
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return candidate
    }
}

// MARK: - Response models

private struct VideoResponse: Decodable {
    let fileUrl: String?
    let embedUrl: String?
    let isPrivate: Bool?
    /// サムネイルに使うコマ番号
    let thumbnail: Int?
    let file: FileInfo?
    let customThumbnail: FileInfo?

    enum CodingKeys: String, CodingKey {
        case fileUrl, embedUrl, thumbnail, file, customThumbnail
        case isPrivate = "private"
    }
}

private struct FileInfo: Decodable {
    let id: String?
    let name: String?
}

private struct Source: Decodable {
    let name: String?
    let src: SourceURLs?
}

private struct SourceURLs: Decodable {
    let view: String?
    let download: String?
}
