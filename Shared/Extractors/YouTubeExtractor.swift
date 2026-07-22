import Foundation

/// YouTube の動画からメディアを抽出する。
/// YouTube 内部の player API (Innertube) を非 Web クライアントとして直接呼び出す。
/// 外部サービスに依存しないが、YouTube 側の仕様変更で動かなくなる可能性はある。
///
/// クライアント選定メモ (2026-07 動作確認):
/// - IOS / WEB クライアントは progressive 形式(映像+音声一体)が返らなくなった
/// - ANDROID / ANDROID_VR は署名解読不要の直 URL が返る
/// - どのクライアントも動画によってはボット検証 (LOGIN_REQUIRED) にかかることが
///   あるため、複数クライアントを順に試す
///
/// 画質: adaptiveFormats から H.264 (avc1) の最高解像度の映像と AAC 音声を選び、
/// ダウンロード後に MediaMuxer で合成する(通常 1080p)。4K などは VP9/AV1 のみの
/// 配信で iOS では再エンコードなしの合成ができないため、H.264 の最高解像度が上限。
/// adaptive が取れない場合は progressive 形式 (itag 18, 360p) にフォールバック。
///
/// PO トークン規制について (2026-07 動作確認):
/// ストリーム URL は動画・クライアントによって「先頭の一部以降のオフセットを
/// 403 で拒否」される(PO トークンなしへの規制。ratebypass=yes 付き URL は制限なし)。
/// 対策は 2 段構え:
/// 1. player リクエストに visitorData を付ける(ANDROID_VR + visitorData なら
///    規制なしの URL が返ることを確認済み。ボット検証の回避にも効く)
/// 2. それでも各フォーマットの最終バイトを Range で取得してみて、ダウンロード
///    可能なフォーマットだけを採用する。最高解像度が取れないクライアントが
///    あっても、全クライアントの中で最も高解像度が取れる結果を使う
struct YouTubeExtractor: MediaExtractor {

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isYouTubeHost = host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtu.be"
        return isYouTubeHost && Self.videoID(from: url) != nil
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        guard let videoID = Self.videoID(from: url) else {
            throw ExtractError.unsupportedURL
        }

        // visitorData(セッション識別子)を付けると、ボット検証にかかりにくくなり、
        // ストリーム URL の取得規制(全量ダウンロード拒否)も回避できる
        let visitorData = await Self.fetchVisitorData()

