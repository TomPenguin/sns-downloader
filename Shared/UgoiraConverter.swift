import AVFoundation
import Compression
import CoreGraphics
import Foundation
import ImageIO

enum UgoiraError: LocalizedError {
    case emptyFrames
    case badZip
    case frameMissing(String)
    case decodeFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyFrames:
            return "うごイラのフレームがありません"
        case .badZip:
            return "うごイラのデータ(ZIP)を展開できませんでした"
        case .frameMissing(let name):
            return "うごイラのフレーム \(name) が見つかりませんでした"
        case .decodeFailed:
            return "うごイラのフレーム画像を読み込めませんでした"
        case .writerFailed(let message):
            return "うごイラの動画化に失敗しました: \(message)"
        }
    }
}

/// pixiv のうごイラ(フレーム画像を収めた ZIP + フレームごとの表示時間)を
/// mp4 動画に組み立てる。フレームの遅延をそのまま各フレームの表示時間として
/// 可変フレームレートで書き出すので、元のテンポを保てる。
enum UgoiraConverter {

    /// フレーム ZIP を mp4 に変換して一時ディレクトリ内のファイル URL を返す。
    static func convert(zipFile: URL, frames: [UgoiraFrame], filenameBase: String) throws -> URL {
        guard !frames.isEmpty else { throw UgoiraError.emptyFrames }

        let data = try Data(contentsOf: zipFile)
        let entries = try ZipReader.entries(in: data)

        // フレーム順に CGImage と遅延(ミリ秒)を並べる
        var images: [(image: CGImage, delayMS: Int)] = []
        images.reserveCapacity(frames.count)
        for frame in frames {
            guard let bytes = entries[frame.file] else { throw UgoiraError.frameMissing(frame.file) }
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw UgoiraError.decodeFailed
            }
            images.append((image, max(frame.delayMS, 10)))
        }
        guard let first = images.first else { throw UgoiraError.emptyFrames }

        // H.264 は偶数サイズを要求するため切り捨てる
        let width = first.image.width & ~1
        let height = first.image.height & ~1
        guard width > 0, height > 0 else { throw UgoiraError.decodeFailed }

        return try write(images: images, width: width, height: height, filenameBase: filenameBase)
    }

    private static func write(
        images: [(image: CGImage, delayMS: Int)],
        width: Int,
        height: Int,
        filenameBase: String
    ) throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenameBase)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: output)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw UgoiraError.writerFailed("入力を追加できませんでした") }
        writer.add(input)

        guard writer.startWriting() else {
            throw UgoiraError.writerFailed(writer.error?.localizedDescription ?? "開始できませんでした")
        }
        // ミリ秒精度のタイムスケール
        let timescale: CMTimeScale = 1000
        writer.startSession(atSourceTime: .zero)

        // 各フレームを「直前までの遅延の累計」の時刻に置く。可変フレームレート。
        // index / elapsedMS / appendError はすべて同じシリアルキュー上でのみ触る。
        var index = 0
        var elapsedMS = 0
        var appendError: Error?
        let queue = DispatchQueue(label: "ugoira.write")
        let semaphore = DispatchSemaphore(value: 0)

        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if index >= images.count {
                    input.markAsFinished()
                    semaphore.signal()
                    return
                }
                let frame = images[index]
                let time = CMTime(value: CMTimeValue(elapsedMS), timescale: timescale)
                do {
                    let buffer = try pixelBuffer(
                        from: frame.image, width: width, height: height, pool: adaptor.pixelBufferPool)
                    if !adaptor.append(buffer, withPresentationTime: time) {
                        throw UgoiraError.writerFailed(
                            writer.error?.localizedDescription ?? "フレームの追加に失敗しました")
                    }
                } catch {
                    appendError = error
                    input.markAsFinished()
                    semaphore.signal()
                    return
                }
                elapsedMS += frame.delayMS
                index += 1
            }
        }
        semaphore.wait()

        if let appendError {
            writer.cancelWriting()
            throw appendError
        }

        // 最終フレームの表示時間も含めた総尺でセッションを閉じる
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(elapsedMS), timescale: timescale))

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        guard writer.status == .completed else {
            throw UgoiraError.writerFailed(writer.error?.localizedDescription ?? "書き込みに失敗しました")
        }
        return output
    }

    /// CGImage を BGRA の CVPixelBuffer に描画する
    private static func pixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                &pixelBuffer
            )
        }
        guard let buffer = pixelBuffer else { throw UgoiraError.writerFailed("バッファを作成できませんでした") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw UgoiraError.writerFailed("描画コンテキストを作成できませんでした")
        }
        // 元画像のアスペクトを保ちつつ枠に収める(端数切り捨てで縦横が変わる場合の保険)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
