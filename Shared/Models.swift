import Foundation

enum MediaType: String, Sendable {
    case photo
    case video
}

/// うごイラ(pixiv のアニメーション)の 1 フレーム。
/// ZIP 内のファイル名と表示時間(ミリ秒)を持つ
struct UgoiraFrame: Sendable {
    let file: String
    let delayMS: Int
}

/// 抽出された 1 つのメディア(画像 or 動画)
struct MediaItem: Sendable {
    let url: URL
    let type: MediaType
    /// 保存ファイル名のベース(拡張子はダウンロード時に決定)
    let filenameBase: String
    /// 選択 UI に表示するサムネイル(動画で取得できない場合は nil)
    var thumbnailURL: URL? = nil
    /// 音声が別ストリームの動画(YouTube 高画質など)の音声 URL。
    /// 非 nil の場合、映像・音声を別々にダウンロードして合成してから保存する
    var audioURL: URL? = nil
    /// ダウンロード時に付与する HTTP ヘッダ。
    /// YouTube はストリーム URL を発行したクライアントと同じ User-Agent で
    /// ダウンロードしないと 403 になることがある
    var httpHeaders: [String: String] = [:]
    /// Range リクエストによる分割ダウンロードのチャンクサイズ(バイト)。
    /// YouTube は一定サイズを超える取得を 403 で拒否するため、指定時は分割して落とす
    var downloadChunkSize: Int? = nil
    /// うごイラの場合のフレーム情報。非 nil のとき、url は各フレーム画像を収めた
    /// ZIP を指す。ダウンロード後に ZIP を展開して mp4 に組み立ててから保存する
    var ugoiraFrames: [UgoiraFrame]? = nil
    /// URL やレスポンスから拡張子が判定できない場合に使う拡張子
    var defaultExtension: String {
        type == .photo ? "jpg" : "mp4"
    }
}

enum ExtractError: LocalizedError {
    case unsupportedURL
    case notFound
    case noMedia
    case loginRequired
    case pixivRestricted
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "対応していないURLです(X / Instagram / TikTok / YouTube / pixiv の投稿URLを指定してください)"
        case .notFound:
            return "投稿が見つかりませんでした(削除済みの可能性があります)"
        case .noMedia:
            return "この投稿には画像・動画がありません"
        case .loginRequired:
            return "非公開アカウントかログインが必要な投稿のため取得できませんでした"
        case .pixivRestricted:
            return "取得できませんでした。R-18等の作品は、設定からpixivにログインし、pixiv側で「性的コンテンツを表示する」をONにしてください"
        case .apiError(let message):
            return "取得に失敗しました: \(message)"
        }
    }
}

enum SaveError: LocalizedError {
    case photoPermissionDenied
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .photoPermissionDenied:
            return "写真ライブラリへの追加が許可されていません。設定アプリから許可してください"
        case .httpError(let code):
            return "ダウンロードに失敗しました(HTTP \(code))"
        }
    }
}
