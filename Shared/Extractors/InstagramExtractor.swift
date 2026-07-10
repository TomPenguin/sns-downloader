import Foundation

/// Instagram の投稿(フィード / リール / カルーセル)からメディアを抽出する。
///
/// 1. ログイン済みなら公式 Web API (/api/v1/media/{pk}/info/)
///    → カルーセル全枚数・フォロー中の非公開アカウントにも対応
/// 2. InstaFix 系ミラー (kkinstagram.com) のリダイレクト先 CDN URL(匿名・1枚目のみ)
/// 3. instagram.com がクローラー UA に返す og:video / og:image メタタグ(匿名・1枚目のみ)
/// の順に試す。
struct InstagramExtractor: MediaExtractor {

    private static let discordBotUA = "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)"
    private static let crawlerUA = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
    private static let igAppID = "936619743392459"

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        let shortcode = try await resolveShortcode(from: url)
        let isReelHint = url.path.contains("/reel") || url.path.contains("/tv/")

        // 方法 1: ログイン済みなら公式 API(失敗したら匿名方式へフォールバック)
        if let session = InstagramSession.load() {
            do {
                let items = try await extractViaAPI(shortcode: shortcode, session: session)
                if !items.isEmpty { return items }
            } catch ExtractError.loginRequired {
                // セッション切れ。匿名方式にフォールバックして続行
            }
        }

