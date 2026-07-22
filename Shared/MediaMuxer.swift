import AVFoundation
import Foundation

enum MuxError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画の合成に失敗しました(映像トラックがありません)"
        case .exportFailed(let message):
            return "動画の合成に失敗しました: \(message)"
        }
    }
}

/// 映像のみ・音声のみに分かれたストリームを 1 つの動画ファイルに合成する。
///
/// AVAssetReader → AVAssetWriter のサンプル単位パススルー(再エンコードなし)。
/// AVMutableComposition + AVAssetExportSession を使わないのは、YouTube の
/// fragmented mp4 (moof/mdat 構造) のコンテナ duration を AVFoundation が
/// 誤読して動画長が 2 倍になるため。サンプル単位のタイムスタンプは正しいので、
/// 末尾に混入する 0 バイトのダミーサンプルだけ捨てて書き直せば正しいファイルになる。
/// ストリーミング処理なのでメモリもほぼ使わない(共有シート拡張の制限内で動く)。
enum MediaMuxer {

    /// videoFile(映像のみ mp4)と audioFile(音声のみ m4a)を合成して
    /// 一時ディレクトリ内のファイル URL を返す。
    static func mux(videoFile: URL, audioFile: URL, filenameBase: String) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenameBase)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: output)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        // 映像(必須)
        let videoAsset = AVURLAsset(url: videoFile)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MuxError.noVideoTrack
        }
        let videoReader = try AVAssetReader(asset: videoAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoReader.add(videoOutput)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)

        // 音声(任意: 元動画が無音の場合もある)
        var audioReader: AVAssetReader?
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        let audioAsset = AVURLAsset(url: audioFile)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let reader = try AVAssetReader(asset: audioAsset)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: try await audioTrack.load(.formatDescriptions).first
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioReader = reader
            audioPair = (output, input)
        }

        guard writer.startWriting() else {
            throw writer.error ?? MuxError.exportFailed("書き込みを開始できませんでした")
        }
        writer.startSession(atSourceTime: .zero)
        guard videoReader.startReading() else {
            writer.cancelWriting()
            throw videoReader.error ?? MuxError.exportFailed("映像を読み込めませんでした")
        }
        if let audioReader, !audioReader.startReading() {
            writer.cancelWriting()
            throw audioReader.error ?? MuxError.exportFailed("音声を読み込めませんでした")
        }

        // ライターはトラックをインターリーブしながら書くため、片方ずつ順番に
        // 流すと相手のサンプル待ちでデッドロックする。必ず並行して流すこと
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(from: videoOutput, to: videoInput, queueLabel: "mux.video") }
            if let (output, input) = audioPair {
                group.addTask { await pump(from: output, to: input, queueLabel: "mux.audio") }
            }
        }

        if videoReader.status == .failed {
            writer.cancelWriting()
            throw videoReader.error ?? MuxError.exportFailed("映像の読み込みに失敗しました")
        }
        if let audioReader, audioReader.status == .failed {
            writer.cancelWriting()
            throw audioReader.error ?? MuxError.exportFailed("音声の読み込みに失敗しました")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MuxError.exportFailed("書き込みに失敗しました")
        }
        return output
    }

    /// リーダーからライターへ全サンプルを流し込む
    private static func pump(
        from output: AVAssetReaderTrackOutput,
        to input: AVAssetWriterInput,
        queueLabel: String
    ) async {
        let queue = DispatchQueue(label: queueLabel)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false // queue 上でのみ触る。continuation の二重 resume 防止
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                func finish() {
                    finished = true
                    input.markAsFinished()
                    continuation.resume()
                }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finish()
                        return
                    }
                    // AVFoundation は fragmented mp4 の末尾に 0 バイトのダミーサンプルを
                    // 返すことがある(誤読した duration の位置)。書き込むと動画長が壊れる
                    guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
                    guard input.append(sample) else {
                        finish()
                        return
                    }
                }
            }
        }
    }
}