        var lastError: Error = ExtractError.noMedia
        // そのクライアントの最高画質が取れたら即採用。画質が落ちた(URL の一部が
        // 403 で拒否された)場合は、他のクライアントも試して一番良い結果を使う
        var bestDegraded: (items: [MediaItem], height: Int)?
        for client in Self.clients {
            do {
                let result = try await Self.extract(
                    videoID: videoID, client: client, visitorData: visitorData)
                if result.isBestQuality {
                    return result.items
                }
                if bestDegraded == nil || result.height > bestDegraded!.height {
                    bestDegraded = (result.items, result.height)
                }
            } catch {
                lastError = error
            }
        }
        if let bestDegraded {
            return bestDegraded.items
        }
        throw lastError
    }

    private static func extract(
        videoID: String,
        client: InnertubeClient,
        visitorData: String?
    ) async throws -> (items: [MediaItem], height: Int, isBestQuality: Bool) {
        let response = try await fetchPlayerResponse(
            videoID: videoID, client: client, visitorData: visitorData)

        switch response.playabilityStatus?.status {
        case "OK", nil:
            break
        case "LOGIN_REQUIRED":
            // ボット検証もここに来る。別クライアントなら通ることがあるので
            // 呼び出し側でフォールバックする
            let reason = response.playabilityStatus?.reason ?? ""
            if reason.contains("bot") || reason.contains("ロボット") {
                throw ExtractError.apiError("YouTubeのボット検証にブロックされました。時間をおいて再試行してください")
            }
            throw ExtractError.loginRequired
        case "ERROR":
            throw ExtractError.notFound
        default:
            throw ExtractError.apiError(response.playabilityStatus?.reason ?? "この動画は再生できません")
        }

        let thumbnail = response.videoDetails?.thumbnail?.thumbnails?.last?.url
            .flatMap { URL(string: $0) }
        let filenameBase = "youtube_\(videoID)"

        // progressive 形式(映像+音声一体、通常 360p)
        let progressive = (response.streamingData?.formats ?? [])
            .filter { $0.url != nil && ($0.mimeType?.hasPrefix("video/mp4") ?? false) }
            .max { ($0.height ?? 0, $0.bitrate ?? 0) < ($1.height ?? 0, $1.bitrate ?? 0) }

        // adaptive 形式(映像のみ+音声のみ)。合成が必要だが高解像度が取れる。
        // iOS で再エンコードなしの合成ができるよう H.264 (avc1) + AAC (mp4a) に限定する
        let adaptiveFormats = response.streamingData?.adaptiveFormats ?? []
        let videoCandidates = adaptiveFormats
            .filter {
                $0.url != nil
                    && ($0.mimeType?.hasPrefix("video/mp4") ?? false)
                    && ($0.mimeType?.contains("avc1") ?? false)
            }
            .sorted { ($0.height ?? 0, $0.bitrate ?? 0) > ($1.height ?? 0, $1.bitrate ?? 0) }
        let bestAudio = adaptiveFormats
            .filter { $0.url != nil && ($0.mimeType?.hasPrefix("audio/mp4") ?? false) }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }

        // ダウンロード時もこの UA を使う(発行元クライアントと違う UA だと 403 になることがある)
        let headers = ["User-Agent": client.userAgent]
        // 大きな Range 指定を一度に投げないよう 10MB ずつ分割して落とす
        let chunkSize = 10_485_760
        let topHeight = videoCandidates.first?.height ?? 0

        // 高解像度の候補から順に、最終バイトまで実際に取得可能なものを選ぶ
        if let bestAudio, let audioURLString = bestAudio.url,
           let audioURL = URL(string: audioURLString),
           await isFullyAccessible(url: audioURL, contentLength: bestAudio.contentLengthBytes,
                                   userAgent: client.userAgent) {
            for candidate in videoCandidates {
                let height = candidate.height ?? 0
                // progressive 以下の解像度しか残っていないなら progressive でよい
                guard height > (progressive?.height ?? 0) else { break }
                guard let urlString = candidate.url, let videoURL = URL(string: urlString) else {
                    continue
                }
                guard await isFullyAccessible(url: videoURL, contentLength: candidate.contentLengthBytes,
                                              userAgent: client.userAgent) else {
                    continue
                }
                let item = MediaItem(
                    url: videoURL,
                    type: .video,
                    filenameBase: filenameBase,
                    thumbnailURL: thumbnail,
                    audioURL: audioURL,
                    httpHeaders: headers,
                    downloadChunkSize: chunkSize
                )
                return ([item], height, height >= topHeight)
            }
        }

        // progressive フォールバック(通常 360p)
        guard let progressive, let urlString = progressive.url,
              let videoURL = URL(string: urlString) else {
            throw ExtractError.noMedia
        }
        guard await isFullyAccessible(url: videoURL, contentLength: progressive.contentLengthBytes,
                                      userAgent: client.userAgent) else {
            throw ExtractError.apiError("ストリームURLが拒否されました (HTTP 403)")
        }
        let item = MediaItem(
            url: videoURL,
            type: .video,
            filenameBase: filenameBase,
            thumbnailURL: thumbnail,
            httpHeaders: headers,
            downloadChunkSize: chunkSize
        )
        // adaptive 候補が元々なければこれがこのクライアントの最高画質
        return ([item], progressive.height ?? 0, videoCandidates.isEmpty)
    }

    /// ストリーム URL の最終バイトを Range リクエストで取得してみて、
    /// 全域がダウンロード可能なことを確認する。
    /// PO トークンなしの URL は一定オフセット(30MiB 前後)以降が 403 になる
    /// ことがあり、先頭だけ確認しても途中で失敗するため末尾で確認する
    private static func isFullyAccessible(
        url: URL,
        contentLength: Int?,
        userAgent: String
    ) async -> Bool {
        let lastByte = max(0, (contentLength ?? 1) - 1)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(lastByte)-\(lastByte)", forHTTPHeaderField: "Range")
        guard let (_, http) = try? await HTTP.perform(request) else { return false }
        return http.statusCode == 200 || http.statusCode == 206
    }

    /// watch?v= / youtu.be / shorts / live / embed の各形式から動画 ID を取り出す
    static func videoID(from url: URL) -> String? {
        let candidate: String?
        if url.host?.lowercased() == "youtu.be" {
            candidate = url.pathComponents.dropFirst().first
        } else if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            candidate = v
        } else {
            let components = url.pathComponents.dropFirst()
            if let first = components.first, ["shorts", "live", "embed", "v"].contains(first) {
                candidate = components.dropFirst().first
            } else {
                candidate = nil
            }
        }
        // 動画 ID は 11 文字の英数字と -_
        guard let candidate,
              candidate.count == 11,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return candidate
    }

    // MARK: - Innertube API

    private struct InnertubeClient {
        let userAgent: String
        /// player リクエストの context.client に入れる値
        let context: [String: Any]
    }

    /// ANDROID_VR を先頭にする: PO トークン規制の対象外で、visitorData 付きなら
    /// ボット検証にもかかりにくく、最高画質がそのまま取れることが多い
    private static let clients: [InnertubeClient] = [
        InnertubeClient(
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            context: [
                "clientName": "ANDROID_VR",
                "clientVersion": "1.62.27",
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L",
            ]
        ),
        InnertubeClient(
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
            context: [
                "clientName": "ANDROID",
                "clientVersion": "20.10.38",
                "androidSdkVersion": 30,
                "osName": "Android",
                "osVersion": "11",
            ]
        ),
    ]

    /// visitorData(未ログインセッションの識別子)を取得する。
    /// player リクエストに付けるとボット検証・取得規制にかかりにくくなる。
    /// 取得に失敗しても抽出は続行できるので nil を返すだけにする
    private static func fetchVisitorData() async -> String? {
        let client = clients[0]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/visitor_id")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["context": ["client": client.context]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, http) = try? await HTTP.perform(request), http.statusCode == 200,
              let response = try? JSONDecoder().decode(VisitorIDResponse.self, from: data) else {
            return nil
        }
        return response.responseContext?.visitorData
    }

    private static func fetchPlayerResponse(
        videoID: String,
        client: InnertubeClient,
        visitorData: String?
    ) async throws -> PlayerResponse {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")

        var clientContext = client.context
        clientContext["hl"] = "ja"
        clientContext["gl"] = "JP"
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            clientContext["visitorData"] = visitorData
        }
        let body: [String: Any] = [
            "videoId": videoID,
            "context": ["client": clientContext],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await HTTP.perform(request)
        guard http.statusCode == 200 else {
            throw ExtractError.apiError("YouTube API HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: data)
        } catch {
            throw ExtractError.apiError("レスポンスの解析に失敗しました")
        }
    }
}

// MARK: - Response models

private struct VisitorIDResponse: Decodable {
    struct ResponseContext: Decodable {
        let visitorData: String?
    }
    let responseContext: ResponseContext?
}

private struct PlayerResponse: Decodable {
    let playabilityStatus: PlayabilityStatus?
    let streamingData: StreamingData?
    let videoDetails: VideoDetails?
}

private struct PlayabilityStatus: Decodable {
    let status: String?
    let reason: String?
}

private struct StreamingData: Decodable {
    let formats: [StreamFormat]?
    let adaptiveFormats: [StreamFormat]?
}

private struct StreamFormat: Decodable {
    let itag: Int?
    let url: String?
    let mimeType: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let qualityLabel: String?
    /// JSON では文字列で返る
    let contentLength: String?

    var contentLengthBytes: Int? {
        contentLength.flatMap { Int($0) }
    }
}

private struct VideoDetails: Decodable {
    let title: String?
    let thumbnail: ThumbnailList?
}

private struct ThumbnailList: Decodable {
    let thumbnails: [Thumbnail]?
}

private struct Thumbnail: Decodable {
    let url: String?
}
