import Foundation

/// pixiv の作品ページからメディアを抽出する。
/// ログイン中の Web フロントエンドが叩く公開 AJAX API (www.pixiv.net/ajax/...) を利用する。
///
/// - イラスト / マンガ: 全ページのオリジナル解像度画像
/// - うごイラ: フレーム ZIP の URL とフレーム情報(後段で mp4 に組み立てる)
///
/// 画像 CDN (i.pximg.net) は Referer: https://www.pixiv.net/ が無いと 403 になるため、
/// ダウンロード時に付与する HTTP ヘッダとして各 MediaItem に持たせる。
/// R-18 などログインが必要な作品は取得できない(AJAX API がエラーを返す)。
struct PixivExtractor: MediaExtractor {

    private static let referer = "https://www.pixiv.net/"

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "pixiv.net" || host.hasSuffix(".pixiv.net")
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        let raw = url.absoluteString
        guard let illustID = raw.firstMatchGroup(pattern: #"/artworks/(\d+)"#)
                ?? raw.firstMatchGroup(pattern: #"illust_id=(\d+)"#) else {
            throw ExtractError.unsupportedURL
        }

        let meta = try await fetchIllust(id: illustID)

        // illustType: 0 = イラスト, 1 = マンガ, 2 = うごイラ
        if meta.illustType == 2 {
            return [try await extractUgoira(id: illustID)]
        }
        return try extractPages(id: illustID, meta: meta)
    }

    // MARK: - イラスト / マンガ

    /// メタの urls.original と pageCount から全ページの URL を導出する。
    /// (複数ページは末尾が _p0, _p1, … と連番になっているだけで、それ以外は共通)
    /// `/pages` エンドポイントは R-18 で認証を要求して 404 になるため使わない。
    private func extractPages(id: String, meta: PixivIllustBody) throws -> [MediaItem] {
        // 認証が不十分な R-18 等は original が null になる
        guard let original = meta.urls?.original, !original.isEmpty else {
            throw ExtractError.pixivRestricted
        }

        let pageCount = max(meta.pageCount ?? 1, 1)
        let items: [MediaItem] = (0..<pageCount).compactMap { index in
            guard let pageURL = Self.pageURL(from: original, pageIndex: index),
                  let mediaURL = URL(string: pageURL) else { return nil }
            return MediaItem(
                url: mediaURL,
                type: .photo,
                filenameBase: "pixiv_\(id)_p\(index + 1)",
                thumbnailURL: Self.thumbnailURL(from: original, pageIndex: index),
                httpHeaders: ["Referer": Self.referer]
            )
        }
        guard !items.isEmpty else { throw ExtractError.noMedia }
        return items
    }

    /// "…/12345_p0.png" の _p0 部分を _p{index} に差し替える
    private static func pageURL(from original: String, pageIndex: Int) -> String? {
        guard let range = original.range(of: "_p0.", options: .backwards) else {
            // 想定形式でなければ 1 ページ目のみそのまま使う
            return pageIndex == 0 ? original : nil
        }
        return original.replacingCharacters(in: range, with: "_p\(pageIndex).")
    }

    /// オリジナル URL から選択 UI 用の縮小版(540px マスター JPEG)URL を導出する。
    ///   original: …/img-original/img/DATE/12345_p0.png
    ///   thumb   : …/c/540x540_70/img-master/img/DATE/12345_p0_master1200.jpg
    private static func thumbnailURL(from original: String, pageIndex: Int) -> URL? {
        guard let pageURLString = pageURL(from: original, pageIndex: pageIndex) else { return nil }
        var thumb = pageURLString.replacingOccurrences(
            of: "/img-original/", with: "/c/540x540_70/img-master/")
        // 拡張子を _master1200.jpg に置換(元は .png / .jpg / .gif など)
        if let dot = thumb.range(of: ".", options: .backwards) {
            thumb.replaceSubrange(dot.lowerBound..<thumb.endIndex, with: "_master1200.jpg")
        }
        return URL(string: thumb)
    }

