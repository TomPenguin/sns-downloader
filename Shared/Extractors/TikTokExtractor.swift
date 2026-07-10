import Foundation

/// TikTok の投稿からメディアを抽出する。
/// 公開 API の tikwm.com を利用する(短縮リンク vm.tiktok.com などもそのまま渡せる)。
struct TikTokExtractor: MediaExtractor {

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        var components = URLComponents(string: "https://www.tikwm.com/api/")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "hd", value: "1"),
        ]
        let (data, http) = try await HTTP.get(components.url!)
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("tikwm HTTP \(http.statusCode)")
        }

        let response: TikwmResponse
        do {
            response = try JSONDecoder().decode(TikwmResponse.self, from: data)
        } catch {
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }

        guard response.code == 0, let payload = response.data else {
            throw ExtractError.apiError(response.msg ?? "投稿を取得できませんでした")
        }

        let postID = payload.id ?? "post"

        // 画像投稿(スライドショー)
        if let images = payload.images, !images.isEmpty {
            return images.enumerated().compactMap { index, urlString in
                guard let mediaURL = Self.absoluteURL(urlString) else { return nil }
                return MediaItem(
                    url: mediaURL,
                    type: .photo,
                    filenameBase: "tiktok_\(postID)_\(index + 1)",
                    thumbnailURL: mediaURL
                )
            }
        }

        // 動画投稿(HD があれば優先)
        let playURLString = [payload.hdplay, payload.play]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let playURLString, let videoURL = Self.absoluteURL(playURLString) else {
            throw ExtractError.noMedia
        }
        let cover = payload.cover.flatMap { Self.absoluteURL($0) }
        return [MediaItem(url: videoURL, type: .video, filenameBase: "tiktok_\(postID)", thumbnailURL: cover)]
    }

    /// tikwm はパスだけの相対 URL を返すことがある
    private static func absoluteURL(_ string: String) -> URL? {
        if string.hasPrefix("http://") || string.hasPrefix("https://") {
            return URL(string: string)
        }
        if string.hasPrefix("/") {
            return URL(string: "https://www.tikwm.com" + string)
        }
        return nil
    }
}

private struct TikwmResponse: Decodable {
    let code: Int
    let msg: String?
    let data: TikwmData?
}

private struct TikwmData: Decodable {
    let id: String?
    let play: String?
    let hdplay: String?
    let cover: String?
    let images: [String]?
}