        if let items = try? await extractViaInstaFix(shortcode: shortcode, isReelHint: isReelHint),
           !items.isEmpty {
            return items
        }
        if let items = try? await extractViaOGTags(shortcode: shortcode), !items.isEmpty {
            return items
        }
        throw ExtractError.loginRequired
    }

    // MARK: - shortcode の解決

    private func resolveShortcode(from url: URL) async throws -> String {
        if let code = Self.shortcode(in: url.absoluteString) {
            return code
        }
        // 共有リンク (instagram.com/share/...) はリダイレクト先に shortcode が含まれる
        if url.path.hasPrefix("/share/") {
            let (_, http) = try await HTTP.get(url)
            if let finalURL = http.url, let code = Self.shortcode(in: finalURL.absoluteString) {
                return code
            }
        }
        throw ExtractError.unsupportedURL
    }

    private static func shortcode(in urlString: String) -> String? {
        urlString.firstMatchGroup(pattern: #"instagram\.com/(?:[^/]+/)?(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)"#)
    }

    /// shortcode(base64url 風エンコード)→ メディア PK(数値 ID)
    static func mediaPK(fromShortcode shortcode: String) -> UInt64? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var pk: UInt64 = 0
        for ch in shortcode.prefix(11) {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            let value = UInt64(alphabet.distance(from: alphabet.startIndex, to: index))
            let (multiplied, overflow1) = pk.multipliedReportingOverflow(by: 64)
            guard !overflow1 else { return nil }
            let (added, overflow2) = multiplied.addingReportingOverflow(value)
            guard !overflow2 else { return nil }
            pk = added
        }
        return pk
    }

    // MARK: - 方法 1: ログイン済み公式 Web API

    private func extractViaAPI(shortcode: String, session: InstagramSession) async throws -> [MediaItem] {
        guard let pk = Self.mediaPK(fromShortcode: shortcode) else {
            throw ExtractError.unsupportedURL
        }

        var request = URLRequest(url: URL(string: "https://www.instagram.com/api/v1/media/\(pk)/info/")!)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(session.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        request.setValue(Self.igAppID, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let csrf = session.csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        }

        let (data, http) = try await HTTP.perform(request)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ExtractError.loginRequired
        }
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("Instagram API HTTP \(http.statusCode)")
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (root["status"] as? String) == "ok",
            let items = root["items"] as? [[String: Any]],
            let post = items.first
        else {
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (root["message"] as? String) == "login_required" {
                throw ExtractError.loginRequired
            }
            throw ExtractError.apiError("Instagram API のレスポンスを解析できませんでした")
        }

        // カルーセル(media_type 8)は carousel_media に全メディアが入る
        if let carousel = post["carousel_media"] as? [[String: Any]], !carousel.isEmpty {
            return carousel.enumerated().compactMap { index, node in
                Self.mediaItem(fromAPINode: node, filenameBase: "ig_\(shortcode)_\(index + 1)")
            }
        }
        if let item = Self.mediaItem(fromAPINode: post, filenameBase: "ig_\(shortcode)") {
            return [item]
        }
        return []
    }

    private static func mediaItem(fromAPINode node: [String: Any], filenameBase: String) -> MediaItem? {
        // 画像・動画どちらも image_versions2 がサムネイルとして使える
        var thumbnail: URL?
        if let imageVersions = node["image_versions2"] as? [String: Any],
           let candidates = imageVersions["candidates"] as? [[String: Any]],
           let urlString = candidates.first?["url"] as? String {
            thumbnail = URL(string: urlString)
        }

        // media_type: 1 = 画像, 2 = 動画
        if let versions = node["video_versions"] as? [[String: Any]],
           let urlString = versions.first?["url"] as? String,
           let url = URL(string: urlString) {
            return MediaItem(url: url, type: .video, filenameBase: filenameBase, thumbnailURL: thumbnail)
        }
        if let thumbnail {
            return MediaItem(url: thumbnail, type: .photo, filenameBase: filenameBase, thumbnailURL: thumbnail)
        }
        return nil
    }

    // MARK: - 方法 2: InstaFix ミラーのリダイレクト先 CDN URL(匿名・1枚目のみ)

    private func extractViaInstaFix(shortcode: String, isReelHint: Bool) async throws -> [MediaItem] {
        let pathType = isReelHint ? "reel" : "p"
        let mirrorURL = URL(string: "https://kkinstagram.com/\(pathType)/\(shortcode)/")!

        guard let location = try await HTTP.redirectLocation(
            for: mirrorURL,
            headers: ["User-Agent": Self.discordBotUA]
        ) else {
            throw ExtractError.apiError("リダイレクトが返されませんでした")
        }

        // メディア CDN 以外(instagram.com 本体やアプリ誘導ページ)へのリダイレクトは失敗扱い
        guard let host = location.host?.lowercased(),
              host.contains("cdninstagram.com") || host.contains("fbcdn.net") else {
            throw ExtractError.apiError("メディアURLを取得できませんでした")
        }

        let type = Self.mediaType(ofCDNURL: location)
        let thumbnail = (type == .photo) ? location : nil
        return [MediaItem(url: location, type: type, filenameBase: "ig_\(shortcode)", thumbnailURL: thumbnail)]
    }

    /// CDN URL から画像か動画かを推定する(最終判定はダウンロード時の MIME タイプで行う)
    private static func mediaType(ofCDNURL url: URL) -> MediaType {
        let s = url.absoluteString.lowercased()
        if s.contains("dst-jpg") || s.contains(".jpg") || s.contains(".webp") || s.contains(".heic") {
            return .photo
        }
        return .video
    }

    // MARK: - 方法 3: instagram.com の og メタタグ(クローラー UA・1枚目のみ)

    private func extractViaOGTags(shortcode: String) async throws -> [MediaItem] {
        let pageURL = URL(string: "https://www.instagram.com/p/\(shortcode)/")!
        let (data, http) = try await HTTP.get(pageURL, headers: ["User-Agent": Self.crawlerUA])
        guard http.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw ExtractError.apiError("Instagram HTTP \(http.statusCode)")
        }

        let ogImage = Self.metaContent(property: "og:image", in: html).flatMap(URL.init(string:))
        if let content = Self.metaContent(property: "og:video", in: html), let url = URL(string: content) {
            return [MediaItem(url: url, type: .video, filenameBase: "ig_\(shortcode)", thumbnailURL: ogImage)]
        }
        if let url = ogImage {
            return [MediaItem(url: url, type: .photo, filenameBase: "ig_\(shortcode)", thumbnailURL: url)]
        }
        return []
    }

    private static func metaContent(property: String, in html: String) -> String? {
        html.firstMatchGroup(pattern: #"<meta property="\#(property)" content="([^"]+)""#)?
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
