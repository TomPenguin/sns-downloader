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

    /// 1 つの投稿 URL を処理する(全メディアを保存)。共有拡張のフォールバック用
    static func run(
        url: URL,
        onStatus: @escaping @Sendable (JobStatus) -> Void
    ) async -> JobStatus {
        do {
            onStatus(.extracting)
            let items = try await ExtractorRouter.extract(from: url)
            return await downloadAndSave(items: items, onStatus: onStatus)
        } catch {
            let result = JobStatus.failed(Self.message(for: error))
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

                let fileURL = try await Downloader.shared.download(item) { itemFraction in
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

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
