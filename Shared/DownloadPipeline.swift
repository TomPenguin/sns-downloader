import Foundation

/// URL 1 件分の処理状態
enum JobStatus: Equatable, Sendable {
    case waiting
    case extracting
    case selecting
    case downloading(current: Int, total: Int, fraction: Double)
    case done(saved: Int)
    case failed(String)

    var label: String {
        switch self {
        case .waiting: return "待機中"
        case .extracting: return "解析中…"
        case .selecting: return "メディアを選択してください"
        case .downloading(let current, let total, _):
            return total > 1 ? "ダウンロード中 (\(current)/\(total))" : "ダウンロード中"
        case .done(let saved): return "保存完了(\(saved)件)"
        case .failed(let message): return message
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// 抽出 → ダウンロード → 写真ライブラリ保存 の共通パイプライン
/// (本体アプリと共有シート拡張の両方から使う)
enum DownloadPipeline {

    /// 1 つの投稿 URL を処理する(全メディアを保存)。共有拡張のフォールバック用。
    /// `pixivRestrictedMessage` を渡すと、pixiv の R-18 等(要ログイン)で失敗したときに
    /// その文言を代わりに表示する(共有拡張は本体アプリのログインを読めないため、
    /// 「本体アプリで開いてください」と案内する用途)。
    static func run(
        url: URL,
        pixivRestrictedMessage: String? = nil,
        onStatus: @escaping @Sendable (JobStatus) -> Void
    ) async -> JobStatus {
        do {
            onStatus(.extracting)
            let items = try await ExtractorRouter.extract(from: url)
            return await downloadAndSave(items: items, onStatus: onStatus)
        } catch {
            let message: String
            if case ExtractError.pixivRestricted = error, let override = pixivRestrictedMessage {
                message = override
            } else {
                message = Self.message(for: error)
            }
            let result = JobStatus.failed(message)
            onStatus(result)
            return result
        }
    }

    /// メディア一覧をダウンロードして写真ライブラリに保存する。
    /// 進捗 fraction は全メディアを通した全体進捗(0.0〜1.0)。
    static func downloadAndSave(
        items: [MediaItem],
        onStatus: @escaping @Sendable (JobStatus) -> Void
    ) async -> JobStatus {
        do {
            try await PhotoSaver.ensurePermission()

            var saved = 0
            let total = items.count
            for (index, item) in items.enumerated() {
                let current = index + 1
                onStatus(.downloading(current: current, total: total, fraction: Double(index) / Double(total)))

                let fileURL = try await fetchFile(for: item) { itemFraction in
                    let overall = (Double(index) + itemFraction) / Double(total)
                    onStatus(.downloading(current: current, total: total, fraction: overall))
                }
                // 拡張子は MIME タイプから決定済みなので、保存タイプは実ファイルに合わせる
                // (抽出時の photo/video 判定が外れていても正しく保存できる)
                let actualType: MediaType = ["mp4", "mov", "m4v"].contains(fileURL.pathExtension.lowercased())
                    ? .video : .photo
                try await PhotoSaver.save(fileURL: fileURL, type: actualType)
                saved += 1
            }

            let result = JobStatus.done(saved: saved)
            onStatus(result)
            return result
        } catch {
            let result = JobStatus.failed(Self.message(for: error))
            onStatus(result)
            return result
        }
    }

    /// 1 メディア分のファイルを用意する。
    /// 音声が別ストリームの場合(YouTube 高画質)は映像・音声を順に落として合成する。
    private static func fetchFile(
        for item: MediaItem,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // うごイラ: フレーム ZIP を落として mp4 に組み立てる
        if let frames = item.ugoiraFrames {
            let zipFile = try await Downloader.shared.download(
                url: item.url,
                filenameBase: item.filenameBase,
                defaultExtension: "zip",
                headers: item.httpHeaders
            ) { progress($0 * 0.8) }
            defer { try? FileManager.default.removeItem(at: zipFile) }
            let mp4 = try UgoiraConverter.convert(
                zipFile: zipFile, frames: frames, filenameBase: item.filenameBase)
            progress(1.0)
            return mp4
        }

        guard let audioURL = item.audioURL else {
            return try await Downloader.shared.download(item, progress: progress)
        }

        // 映像 0.0〜0.75 → 音声 0.75〜0.95 → 合成 → 1.0
        let videoFile = try await Downloader.shared.download(item) { progress($0 * 0.75) }
        let audioFile = try await Downloader.shared.download(
            url: audioURL,
            filenameBase: item.filenameBase + "_audio",
            defaultExtension: "m4a",
            headers: item.httpHeaders,
            chunkSize: item.downloadChunkSize
        ) { progress(0.75 + $0 * 0.2) }
        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }
        let muxed = try await MediaMuxer.mux(
            videoFile: videoFile, audioFile: audioFile, filenameBase: item.filenameBase)
        progress(1.0)
        return muxed
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
