import Foundation

/// iwara のログイン状態。
/// 本体アプリの WKWebView ログインで localStorage から長期トークンを取り出し、
/// Keychain 経由で共有シート拡張からも使う。API 呼び出しに使う短期のアクセス
/// トークンは、その長期トークンと引き換えに都度発行する。
///
/// 未ログインでも動画は取得できるが、配信される画質が 360p だけに制限される。
/// ログインすると Source(原本)を含む全画質が返るようになる。
struct IwaraSession: Codable {
    /// 同ファイルの IwaraTokenProvider から失効時に消すため fileprivate
    fileprivate static let keychainKey = "iwara.session"

    /// フロントエンドが localStorage に持っている長期トークン
    var refreshToken: String

    var isValid: Bool {
        !refreshToken.isEmpty
    }

    // MARK: - 永続化

    static func load() -> IwaraSession? {
        guard let data = KeychainStore.load(forKey: keychainKey),
              let session = try? JSONDecoder().decode(IwaraSession.self, from: data),
              session.isValid else {
            return nil
        }
        return session
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainStore.save(data, forKey: Self.keychainKey)
    }

    static func clear() {
        KeychainStore.delete(forKey: keychainKey)
        Task { await IwaraTokenProvider.shared.invalidate() }
    }
}

/// 短期アクセストークンをメモリ上でキャッシュする。
/// 本体アプリと共有シート拡張は別プロセスなので、キャッシュはプロセスごとに持つ
actor IwaraTokenProvider {
    static let shared = IwaraTokenProvider()

    private var cached: (token: String, expiresAt: Date)?

    /// 未ログイン・トークン失効時は nil を返す(その場合も 360p までは取得できる)
    func accessToken() async -> String? {
        // 期限ぎりぎりのトークンを使わないよう 1 分の余裕を見る
        if let cached, cached.expiresAt > Date().addingTimeInterval(60) {
            return cached.token
        }
        guard let session = IwaraSession.load() else { return nil }
        let result = await Self.exchange(refreshToken: session.refreshToken)
        if result.isRejected {
            // トークンが失効・失効済みなら保存を消す。残したままだと設定画面が
            // 「ログイン済み」を出しつつ 360p に落ちる、原因の分からない状態になる
            KeychainStore.delete(forKey: IwaraSession.keychainKey)
            return nil
        }
        guard let token = result.token else { return nil }
        // exp が読めなかった場合も一定時間はキャッシュする
        cached = (token, Self.expiry(ofJWT: token) ?? Date().addingTimeInterval(1800))
        return token
    }

    func invalidate() {
        cached = nil
    }

    /// 長期トークンを短期アクセストークンに交換する。
    /// 通信失敗と「トークンが受け付けられなかった」を区別する(前者で保存を消すと、
    /// 圏外だっただけでログアウトさせてしまう)
    private static func exchange(refreshToken: String) async -> (token: String?, isRejected: Bool) {
        var request = URLRequest(url: URL(string: "https://api.iwara.tv/user/token")!)
        request.httpMethod = "POST"
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")

        guard let (data, http) = try? await HTTP.perform(request) else {
            return (nil, false) // 通信失敗
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            return (nil, true)
        }
        guard http.statusCode == 200,
              let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            return (nil, false)
        }
        return (response.accessToken, false)
    }

    /// JWT のペイロード部から exp(失効時刻)を読む
    private static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url は末尾のパディングが省略される
        while base64.count % 4 != 0 {
            base64 += "="
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = payload["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}

private struct TokenResponse: Decodable {
    /// /user/login が返す長期トークン
    let token: String?
    /// /user/token が返す短期トークン
    let accessToken: String?
}
