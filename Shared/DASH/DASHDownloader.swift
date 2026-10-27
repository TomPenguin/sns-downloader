import Foundation

/// MPD を読んで映像・音声のセグメントを落とし、1 本の mp4 にまとめる。
///
/// DASH は映像と音声が別の Representation に分かれているのが普通なので、
/// それぞれを組み立ててから合成する。対応するのは非 DRM の VOD のみ。
enum DASHDownloader {

    static func download(
        manifestURL: URL,
        filenameBase: String,
        headers: [String: String] = [:],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let data = try await SegmentAssembler.fetchData(manifestURL, headers: headers)
        let manifest = try DASHManifest.parse(data, baseURL: manifestURL)

        guard !manifest.isProtected else { throw StreamError.encrypted }
        guard !manifest.isDynamic else { throw StreamError.live }

        let video = manifest.video.max { best($0, $1) }
        let audio = manifest.audio.max { best($0, $1) }
        guard video != nil || audio != nil else { throw StreamError.emptySegments }

        // 映像だけ・音声だけのマニフェストもあるので、ある方だけ組み立てる
        guard let video else {
            guard let audio else { throw StreamError.emptySegments }
            return try await buildStream(
                audio, filenameBase: filenameBase, headers: headers, progress: progress)
        }
        guard let audio else {
            return try await buildStream(
                video, filenameBase: filenameBase, headers: headers, progress: progress)
        }

        let videoFile = try await buildStream(
            video, filenameBase: filenameBase, headers: headers,
            progress: { progress($0 * 0.6) })
        let audioFile = try await buildStream(
            audio, filenameBase: filenameBase + "_audio", headers: headers,
            progress: { progress(0.6 + $0 * 0.3) })
        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }
        let muxed = try await MediaMuxer.mux(
            videoFile: videoFile, audioFile: audioFile, filenameBase: filenameBase)
        progress(1.0)
        return muxed
    }

    /// 画質の良い方を選ぶ基準
    private static func best(
        _ lhs: DASHManifest.Representation,
        _ rhs: DASHManifest.Representation
    ) -> Bool {
        (lhs.bandwidth, lhs.height ?? 0) < (rhs.bandwidth, rhs.height ?? 0)
    }

    private static func buildStream(
        _ representation: DASHManifest.Representation,
        filenameBase: String,
        headers: [String: String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // 分割されていない場合はそのまま 1 ファイル落とすだけでよい
        if let singleFile = representation.singleFile, representation.segments.isEmpty {
            return try await Downloader.shared.download(
                url: singleFile,
                filenameBase: filenameBase,
                defaultExtension: "mp4",
                headers: headers,
                progress: progress
            )
        }
        guard !representation.segments.isEmpty else { throw StreamError.emptySegments }

        // ダウンロード 0.0〜0.9、書き出し 0.9〜1.0
        let total = Double(representation.segments.count)
        let output = try await SegmentAssembler.assembleFragmentedMP4(
            initSegment: representation.initialization,
            segments: representation.segments,
            filenameBase: filenameBase,
            headers: headers,
            onSegment: { progress(Double($0) / total * 0.9) }
        )
        progress(1.0)
        return output
    }
}
