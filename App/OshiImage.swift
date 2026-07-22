import SwiftUI

/// トリミング画面へ渡す元画像(fullScreenCover(item:) 用)
struct CropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 推し画像(アプリ背景)の保存・読み込み。
/// アプリコンテナ内に JPEG で永続化する(写真ライブラリへの依存を残さない)。
@MainActor
final class OshiImageStore: ObservableObject {
    static let shared = OshiImageStore()

    @Published private(set) var image: UIImage?

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oshi.jpg")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            image = UIImage(data: data)
        }
    }

    func save(_ newImage: UIImage) {
        guard let data = newImage.jpegData(compressionQuality: 0.92) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        image = newImage
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }
}

/// 推し画像のトリミング画面。
/// 画面と同じ縦横比の枠に、ドラッグ・ピンチで位置とサイズを合わせて切り出す。
struct OshiCropView: View {
    let source: UIImage
    let onCrop: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = Self.cropFrame(in: size)

            ZStack {
                Color.black.ignoresSafeArea()

                imageView(frame: frame, in: size)

                dimOverlay(frame: frame, in: size)

                VStack {
                    Text("ドラッグとピンチで表示範囲を調整")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.top, 8)
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            onCancel()
                        } label: {
                            Text("キャンセル")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .background(.ultraThinMaterial, in: Capsule())

                        Button {
                            if let cropped = crop(in: size) {
                                onCrop(cropped)
                            } else {
                                onCancel()
                            }
                        } label: {
                            Text("この範囲に設定")
                                .bold()
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragAndZoom(in: size))
        }
    }

    // MARK: - 表示

    private func imageView(frame: CGRect, in size: CGSize) -> some View {
        let total = totalScale(frame: frame)
        return Image(uiImage: source)
            .resizable()
            .frame(width: source.size.width * total, height: source.size.height * total)
            .position(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
    }

    /// 枠の外側を暗くして、枠線を描く
    private func dimOverlay(frame: CGRect, in size: CGSize) -> some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Path(frame.insetBy(dx: -0.75, dy: -0.75))
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - ジェスチャ

    private func dragAndZoom(in size: CGSize) -> some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { value in
                    offset = clamped(
                        CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        ), in: size)
                }
                .onEnded { _ in lastOffset = offset },
            MagnificationGesture()
                .onChanged { value in
                    scale = min(8, max(1, lastScale * value))
                    offset = clamped(offset, in: size)
                }
                .onEnded { _ in
                    lastScale = scale
                    lastOffset = offset
                }
        )
    }

    /// 画像が枠から外れない範囲にオフセットを制限する
    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let frame = Self.cropFrame(in: size)
        let total = totalScale(frame: frame)
        let maxX = max(0, (source.size.width * total - frame.width) / 2)
        let maxY = max(0, (source.size.height * total - frame.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }

    // MARK: - 切り出し

    private func crop(in size: CGSize) -> UIImage? {
        let frame = Self.cropFrame(in: size)
        let image = Self.normalized(source)
        let total = totalScale(frame: frame)
        let width = image.size.width * total
        let height = image.size.height * total
        let originX = size.width / 2 + offset.width - width / 2
        let originY = size.height / 2 + offset.height - height / 2
        var rect = CGRect(
            x: (frame.minX - originX) / total,
            y: (frame.minY - originY) / total,
            width: frame.width / total,
            height: frame.height / total
        )
        rect = rect.intersection(CGRect(origin: .zero, size: image.size))
        guard !rect.isEmpty, let cg = image.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 表示中の画像の拡大率(枠を覆う最小倍率 × ユーザーのピンチ倍率)
    private func totalScale(frame: CGRect) -> CGFloat {
        max(frame.width / source.size.width, frame.height / source.size.height) * scale
    }

    /// 画面と同じ縦横比の切り出し枠(中央配置)
    private static func cropFrame(in size: CGSize) -> CGRect {
        let ratio: CGFloat = 0.82
        let width = size.width * ratio
        let height = size.height * ratio
        return CGRect(
            x: (size.width - width) / 2, y: (size.height - height) / 2,
            width: width, height: height)
    }

    /// EXIF の向きを反映した .up 向きの画像に描き直す(cgImage.cropping は向きを見ないため)
    private static func normalized(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.scale == 1 { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
