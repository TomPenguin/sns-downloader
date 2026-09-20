import Foundation

/// Instagram のログインセッション(Cookie)。
/// 本体アプリの WKWebView ログインで取得し、Keychain 経由で共有シート拡張からも使う。
struct InstagramSession: Codable {
    private static let keychainKey = "instagram.cookies"
    /// セッション切れを検知したことを示すマーカー(再ログイン導線の表示に使う)
    private static let expiredKey = "instagram.expired"

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
        KeychainStore.delete(forKey: Self.expiredKey)
    }

    static func clear() {
        KeychainStore.delete(forKey: keychainKey)
        KeychainStore.delete(forKey: expiredKey)
    }

    // MARK: - セッション切れ

    /// API に Cookie を拒否されたときに呼ぶ。
    /// 使えない Cookie は消したうえで「要再ログイン」を記録し、
    /// 本体アプリ・共有シート拡張の両方で再ログインを促せるようにする
    static func markExpired() {
        KeychainStore.delete(forKey: keychainKey)
        KeychainStore.save(Data([1]), forKey: expiredKey)
    }

    /// 再ログインを促すべきか(ログイン済みだったセッションが切れたか)
    static var needsRelogin: Bool {
        KeychainStore.load(forKey: expiredKey) != nil
    }
}
