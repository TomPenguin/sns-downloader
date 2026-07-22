import SwiftUI

/// 複数メディアの投稿から保存対象を選ぶシート
struct MediaSelectionView: View {
    let selection: PendingSelection
    let onConfirm: (Set<Int>) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<Int>

    init(selection: PendingSelection, onConfirm: @escaping (Set<Int>) -> Void, onCancel: @escaping () -> Void) {
        self.selection = selection
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // 初期状態は全選択
        _selected = State(initialValue: Set(selection.items.indices))
    }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(selection.items.indices, id: \.self) { index in
                        MediaCell(
                            item: selection.items[index],
                            isSelected: selected.contains(index)
                        ) {
                            if selected.contains(index) {
                                selected.remove(index)
                            } else {
                                selected.insert(index)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("保存するメディアを選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selected.count == selection.items.count ? "全解除" : "全選択") {
                        if selected.count == selection.items.count {
                            selected.removeAll()
                        } else {
                            selected = Set(selection.items.indices)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm(selected)
                } label: {
                    Text("\(selected.count)件を保存")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty)
                .padding()
                .background(.thinMaterial)
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct MediaCell: View {
    let item: MediaItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(minHeight: 100)
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )
                    .opacity(isSelected ? 1.0 : 0.45)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let url = item.thumbnailURL {
                // AsyncImage はカスタムヘッダを送れず、pixiv (i.pximg.net) など
                // Referer 必須の CDN では 403 になるため、ヘッダ対応の自前ローダを使う
                RemoteImageView(url: url, headers: item.httpHeaders) {
                    placeholder
                }
            } else {
                placeholder
            }

            if item.type == .video {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: item.type == .video ? "video" : "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

/// HTTP ヘッダ(Referer など)を付けて画像を取得できる AsyncImage 代替。
/// pixiv の i.pximg.net は Referer が無いと 403 になるため必要。
private struct RemoteImageView<Placeholder: View>: View {
    let url: URL
    let headers: [String: String]
    @ViewBuilder let placeholder: () -> Placeholder

    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if loader.failed {
                placeholder()
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    ProgressView()
                }
            }
        }
        .task { await loader.load(url: url, headers: headers) }
    }
}

@MainActor
private final class RemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false
    private var loaded = false

    func load(url: URL, headers: [String: String]) async {
        guard !loaded else { return }
        loaded = true
        var request = URLRequest(url: url)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = UIImage(data: data) else {
                failed = true
                return
            }
            self.image = image
        } catch {
            failed = true
        }
    }
}
