import Foundation

/// X (Twitter) の投稿からメディアを抽出する。
/// 公開ミラー API の FxTwitter (api.fxtwitter.com) を利用する。
struct TwitterExtractor: MediaExtractor {

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let hosts = ["twitter.com", "www.twitter.com", "mobile.twitter.com", "x.com", "www.x.com", "mobile.x.com"]
        return hosts.contains(host)
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        guard let statusID = url.absoluteString.firstMatchGroup(pattern: #"/status(?:es)?/(\d+)"#) else {
            throw ExtractError.unsupportedURL
        }

        let apiURL = URL(string: "https://api.fxtwitter.com/i/status/\(statusID)")!
        let (data, http) = try await HTTP.get(apiURL)

        if http.statusCode == 404 {
            throw ExtractError.notFound
        }
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("FxTwitter HTTP \(http.statusCode)")
        }

        let response: FxResponse
        do {
            response = try JSONDecoder().decode(FxResponse.self, from: data)
        } catch {
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }

        guard response.code == 200, let tweet = response.tweet else {
            if response.code == 401 || response.code == 403 {
                throw ExtractError.loginRequired
            }
            throw ExtractError.notFound
        }

        let all = tweet.media?.all ?? []
        return all.enumerated().compactMap { index, item in
            guard let mediaURL = URL(string: item.url) else { return nil }
            let type: MediaType = (item.type == "photo") ? .photo : .video
            let thumbnail = (type == .photo) ? mediaURL : item.thumbnail_url.flatMap(URL.init(string:))
            return MediaItem(
                url: mediaURL,
                type: type,
                filenameBase: "x_\(statusID)_\(index + 1)",
                thumbnailURL: thumbnail
            )
        }
    }
}

private struct FxResponse: Decodable {
    let code: Int
    let message: String?
    let tweet: FxTweet?
}

private struct FxTweet: Decodable {
    let media: FxMedia?
}

private struct FxMedia: Decodable {
    let all: [FxMediaItem]?
}

private struct FxMediaItem: Decodable {
    let type: String // "photo" | "video" | "gif"
    let url: String
    let thumbnail_url: String?
}
