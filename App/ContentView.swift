import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var oshi = OshiImageStore.shared
    @State private var input = ""
    @State private var showSettings = false
    @State private var showInstagramLogin = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            background

            VStack(spacing: 12) {
                HStack {
                    settingsButton
                    Spacer()
                }
                Spacer()
                if oshi.image == nil {
                    oshiPlaceholder
                    Spacer()
                }
                if manager.needsInstagramRelogin {
                    InstagramReloginBanner { showInstagramLogin = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                jobCapsules
                inputArea
                downloadButton
            }
            .padding()

            toastOverlay
        }
        .animation(.spring(duration: 0.35), value: manager.toast)
        .animation(.spring(duration: 0.35), value: manager.jobs)
        .animation(.spring(duration: 0.35), value: manager.needsInstagramRelogin)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showInstagramLogin) {
            InstagramLoginView { _ in
                manager.refreshInstagramSessionState()
            }
        }
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
        .task {
            await autoPasteFromClipboard()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                manager.refreshInstagramSessionState()
                Task { await autoPasteFromClipboard() }
            }
        }
        .onChange(of: manager.toast) { toast in
            if toast != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// 起動・前面復帰時、入力欄が空でクリップボードに URL が含まれていれば自動でペーストする。
    /// `detectPatterns` で URL を含むときだけ実際に読み取るので、
    /// 無関係なテキストで「〜からペーストしました」通知が出るのを防ぐ。
    @MainActor
    private func autoPasteFromClipboard() async {
        guard input.isEmpty else { return }
        let patterns = try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL])
        guard patterns?.contains(\.probableWebURL) == true,
              let text = UIPasteboard.general.string,
              !HTTP.allURLs(in: text).isEmpty else {
            return
        }
        if input.isEmpty {
            input = text
        }
    }

    // MARK: - 背景(推し画像)

    @ViewBuilder
    private var background: some View {
        if let image = oshi.image {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            // 下部の操作エリアの視認性を確保するスクリム
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: - 進行状況(履歴は持たない)

    private var jobCapsules: some View {
        VStack(spacing: 8) {
            ForEach(manager.jobs) { job in
                JobCapsule(
                    job: job,
                    onRetry: { manager.retry(jobID: job.id) },
                    onDismiss: { manager.dismiss(jobID: job.id) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 入力・操作

    private var inputArea: some View {
        TextField(
            "X / Instagram / Threads / TikTok / YouTube / pixiv のURL(複数可)",
            text: $input,
            axis: .vertical
        )
        .lineLimit(2...5)
        .focused($inputFocused)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var downloadButton: some View {
        Button {
            inputFocused = false
            manager.addAndStart(text: input)
            input = ""
        } label: {
            Label("ダウンロード", systemImage: "arrow.down.circle.fill")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .disabled(HTTP.allURLs(in: input).isEmpty)
    }

    // MARK: - 推し画像未設定時のプレースホルダ

    private var oshiPlaceholder: some View {
        Button {
            showSettings = true
        } label: {
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("推し画像を設定しよう")
                    .font(.title3.bold())
                Text("設定から好きな画像を選ぶと\nアプリの背景に表示されます")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Label("設定を開く", systemImage: "gearshape.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .foregroundStyle(.primary)
            .padding(28)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 保存完了トースト

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = manager.toast {
            VStack {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                    Text(toast.text)
                        .font(.headline)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.top, 8)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .scale(scale: 0.8)).combined(with: .opacity))
        }
    }
}

// MARK: - 設定

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var oshi = OshiImageStore.shared
    @State private var session = InstagramSession.load()
    @State private var needsRelogin = InstagramSession.needsRelogin
    @State private var pixivSession = PixivSession.load()
    @State private var iwaraSession = IwaraSession.load()
    @State private var showLogin = false
    @State private var showPixivLogin = false
    @State private var showIwaraLogin = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropSource: CropSource?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let image = oshi.image {
                        HStack(spacing: 12) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("設定済み")
                        }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(
                            oshi.image == nil ? "推し画像を設定" : "推し画像を変更",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    if oshi.image != nil {
                        Button("推し画像を削除", role: .destructive) {
                            oshi.clear()
                        }
                    }
                } header: {
                    Text("推し画像")
                } footer: {
                    Text("選んだ画像がアプリの背景として全画面に表示されます。選択後にトリミングできます。")
                }

                Section {
                    if let current = session, current.isValid {
                        Label {
                            Text("ログイン済み" + (current.userID.map { "(ID: \($0))" } ?? ""))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Button("ログアウト", role: .destructive) {
                            InstagramSession.clear()
                            session = nil
                            needsRelogin = false
                        }
                    } else {
                        if needsRelogin {
                            Label {
                                Text("セッションが切れました")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Button {
                            showLogin = true
                        } label: {
                            Label(
                                needsRelogin ? "Instagramに再ログイン" : "Instagramにログイン",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                        }
                    }
                } header: {
                    Text("Instagram")
                } footer: {
                    Text("ログインすると、カルーセル(複数枚投稿)の全メディアと、フォロー中の非公開アカウントの投稿もダウンロードできるようになります。Cookieは端末のKeychainにのみ保存されます。")
                }

                Section {
                    if let current = pixivSession, current.isValid {
                        Label {
                            Text("ログイン済み" + (current.userID.map { "(ID: \($0))" } ?? ""))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Button("ログアウト", role: .destructive) {
                            PixivSession.clear()
                            pixivSession = nil
                        }
                    } else {
                        Button {
                            showPixivLogin = true
                        } label: {
                            Label("pixivにログイン", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                } header: {
                    Text("pixiv")
                } footer: {
                    Text("ログインすると、R-18・R-18Gなどログインが必要な作品もダウンロードできるようになります。pixivの設定で「性的コンテンツを表示する」を有効にしておいてください。Cookieは端末のKeychainにのみ保存されます。")
                }

                Section {
                    if let current = iwaraSession, current.isValid {
                        Label {
                            Text("ログイン済み")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Button("ログアウト", role: .destructive) {
                            IwaraSession.clear()
                            iwaraSession = nil
                        }
                    } else {
                        Button {
                            showIwaraLogin = true
                        } label: {
                            Label("iwaraにログイン", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                } header: {
                    Text("iwara")
                } footer: {
                    Text("未ログインだと360pしかダウンロードできません。ログインすると原本(Source)を含む全画質が選べるようになります。トークンは端末のKeychainにのみ保存されます。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                InstagramLoginView { success in
                    if success {
                        session = InstagramSession.load()
                    }
                    needsRelogin = InstagramSession.needsRelogin
                }
            }
            .sheet(isPresented: $showPixivLogin) {
                PixivLoginView { success in
                    if success {
                        pixivSession = PixivSession.load()
                    }
                }
            }
            .sheet(isPresented: $showIwaraLogin) {
                IwaraLoginView { success in
                    if success {
                        iwaraSession = IwaraSession.load()
                    }
                }
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        cropSource = CropSource(image: image)
                    }
                    pickerItem = nil
                }
            }
            .fullScreenCover(item: $cropSource) { source in
                OshiCropView(source: source.image) { cropped in
                    oshi.save(cropped)
                    cropSource = nil
                } onCancel: {
                    cropSource = nil
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DownloadManager())
}
