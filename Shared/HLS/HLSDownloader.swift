import Foundation

/// m3u8 を読んでセグメントを落とし、1 本の mp4 にまとめる。
///
/// 対応するのは非暗号化の VOD プレイリストのみ。
/// セグメントが MPEG-TS なら自前のデマルチプレクサで mp4 に書き直し、
/// fMP4 なら初期化セグメントと連結してから書き直す。
enum HLSDownloader {

    static func download(
        playlistURL: URL,
        filenameBase: String,
        headers: [String: String] = [:],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let text = try await SegmentAssembler.fetchText(playlistURL, headers: headers)

        guard HLSPlaylist.isMaster(text) else {
            return try await buildStream(
                playlistURL: playlistURL,
                playlistText: text,
                filenameBase: filenameBase,
                headers: headers,
                progress: progress
            )
        }

        let variants = HLSPlaylist.variants(in: text, baseURL: playlistURL)
        guard let best = variants.max(by: { ($0.bandwidth, $0.height ?? 0) < ($1.bandwidth, $1.height ?? 0) })
        else {
            throw StreamError.emptySegments
        }

        // 音声が別プレイリストに分かれている場合は両方落として合成する
        let renditions = HLSPlaylist.audioRenditions(in: text, baseURL: playlistURL)
        let audioRendition = best.audioGroupID.flatMap { group in
            renditions.first { $0.groupID == group && $0.isDefault }
                ?? renditions.first { $0.groupID == group }
        }

        guard let audioRendition else {
            return try await buildStream(
                playlistURL: best.url,
                playlistText: nil,
                filenameBase: filenameBase,
                headers: headers,
                progress: progress
            )
        }

        let videoFile = try await buildStream(
            playlistURL: best.url,
            playlistText: nil,
            filenameBase: filenameBase,
            headers: headers,
            progress: { progress($0 * 0.6) }
        )
        let audioFile = try await buildStream(
            playlistURL: audioRendition.url,
            playlistText: nil,
            filenameBase: filenameBase + "_audio",
            headers: headers,
            progress: { progress(0.6 + $0 * 0.3) }
        )
        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }
        let muxed = try await MediaMuxer.mux(
            videoFile: videoFile, audioFile: audioFile, filenameBase: filenameBase)
        progress(1.0)
        return muxed
    }

    // MARK: - メディアプレイリスト 1 本分

    private static func buildStream(
        playlistURL: URL,
        playlistText: String?,
        filenameBase: String,
        headers: [String: String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let text: String
        if let playlistText {
            text = playlistText
        } else {
            text = try await SegmentAssembler.fetchText(playlistURL, headers: headers)
        }
        let media = HLSPlaylist.media(in: text, baseURL: playlistURL)
        guard !media.isEncrypted else { throw StreamError.encrypted }
        guard !media.segments.isEmpty else { throw StreamError.emptySegments }

        // ダウンロード 0.0〜0.9、書き出し 0.9〜1.0
        let total = Double(media.segments.count)
        func reportDownload(_ index: Int) {
            progress(Double(index) / total * 0.9)
        }

        if let initSegment = media.initSegment {
            let output = try await SegmentAssembler.assembleFragmentedMP4(
                initSegment: initSegment,
                segments: media.segments,
                filenameBase: filenameBase,
                headers: headers,
                onSegment: reportDownload
            )
            progress(1.0)
            return output
        }

        // 先頭セグメントの中身でコンテナを見分ける
        let first = try await SegmentAssembler.fetchData(media.segments[0], headers: headers)
        if first.first == 0x47 {
            let remuxer = TSRemuxer(filenameBase: filenameBase)
            try await remuxer.append(segment: first)
            reportDownload(1)
            for (index, segment) in media.segments.enumerated().dropFirst() {
                try await remuxer.append(
                    segment: SegmentAssembler.fetchData(segment, headers: headers))
                reportDownload(index + 1)
            }
            let output = try await remuxer.finish()
            progress(1.0)
            return output
        }
        guard Self.isMP4(first) else { throw StreamError.unsupportedSegment }

        let output = try await SegmentAssembler.assembleFragmentedMP4(
            initSegment: nil,
            segments: media.segments,
            filenameBase: filenameBase,
            headers: headers,
            onSegment: reportDownload
        )
        progress(1.0)
        return output
    }

    /// 先頭ボックスが ftyp / styp なら mp4 系
    private static func isMP4(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data.prefix(8))
        let type = String(bytes: bytes[4..<8], encoding: .ascii)
        return type == "ftyp" || type == "styp" || type == "moof" || type == "sidx"
    }
}
