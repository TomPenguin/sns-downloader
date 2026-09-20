import Foundation

/// Threads (threads.com / threads.net) の投稿からメディアを抽出する。
///
/// 1. Instagram にログイン済みなら公式 Web API (/api/v1/media/{pk}/info/)
///    → カルーセル全枚数・動画に対応(Threads の投稿コードは Instagram と同じ方式で
///      メディア PK に変換できる)
/// 2. 公開ミラー vxThreads (vxthreads.com) の og タグ(匿名)
/// の順に試す。
struct ThreadsExtractor: MediaExtractor {

    private static let discordBotUA = "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)"

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "threads.com" || host.hasSuffix(".threads.com")
            || host == "threads.net" || host.hasSuffix(".threads.net")
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        let post = try await resolve(url: url)

        var sessionExpired = false
        if let session = InstagramSession.load() {
            do {
                let items = try await extractViaAPI(code: post.code, session: session)
                if !items.isEmpty { return items }
            } catch ExtractError.loginRequired {
                sessionExpired = true
                InstagramSession.markExpired()
            } catch {
                // 匿名方式で続行する
            }
        }
        if let username = post.username,
           let items = try? await extractViaVXThreads(username: username, code: post.code),
           !items.isEmpty {
            return items
        }
        throw sessionExpired ? ExtractError.instagramSessionExpired : ExtractError.loginRequired
    }

    // MARK: - 投稿コードの解決

    /// 投稿コードと、ミラーに渡すためのユーザー名(/@user/post/CODE 形式の user 部分)を返す
    private func resolve(url: URL) async throws -> (code: String, username: String?) {
        if let parsed = Self.parse(url.absoluteString), parsed.username != nil {
            return parsed
        }
        // /t/CODE や共有用の短縮リンクはリダイレクト先が /@user/post/CODE 形式になる
        if let (_, http) = try? await HTTP.get(url),
           let finalURL = http.url,
           let parsed = Self.parse(finalURL.absoluteString),
           parsed.username != nil {
            return parsed
        }
        if let parsed = Self.parse(url.absoluteString) {
            return parsed
        }
        throw ExtractError.unsupportedURL
    }

    private static func parse(_ urlString: String) -> (code: String, username: String?)? {
        let pattern = #"threads\.(?:com|net)/@([^/?#]+)/post/([A-Za-z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
           let userRange = Range(match.range(at: 1), in: urlString),
           let codeRange = Range(match.range(at: 2), in: urlString) {
            return (String(urlString[codeRange]), String(urlString[userRange]))
        }
        if let code = urlString.firstMatchGroup(pattern: #"threads\.(?:com|net)/t/([A-Za-z0-9_-]+)"#) {
            return (code, nil)
        }
        return nil
    }

    // MARK: - 方法 1: Instagram のセッションで公式 API

    private func extractViaAPI(code: String, session: InstagramSession) async throws -> [MediaItem] {
        guard let pk = InstagramExtractor.mediaPK(fromShortcode: code) else {
            throw ExtractError.unsupportedURL
        }
        // Threads の投稿も Instagram のメディア名前空間にあるので instagram.com 側に投げる。
        // Cookie はドメイン単位なので threads.com に同じ Cookie を送っても通らず、
        // 常に 302 が返って「セッション切れ」と誤判定してしまうため叩かない
        let post = try await InstagramExtractor.fetchMediaInfo(
            endpoint: URL(string: "https://www.instagram.com/api/v1/media/\(pk)/info/")!,
            referer: "https://www.instagram.com/",
            appID: InstagramExtractor.igAppID,
            session: session
        )
        let items = InstagramExtractor.mediaItems(fromAPIPost: post, filenameBase: "threads_\(code)")
        guard !items.isEmpty else { throw ExtractError.noMedia }
        return items
    }

    // MARK: - 方法 2: vxThreads ミラーの og タグ(匿名)

    private func extractViaVXThreads(username: String, code: String) async throws -> [MediaItem] {
        // URL 末尾に本文スラッグが付いているとミラーが 404 を返すので、正規形に組み直す
        guard let mirrorURL = URL(string: "https://www.vxthreads.com/@\(username)/post/\(code)") else {
            throw ExtractError.unsupportedURL
        }
        let (data, http) = try await HTTP.get(mirrorURL, headers: ["User-Agent": Self.discordBotUA])
        guard http.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw ExtractError.apiError("vxThreads HTTP \(http.statusCode)")
        }

        let images = Self.metaContents(property: "og:image", in: html).compactMap(URL.init(string:))
        let videos = Self.metaContents(property: "og:video", in: html).compactMap(URL.init(string:))

        // 動画がある投稿では og:image はサムネイル扱いにする
        if !videos.isEmpty {
            return videos.enumerated().map { index, url in
                MediaItem(
                    url: url,
                    type: .video,
                    filenameBase: videos.count > 1 ? "threads_\(code)_\(index + 1)" : "threads_\(code)",
                    thumbnailURL: images.first
                )
            }
        }
        return images.enumerated().map { index, url in
            MediaItem(
                url: url,
                type: .photo,
                filenameBase: images.count > 1 ? "threads_\(code)_\(index + 1)" : "threads_\(code)",
                thumbnailURL: url
            )
        }
    }

    /// 同じ property の meta タグをすべて(重複を除いて出現順に)返す
    private static func metaContents(property: String, in html: String) -> [String] {
        let pattern = #"<meta property="\#(property)" content="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [String] = []
        for match in regex.matches(in: html, range: range) {
            guard let groupRange = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[groupRange]).replacingOccurrences(of: "&amp;", with: "&")
            if !result.contains(value) { result.append(value) }
        }
        return result
    }
}
