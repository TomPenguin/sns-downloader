import Foundation

/// 進捗コールバック付きのファイルダウンローダ。
/// ダウンロードタスクでディスクに直接書き込むため、大きな動画でもメモリを圧迫しない
/// (共有シート拡張のメモリ制限対策)。
final class Downloader: NSObject, @unchecked Sendable {

    static let shared = Downloader()

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private struct Handler {
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<URL, Error>
        let filenameBase: String
        let defaultExtension: String
    }

    private var handlers: [Int: Handler] = [:]
    private let lock = NSLock()

    /// ダウンロードして一時ディレクトリ内のファイル URL を返す。
    func download(
        _ item: MediaItem,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        var request = URLRequest(url: item.url)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.lock()
            handlers[task.taskIdentifier] = Handler(
                progress: progress,
                continuation: continuation,
                filenameBase: item.filenameBase,
                defaultExtension: item.defaultExtension
            )
            lock.unlock()
            task.resume()
        }
    }

    private func takeHandler(for task: URLSessionTask) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: task.taskIdentifier)
    }

    private func peekHandler(for task: URLSessionTask) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    private static func fileExtension(for task: URLSessionTask, fallback: String) -> String {
        // 1. URL の拡張子
        if let ext = task.originalRequest?.url?.pathExtension.lowercased(),
           ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v"].contains(ext) {
            return ext
        }
        // 2. MIME タイプ
        if let mime = (task.response as? HTTPURLResponse)?.mimeType?.lowercased() {
            switch mime {
            case "image/jpeg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/heic": return "heic"
            case "video/mp4": return "mp4"
            case "video/quicktime": return "mov"
            default: break
            }
        }
        return fallback
    }
}

extension Downloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let handler = peekHandler(for: downloadTask) else { return }
        handler.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let handler = takeHandler(for: downloadTask) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            handler.continuation.resume(throwing: SaveError.httpError(http.statusCode))
            return
        }

        let ext = Self.fileExtension(for: downloadTask, fallback: handler.defaultExtension)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(handler.filenameBase)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(ext)

        do {
            // このデリゲートメソッドを抜けると location のファイルは消えるため、同期的に移動する
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            handler.continuation.resume(returning: destination)
        } catch {
            handler.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // 成功時は didFinishDownloadingTo で処理済み
        guard let handler = takeHandler(for: task) else { return }
        handler.continuation.resume(throwing: error)
    }
}
