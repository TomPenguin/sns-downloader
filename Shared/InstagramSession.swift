import Foundation

/// Instagram のログインセッション(Cookie)。
/// 本体アプリの WKWebView ログインで取得し、Keychain 経由で共有シート拡張からも使う。
struct InstagramSession: Codable {
    private static let keychainKey = "instagram.cookies"

    /// Cookie 名 → 値
    var cookies: [String: String]

    var isValid: Bool {
        !(cookies["sessionid"] ?? "").isEmpty
    }

    var userID: String? {
        cookies["ds_user_id"]
    }

    var csrfToken: String? {
        cookies["csrftoken"]
    }

    var cookieHeaderValue: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - 永続化

    static func load() -> InstagramSession? {
        guard let data = KeychainStore.load(forKey: keychainKey),
              let session = try? JSONDecoder().decode(InstagramSession.self, from: data),
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
    }
}
