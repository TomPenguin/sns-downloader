import Foundation

/// メディアファイルを直接指す URL を、サイト個別の解析なしに扱う。
///
/// 対応サイトに該当しない URL の受け皿なので、ルータの最後に置く。
/// 拡張子で判定するだけで、視聴ページの HTML を解析して動画を探すことはしない。
struct DirectMediaExtractor: MediaExtractor {

    // 写真ライブラリに保存できる形式だけを対象にする(webm や bmp は iOS で扱えない)
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let manifestExtensions: [String: ManifestFormat] = ["m3u8": .hls, "mpd": .dash]

    func canHandle(_ url: URL) -> Bool {
        Self.kind(of: url) != nil
    }

    func extract(from url: URL) async throws -> [MediaItem] {
        guard let kind = Self.kind(of: url) else { throw ExtractError.unsupportedURL }
        switch kind {
        case .photo:
            return [MediaItem(url: url, type: .photo, filenameBase: Self.filenameBase(for: url))]
        case .video:
            return [MediaItem(url: url, type: .video, filenameBase: Self.filenameBase(for: url))]
        case .manifest(let format):
            return [
                MediaItem(
                    url: url,
                    type: .video,
                    filenameBase: Self.filenameBase(for: url),
                    streamFormat: format
                )
            ]
        }
    }

    private enum Kind {
        case photo
        case video
        case manifest(ManifestFormat)
    }

    private static func kind(of url: URL) -> Kind? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        let ext = url.pathExtension.lowercased()
        if let format = manifestExtensions[ext] { return .manifest(format) }
        if videoExtensions.contains(ext) { return .video }
        if photoExtensions.contains(ext) { return .photo }
        return nil
    }

    /// URL のファイル名部分を保存名に使う。使えない文字は落とす
    private static func filenameBase(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let allowed = stem.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(allowed)).prefix(60)
        return cleaned.isEmpty ? "media_\(url.host ?? "download")" : String(cleaned)
    }
}
