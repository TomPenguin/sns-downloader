import SwiftUI
import WebKit

/// アプリ内 WKWebView で iwara にログインし、トークンを Keychain に保存する。
/// pixiv / Instagram は Cookie を拾うが、iwara のフロントエンドは
/// localStorage の "token" に長期トークンを書き込むのでそこから取る
struct IwaraLoginView: View {
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
            .navigationTitle("iwaraにログイン")
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
    /// トークンが取得できたときに呼ばれる
    var onSession: (IwaraSession) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSession: onSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // ここでは UA を差し替えない。iwara は Cloudflare の判定を通す必要があり、
        // 素の WKWebView の UA のままが一番素直に通る。認証もトークン方式なので、
        // pixiv のように API 側と UA を揃える必要がない
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://www.iwara.tv/login")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onSession: (IwaraSession) -> Void
        private var timer: Timer?

        init(onSession: @escaping (IwaraSession) -> Void) {
            self.onSession = onSession
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForToken(webView)
            // SPA なのでログイン成功でもページ遷移が起きないことがあり、
            // didFinish だけでは拾えない。定期的に確認する
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak webView] _ in
                guard let webView else { return }
                self?.checkForToken(webView)
            }
        }

        private func checkForToken(_ webView: WKWebView) {
            webView.evaluateJavaScript("localStorage.getItem('token')") { [weak self] result, _ in
                guard let token = result as? String, !token.isEmpty else { return }
                self?.timer?.invalidate()
                self?.timer = nil
                self?.onSession(IwaraSession(refreshToken: token))
            }
        }

        deinit {
            timer?.invalidate()
        }
    }
}
