import SwiftUI
import WebKit

/// アプリ内 WKWebView で Instagram にログインし、セッション Cookie を Keychain に保存する
struct InstagramLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didLogin = false

    var onComplete: (Bool) -> Void

    var body: some View {
        NavigationStack {
            LoginWebView { session in
                guard !didLogin else { return }
                didLogin = true
                session.save()
                onComplete(true)
                dismiss()
            }
            .navigationTitle("Instagramにログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        onComplete(false)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    /// sessionid Cookie が取得できたときに呼ばれる
    var onSession: (InstagramSession) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSession: onSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 以降の API リクエストと同じ UA でログインさせる
        webView.customUserAgent = HTTP.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://www.instagram.com/accounts/login/")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onSession: (InstagramSession) -> Void
        private var timer: Timer?

        init(onSession: @escaping (InstagramSession) -> Void) {
            self.onSession = onSession
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForSession(webView)
            // 2FA やリダイレクトでページ遷移しないケースがあるため定期チェックも行う
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak webView] _ in
                guard let webView else { return }
                self?.checkForSession(webView)
            }
        }

        private func checkForSession(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                var values: [String: String] = [:]
                for cookie in cookies where cookie.domain.contains("instagram.com") {
                    values[cookie.name] = cookie.value
                }
                let session = InstagramSession(cookies: values)
                if session.isValid {
                    self?.timer?.invalidate()
                    self?.timer = nil
                    self?.onSession(session)
                }
            }
        }

        deinit {
            timer?.invalidate()
        }
    }
}
