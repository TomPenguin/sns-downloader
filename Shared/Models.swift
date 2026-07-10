import Foundation

enum MediaType: String, Sendable {
    case photo
    case video
}

/// 抽出された 1 つのメディア(画像 or 動画)
struct MediaItem: Sendable {
    let url: URL
    let type: MediaType
    /// 保存ファイル名のベース(拡張子はダウンロード時に決定)
    let filenameBase: String
    /// 選択 UI に表示するサムネイル(動画で取得できない場合は nil)
    var thumbnailURL: URL? = nil
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
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "対応していないURLです(X / Instagram / TikTok の投稿URLを指定してください)"
        case .notFound:
            return "投稿が見つかりませんでした(削除済みの可能性があります)"
        case .noMedia:
            return "この投稿には画像・動画がありません"
        case .loginRequired:
            return "非公開アカウントかログインが必要な投稿のため取得できませんでした"
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
