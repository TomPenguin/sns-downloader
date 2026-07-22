import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                inputArea
                actionButtons
                jobList
            }
            .padding()
            .navigationTitle("SNS Downloader")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了を消去") {
                        manager.clearFinished()
                    }
                    .disabled(!manager.jobs.contains { $0.status.isFinished })
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
        }
        .task {
            await autoPasteFromClipboard()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await autoPasteFromClipboard() }
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

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("X / Instagram / TikTok / YouTube の投稿URL(複数可・改行区切り)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $input)
                .focused($inputFocused)
                .frame(height: 100)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                if let pasted = UIPasteboard.general.string {
                    if !input.isEmpty && !input.hasSuffix("\n") {
                        input += "\n"
                    }
                    input += pasted
                }
            } label: {
                Label("ペースト", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                inputFocused = false
                manager.addAndStart(text: input)
                input = ""
            } label: {
                Label("ダウンロード", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(HTTP.allURLs(in: input).isEmpty)
        }
    }

    private var jobList: some View {
        List {
            if manager.jobs.isEmpty {
                Text("共有シートからも保存できます:\n各アプリで「共有」→「SNSに保存」")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(manager.jobs) { job in
                JobRow(job: job) {
                    manager.retry(jobID: job.id)
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct JobRow: View {
    let job: DownloadJob
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayURL)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.status.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if case .downloading(_, _, let fraction) = job.status {
                    ProgressView(value: fraction)
                }
            }

            Spacer()

            if case .failed = job.status {
                Button {
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayURL: String {
        let host = (job.sourceURL.host ?? "").replacingOccurrences(of: "www.", with: "")
        return host + job.sourceURL.path
    }

    private var iconName: String {
        switch job.status {
        case .waiting: return "clock"
        case .extracting: return "magnifyingglass"
        case .selecting: return "checklist"
        case .downloading: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var statusColor: Color {
        if case .failed = job.status { return .orange }
        return .secondary
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = InstagramSession.load()
    @State private var pixivSession = PixivSession.load()
    @State private var showLogin = false
    @State private var showPixivLogin = false

    var body: some View {
        NavigationStack {
            List {
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
                        }
                    } else {
                        Button {
                            showLogin = true
                        } label: {
                            Label("Instagramにログイン", systemImage: "person.crop.circle.badge.plus")
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
                }
            }
            .sheet(isPresented: $showPixivLogin) {
                PixivLoginView { success in
                    if success {
                        pixivSession = PixivSession.load()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DownloadManager())
}
