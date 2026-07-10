import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// 共有シートの入口。共有された URL を取り出し、
/// snsdl:// スキームで本体アプリを起動して即ダウンロードさせる。
/// 本体アプリを開けなかった場合は自動でその場ダウンロードにフォールバックする。
final class ShareViewController: UIViewController {

    private let model = ShareModel()
    private var targetURL: URL?
    private var hasAppeared = false
    private var openAttempted = false
    private var resolved = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        model.onClose = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        // 本体アプリが開く = このホストアプリが非アクティブになる、で起動成功を検知する
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWillResignActive),
            name: NSNotification.Name.NSExtensionHostWillResignActive,
            object: nil
        )

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        loadSharedURL()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        tryOpenMainAppIfReady()
    }

    // MARK: - 共有 URL の取得

    private func loadSharedURL() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        // URL 添付を優先し、なければテキストから URL を探す
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? String).flatMap { HTTP.firstURL(in: $0) }
                self?.didLoad(url: url)
            }
        } else if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                let url = (item as? String).flatMap { HTTP.firstURL(in: $0) }
                self?.didLoad(url: url)
            }
        } else {
            didLoad(url: nil)
        }
    }

    private func didLoad(url: URL?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let url else {
                self.model.status = .failed("共有された内容からURLを取得できませんでした")
                return
            }
            self.model.sourceURL = url
            self.targetURL = url
            self.tryOpenMainAppIfReady()
        }
    }

    // MARK: - 本体アプリの起動

    /// ビューが表示済み & URL 取得済みになったら一度だけ起動を試みる
    private func tryOpenMainAppIfReady() {
        guard hasAppeared, !openAttempted, let url = targetURL else { return }
        openAttempted = true

        var components = URLComponents()
        components.scheme = "snsdl"
        components.host = "download"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let deepLink = components.url else {
            fallbackToInPlace()
            return
        }

        openViaResponderChain(deepLink)

        // 一定時間たってもホストが非アクティブにならなければ起動失敗とみなし、
        // その場ダウンロードに自動フォールバック
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.fallbackToInPlace()
        }
    }

    /// 共有シート拡張から親アプリを開く(responder chain 経由の openURL:)
    private func openViaResponderChain(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }

    /// 本体アプリが開いた(ホストアプリが非アクティブになった)→ シートを閉じる
    @objc private func hostWillResignActive() {
        guard openAttempted, !resolved else { return }
        resolved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// アプリを起動できなかったときのその場ダウンロード
    private func fallbackToInPlace() {
        guard !resolved else { return }
        resolved = true
        model.startInPlace()
    }
}

// MARK: - その場ダウンロード UI

@MainActor
final class ShareModel: ObservableObject {
    @Published var status: JobStatus = .waiting
    @Published var sourceURL: URL?
    @Published var isDownloadingInPlace = false
    var onClose: (() -> Void)?

    func startInPlace() {
        guard let url = sourceURL, !isDownloadingInPlace else { return }
        isDownloadingInPlace = true
        Task {
            let result = await DownloadPipeline.run(url: url) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.status = status
                }
            }
            if case .done = result {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.onClose?()
            }
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 44))
                .foregroundStyle(iconColor)

            if let url = model.sourceURL {
                Text((url.host ?? "") + url.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)
            }

            Text(statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if case .downloading(_, _, let fraction) = model.status {
                ProgressView(value: fraction)
                    .padding(.horizontal, 40)
            } else if !model.status.isFinished {
                ProgressView()
            }

            Spacer()

            Button {
                model.onClose?()
            } label: {
                Text(model.status.isFinished ? "閉じる" : "キャンセル")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }

    private var statusText: String {
        if model.isDownloadingInPlace || model.status.isFinished {
            return model.status.label
        }
        return "アプリを起動しています…"
    }

    private var iconName: String {
        switch model.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.down.circle"
        }
    }

    private var iconColor: Color {
        switch model.status {
        case .done: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }
}
