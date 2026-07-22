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
        try await download(
            url: item.url,
            filenameBase: item.filenameBase,
            defaultExtension: item.defaultExtension,
            headers: item.httpHeaders,
            chunkSize: item.downloadChunkSize,
            progress: progress
        )
    }

    /// 任意の URL をダウンロードして一時ディレクトリ内のファイル URL を返す。
    func download(
        url: URL,
        filenameBase: String,
        defaultExtension: String,
        headers: [String: String] = [:],
        chunkSize: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        if let chunkSize {
            return try await downloadInChunks(
                url: url,
                filenameBase: filenameBase,
                defaultExtension: defaultExtension,
                headers: headers,
                chunkSize: chunkSize,
                progress: progress
            )
        }
        var request = URLRequest(url: url)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.lock()
            handlers[task.taskIdentifier] = Handler(
                progress: progress,
                continuation: continuation,
                filenameBase: filenameBase,
                defaultExtension: defaultExtension
            )
            lock.unlock()
            task.resume()
        }
    }

    /// Range リクエストで分割ダウンロードする。
    /// YouTube (googlevideo) は一定サイズを超える一括取得を 403 で拒否するため、
    /// チャンクごとに取得してファイルに追記していく(2026-07 時点で 10MB は許容、
    /// 40MB や Range なしは 403)。
    private func downloadInChunks(
        url: URL,
        filenameBase: String,
        defaultExtension: String,
        headers: [String: String],
        chunkSize: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var destination: URL?
        var handle: FileHandle?
        defer { try? handle?.close() }

        var offset = 0
        var total = Int.max
        while offset < total {
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)", forHTTPHeaderField: "Range")
            let (data, http) = try await HTTP.perform(request)
            guard (200...299).contains(http.statusCode) else {
                throw SaveError.httpError(http.statusCode)
            }

            if destination == nil {
                let ext = Self.fileExtension(
                    urlExtension: url.pathExtension,
                    mimeType: http.mimeType,
                    fallback: defaultExtension
                )
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(filenameBase)_\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(ext)
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                handle = try FileHandle(forWritingTo: dest)
                destination = dest
            }

            if http.statusCode == 200 {
                // サーバが Range を無視して全量を返した
                total = data.count
            } else if total == Int.max {
                total = Self.contentRangeTotal(from: http) ?? (offset + data.count)
            }

            guard !data.isEmpty else { break } // 想定外の空レスポンスで無限ループしないように
            try handle?.write(contentsOf: data)
            offset += data.count
            progress(min(1.0, Double(offset) / Double(total)))
        }

        guard let destination else {
            throw URLError(.badServerResponse)
        }
        return destination
    }

    /// Content-Range ヘッダ ("bytes 0-9/1234") から全体サイズを取り出す
    private static func contentRangeTotal(from response: HTTPURLResponse) -> Int? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let totalString = contentRange.split(separator: "/").last,
              let total = Int(totalString) else {
            return nil
        }
        return total
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
        fileExtension(
            urlExtension: task.originalRequest?.url?.pathExtension,
            mimeType: (task.response as? HTTPURLResponse)?.mimeType,
            fallback: fallback
        )
    }

    private static func fileExtension(urlExtension: String?, mimeType: String?, fallback: String) -> String {
        // 1. URL の拡張子
        if let ext = urlExtension?.lowercased(),
           ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v"].contains(ext) {
            return ext
        }
        // 2. MIME タイプ
        if let mime = mimeType?.lowercased() {
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
