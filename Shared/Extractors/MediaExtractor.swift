import Foundation

protocol MediaExtractor: Sendable {
    func canHandle(_ url: URL) -> Bool
    func extract(from url: URL) async throws -> [MediaItem]
}

enum ExtractorRouter {
    static let extractors: [any MediaExtractor] = [
        TwitterExtractor(),
        InstagramExtractor(),
        TikTokExtractor(),
        YouTubeExtractor(),
        PixivExtractor(),
    ]

    static func extract(from url: URL) async throws -> [MediaItem] {
        guard let extractor = extractors.first(where: { $0.canHandle(url) }) else {
            throw ExtractError.unsupportedURL
        }
        let items = try await extractor.extract(from: url)
        guard !items.isEmpty else {
            throw ExtractError.noMedia
        }
        return items
    }
}
