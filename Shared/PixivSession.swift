import Foundation

/// pixiv のログインセッション(Cookie)。
/// 本体アプリの WKWebView ログインで取得し、Keychain 経由で共有シート拡張からも使う。
/// R-18 などログインが必要な作品を取得するために AJAX API へ付与する。
struct PixivSession: Codable {
    private static let keychainKey = "pixiv.cookies"

    /// Cookie 名 → 値
    var cookies: [String: String]

    /// ログイン済みの PHPSESSID は "12345678_xxxxx"(ユーザー ID + "_" + ハッシュ)形式。
    /// pixiv は未ログイン(匿名)でも PHPSESSID を発行するため、単に存在するかではなく
    /// ユーザー ID プレフィックスの有無でログイン済みかを判定する。
    /// (これを見ないと、ログイン画面を開いた瞬間の匿名 Cookie を掴んで誤ってログイン済み扱いになる)
    var isValid: Bool {
        userID != nil
    }

    /// PHPSESSID の先頭(数字部分)がユーザー ID。匿名セッションでは nil
    var userID: String? {
        guard let session = cookies["PHPSESSID"],
              let underscore = session.firstIndex(of: "_") else {
            return nil
        }
        let id = String(session[session.startIndex..<underscore])
        return (!id.isEmpty && id.allSatisfy(\.isNumber)) ? id : nil
    }

    var cookieHeaderValue: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - 永続化

    static func load() -> PixivSession? {
        guard let data = KeychainStore.load(forKey: keychainKey),
              let session = try? JSONDecoder().decode(PixivSession.self, from: data),
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
