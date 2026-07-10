import Foundation

enum HTTP {
    static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request)
    }

    static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// リダイレクトを追わずに Location ヘッダの URL を返す(3xx でなければ nil)
    static func redirectLocation(for url: URL, headers: [String: String] = [:]) async throws -> URL? {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else {
            return nil
        }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    /// テキスト中から最初の http(s) URL を取り出す
    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, url.scheme == "http" || url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// テキスト中のすべての http(s) URL
    static func allURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, url.scheme == "http" || url.scheme == "https" else { return nil }
            return url
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // リダイレクトを追わない
    }
}

extension String {
    /// NSRegularExpression の最初のマッチのキャプチャグループ 1 を返す
    func firstMatchGroup(pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              match.numberOfRanges >= 2,
              let groupRange = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[groupRange])
    }

    /// JSON 文字列としてエスケープされた URL を復元する("\/" と "\uXXXX")
    func unescapedJSONString() -> String {
        var result = replacingOccurrences(of: "\\/", with: "/")
        while let range = result.range(of: #"\\u([0-9a-fA-F]{4})"#, options: .regularExpression) {
            let hex = String(result[range].dropFirst(2))
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                result.replaceSubrange(range, with: String(Character(scalar)))
            } else {
                break
            }
        }
        return result
    }
}
