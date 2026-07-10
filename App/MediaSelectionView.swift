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
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        ZStack {
                            Color(.secondarySystemBackground)
                            ProgressView()
                        }
                    }
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
