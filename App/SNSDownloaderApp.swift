import SwiftUI

@main
struct SNSDownloaderApp: App {
    @StateObject private var manager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// 共有シート拡張からの起動: snsdl://download?url={対象URL}
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "snsdl" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !target.isEmpty else {
            return
        }
        manager.addAndStart(text: target)
    }
}
