import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// 共有シートの入口。共有された URL をその場でダウンロードする。
/// 処理は本体アプリと同じ DownloadManager / 選択シート / 進行カプセルを使うので、
/// 直接ダウンロードしたときと体験が揃う
final class ShareViewController: UIViewController {

    private let manager = DownloadManager()
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        state.onClose = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        let host = UIHostingController(rootView: ShareRootView(manager: manager, state: state))
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
                self.state.loadError = "共有された内容からURLを取得できませんでした"
                return
            }
            self.state.sourceURL = url
            self.manager.addAndStart(text: url.absoluteString)
        }
    }
}

// MARK: - 共有シート固有の状態

@MainActor
final class ShareState: ObservableObject {
    @Published var sourceURL: URL?
    /// URL そのものが取れなかったときのメッセージ(ジョブにならないので別に持つ)
    @Published var loadError: String?
    var onClose: (() -> Void)?
}

// MARK: - 共有シートの画面

struct ShareRootView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var state: ShareState
    @State private var showInstagramLogin = false
    @State private var isClosing = false

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            if let url = state.sourceURL, manager.jobs.isEmpty {
                Text((url.host ?? "") + url.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)
            }

            if let message = state.loadError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if manager.jobs.isEmpty {
                ProgressView()
            }

            if manager.needsInstagramRelogin {
                InstagramReloginBanner { showInstagramLogin = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ForEach(manager.jobs) { job in
                JobCapsule(
                    job: job,
                    onRetry: { manager.retry(jobID: job.id) },
                    onDismiss: { manager.dismiss(jobID: job.id) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()

            Button {
                state.onClose?()
            } label: {
                Text(isFinished ? "閉じる" : "キャンセル")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .animation(.spring(duration: 0.35), value: manager.jobs)
        .animation(.spring(duration: 0.35), value: manager.needsInstagramRelogin)
        .sheet(item: $manager.activeSelection, onDismiss: {
            manager.handleSelectionDismiss()
        }) { selection in
            MediaSelectionView(
                selection: selection,
                onConfirm: { indices in
                    manager.confirmSelection(selection, selectedIndices: indices)
                },
                onCancel: {
                    manager.cancelSelection(selection)
                }
            )
        }
        .sheet(isPresented: $showInstagramLogin) {
            InstagramLoginView { _ in
                manager.refreshInstagramSessionState()
            }
        }
        // 保存完了(トースト発火)を合図に閉じる。本体アプリはトーストを出すだけで
        // 画面が残るが、共有シートは用が済んだら閉じるのが自然なのでここだけ差をつける
        .onChange(of: manager.toast) { toast in
            guard toast != nil, !isClosing else { return }
            isClosing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                state.onClose?()
            }
        }
    }

    private var isFinished: Bool {
        state.loadError != nil
            || (!manager.jobs.isEmpty && manager.jobs.allSatisfy { $0.status.isFinished })
    }
}
