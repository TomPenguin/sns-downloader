import AVFoundation
import SwiftUI

/// 動画からサムネイルに使うフレームを選ぶシート。
/// 動画本体はダウンロードせず、リモート URL を指す AVURLAsset から該当時刻のフレームだけ取り出す。
struct VideoFrameSelectionView: View {
    let onSelect: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var loader: FrameLoader
    @State private var position: Double = 0

    init(item: MediaItem, onSelect: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        _loader = StateObject(wrappedValue: FrameLoader(url: item.url, headers: item.httpHeaders))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Color.black
                    preview
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // フレームが取れない動画(403・HLS など)ではスクラバを出さない
                if let duration = loader.duration {
                    scrubber(duration: duration)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("サムネイルにするフレーム")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") {
                        if let frame = loader.frame { onSelect(frame) }
                    }
                    .disabled(loader.frame == nil)
                }
            }
            .task { await loader.prepare() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let message = loader.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding()
        } else if let frame = loader.frame {
            Image(uiImage: frame)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView().tint(.white)
        }
    }

    private func scrubber(duration: Double) -> some View {
        VStack(spacing: 4) {
            Slider(value: $position, in: 0...duration) { editing in
                // ドラッグ中の要求はまとめて捨てられるので、離した位置だけは必ず取り直す
                if !editing { loader.requestFrame(at: position) }
            }
            HStack {
                Text(Self.timeLabel(position))
                Spacer()
                Text(Self.timeLabel(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: position) { loader.requestFrame(at: $0) }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// AVAssetImageGenerator でリモート動画から 1 フレームずつ取り出すローダ
@MainActor
private final class FrameLoader: ObservableObject {
    @Published var frame: UIImage?
    /// 尺(秒)。nil のままならフレームを取れていないのでスクラバを出さない
    @Published var duration: Double?
    @Published var errorMessage: String?

    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private var pendingTask: Task<Void, Never>?
    private var prepared = false

    init(url: URL, headers: [String: String]) {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            // AVURLAssetHTTPHeaderFieldsKey は非公開キーだが、Referer 必須の i.pximg.net や
            // User-Agent 必須の YouTube ではヘッダを付けないと 403 になり他に手段がない
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        asset = AVURLAsset(url: url, options: options)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 厳密な時刻を要求すると直前のキーフレームからデコードし直すことになりスクラブに
        // 追従できないため、わずかにずれた近いフレームで妥協する
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        // 用途は小さなセルのサムネイルなので、高解像度の動画を原寸でデコードさせない
        generator.maximumSize = CGSize(width: 720, height: 720)
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        do {
            let seconds = CMTimeGetSeconds(try await asset.load(.duration))
            guard seconds.isFinite, seconds > 0 else { throw FrameError.unavailable }
            frame = try await image(at: 0)
            duration = seconds
        } catch {
            // HLS や 403 の動画では尺もフレームも取れない。クラッシュさせず諦めて
            // 呼び出し元の既存サムネイル表示に任せる
            errorMessage = "この動画のフレームは取得できませんでした。元のサムネイルのままになります"
        }
    }

    func requestFrame(at seconds: Double) {
        guard duration != nil else { return }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            // スクラブ中は要求が連続するので少し待ち、途中の位置は描かずに最新だけ取りに行く
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self else { return }
            if let image = try? await self.image(at: seconds) {
                self.frame = image
            }
        }
    }

    private func image(at seconds: Double) async throws -> UIImage {
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return UIImage(cgImage: cgImage)
    }

    private enum FrameError: Error {
        case unavailable
    }
}