    // MARK: - うごイラ

    private func extractUgoira(id: String) async throws -> MediaItem {
        let body: PixivUgoiraBody
        do {
            body = try await fetchBody(
                "https://www.pixiv.net/ajax/illust/\(id)/ugoira_meta",
                as: PixivUgoiraResponse.self
            ).body
        } catch ExtractError.notFound {
            // メタ取得は成功しているので、うごイラ本体だけ取れないのは R-18 等の認証制限
            throw ExtractError.pixivRestricted
        }

        // originalSrc(高解像度)を優先し、無ければ src(600x600 プレビュー)
        guard let zipString = body.originalSrc ?? body.src, let zipURL = URL(string: zipString) else {
            throw ExtractError.noMedia
        }
        let frames = body.frames.map { UgoiraFrame(file: $0.file, delayMS: $0.delay) }
        guard !frames.isEmpty else { throw ExtractError.noMedia }

        return MediaItem(
            url: zipURL,
            type: .video,
            filenameBase: "pixiv_\(id)_ugoira",
            httpHeaders: ["Referer": Self.referer],
            ugoiraFrames: frames
        )
    }

    // MARK: - AJAX API 呼び出し

    private func fetchIllust(id: String) async throws -> PixivIllustBody {
        try await fetchBody(
            "https://www.pixiv.net/ajax/illust/\(id)",
            as: PixivIllustResponse.self
        ).body
    }

    /// 共通のラッパー {error, message, body} をデコードして返す
    private func fetchBody<T: Decodable>(_ urlString: String, as _: T.Type) async throws -> T {
        guard let url = URL(string: urlString) else { throw ExtractError.unsupportedURL }
        var headers = [
            "Referer": Self.referer,
            "Accept": "application/json",
        ]
        // ログイン済みなら Cookie を付けて R-18 などの作品も取得できるようにする
        if let session = PixivSession.load() {
            headers["Cookie"] = session.cookieHeaderValue
        }
        let (data, http) = try await HTTP.get(url, headers: headers)

        if http.statusCode == 404 { throw ExtractError.notFound }
        // pixiv は非公開・要ログイン作品に 403 を返すことがある
        if http.statusCode == 401 || http.statusCode == 403 { throw ExtractError.loginRequired }
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("pixiv HTTP \(http.statusCode)")
        }

        do {
            let response = try JSONDecoder().decode(T.self, from: data)
            return response
        } catch {
            // error フラグ付きレスポンスならメッセージを拾う
            if let envelope = try? JSONDecoder().decode(PixivErrorEnvelope.self, from: data), envelope.error {
                let message = envelope.message ?? ""
                // R-18 など要ログイン作品は error:true を返す。未ログインならログインを促す
                // (メッセージに "ログイン" が含まれないことも多いため、未ログインを優先判定)
                if PixivSession.load() == nil
                    || message.contains("ログイン") || message.lowercased().contains("login") {
                    throw ExtractError.loginRequired
                }
                throw ExtractError.apiError(message.isEmpty ? "作品を取得できませんでした" : message)
            }
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }
    }
}

// MARK: - レスポンス定義

private struct PixivErrorEnvelope: Decodable {
    let error: Bool
    let message: String?
}

private struct PixivIllustResponse: Decodable {
    let body: PixivIllustBody
}

private struct PixivIllustBody: Decodable {
    let illustType: Int
    let pageCount: Int?
    let urls: PixivPageURLs?
}

private struct PixivPageURLs: Decodable {
    let original: String?
}

private struct PixivUgoiraResponse: Decodable {
    let body: PixivUgoiraBody
}

private struct PixivUgoiraBody: Decodable {
    let src: String?
    let originalSrc: String?
    let frames: [PixivUgoiraFrame]
}

private struct PixivUgoiraFrame: Decodable {
    let file: String
    let delay: Int
}
