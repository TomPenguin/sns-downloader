import Foundation

/// HLS / DASH に共通するエラー
enum StreamError: LocalizedError {
    case encrypted
    case live
    case emptySegments
    case unsupportedSegment
    case manifestParseFailed
    case segmentFailed(Int)

    var errorDescription: String? {
        switch self {
        case .encrypted:
            return "暗号化されたストリームには対応していません"
        case .live:
            return "ライブ配信には対応していません"
        case .emptySegments:
            return "再生できるセグメントがありません"
        case .unsupportedSegment:
            return "この配信形式には対応していません(MPEG-TS / fMP4 以外)"
        case .manifestParseFailed:
            return "マニフェストを解析できませんでした"
        case .segmentFailed(let code):
            return "セグメントの取得に失敗しました(HTTP \(code))"
        }
    }
}

/// 初期化セグメント + 分割セグメントを 1 本の動画ファイルにまとめる。
/// HLS の fMP4 と DASH で同じ処理になるので共通化している
enum SegmentAssembler {

    /// セグメントを順に連結して fragmented mp4 を作り、通常の mp4 に書き直して返す
    static func assembleFragmentedMP4(
        initSegment: URL?,
        segments: [URL],
        filenameBase: String,
        headers: [String: String],
        onSegment: (Int) -> Void = { _ in }
    ) async throws -> URL {
        let joined = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenameBase)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: joined)
        FileManager.default.createFile(atPath: joined.path, contents: nil)
        let handle = try FileHandle(forWritingTo: joined)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: joined)
        }

        if let initSegment {
            try handle.write(contentsOf: await fetchData(initSegment, headers: headers))
        }
        for (index, segment) in segments.enumerated() {
            try handle.write(contentsOf: await fetchData(segment, headers: headers))
            onSegment(index + 1)
        }
        try handle.close()

        return try await MediaMuxer.remux(file: joined, filenameBase: filenameBase)
    }

    static func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        let data = try await fetchData(url, headers: headers)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StreamError.manifestParseFailed
        }
        return text
    }

    static func fetchData(_ url: URL, headers: [String: String]) async throws -> Data {
        let (data, http) = try await HTTP.get(url, headers: headers)
        guard (200...299).contains(http.statusCode) else {
            throw StreamError.segmentFailed(http.statusCode)
        }
        return data
    }
}
