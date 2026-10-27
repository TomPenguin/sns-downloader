import AVFoundation
import CoreMedia
import Foundation

enum TSRemuxError: LocalizedError {
    case noSupportedStream
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSupportedStream:
            return "この動画の形式には対応していません(H.264 / AAC 以外)"
        case .writeFailed(let message):
            return "動画の書き出しに失敗しました: \(message)"
        }
    }
}

/// サンプルを 1 本のトラックぶん溜める FIFO。
/// 取り出し側(AVAssetWriter の供給ブロック)は、データが来るまで待つ
private final class SampleQueue: @unchecked Sendable {
    private var items: [CMSampleBuffer] = []
    private var isClosed = false
    private let condition = NSCondition()

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return items.count
    }

    func enqueue(_ buffer: CMSampleBuffer) {
        condition.lock()
        items.append(buffer)
        condition.signal()
        condition.unlock()
    }

    /// これ以上サンプルが来ないことを伝える
    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    /// サンプルが入るまで待って返す。close 済みで空なら nil
    func dequeueWaiting() -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty && !isClosed {
            condition.wait()
        }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

/// MPEG-TS セグメントを順に受け取り、再エンコードせずに mp4 を書き出す。
///
/// セグメント 1 つ分ずつ処理するので、長い動画でもメモリはセグメント 1 つ分と
/// 書き込み待ちのサンプルしか使わない(共有シート拡張のメモリ制限内で動く)。
///
/// 映像・音声のフォーマットは最初の PES を読むまで分からないが、AVAssetWriter は
/// 入力を追加してからでないと書き始められない。そのため両方のフォーマットが
/// 判明するまでサンプルを溜めておき、判明した時点でライターを作る。
///
/// ライターへの書き込みは `requestMediaDataWhenReady` による引き取り方式にする。
/// 自前のループで `isReadyForMoreMediaData` を待ちながら順に append すると、
/// ライターが「もう一方のトラックのサンプル待ち」になった時点で、こちらも
/// 「ready 待ち」になって互いに止まる(映像と音声で取り合いになる)。
final class TSRemuxer {

    private let demuxer = TSDemuxer()
    private let videoBuilder = H264SampleBuilder()
    private let audioBuilder = AACSampleBuilder()

    /// 書き込み待ちで溜めるサンプル数の上限(超えたら取得側を待たせる)
    private static let queueLimit = 600

    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var videoQueue: SampleQueue?
    private var audioQueue: SampleQueue?
    private var buffered: [(buffer: CMSampleBuffer, isVideo: Bool)] = []
    private let lock = NSLock()
    private var inputsFinished = 0
    private var expectedInputs = 0
    private var failure: Error?

    init(filenameBase: String) {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenameBase)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)
    }

    func append(segment: Data) async throws {
        var samples: [(CMSampleBuffer, Bool)] = []
        try collect(into: &samples) { onPacket in
            demuxer.push(segment, onPacket: onPacket)
        }
        try await enqueue(samples)
    }

    func finish() async throws -> URL {
        var samples: [(CMSampleBuffer, Bool)] = []
        try collect(into: &samples) { onPacket in
            demuxer.flush(onPacket: onPacket)
        }
        try videoBuilder.flush { samples.append(($0, true)) }
        try await enqueue(samples)

        guard let writer else { throw TSRemuxError.noSupportedStream }
        videoQueue?.close()
        audioQueue?.close()

        // 供給ブロックが残りを書き終えるまで待つ
        while true {
            lock.lock()
            let done = inputsFinished >= expectedInputs
            let error = failure
            lock.unlock()
            if let error { throw error }
            if done { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TSRemuxError.writeFailed(writer.error?.localizedDescription ?? "不明なエラー")
        }
        return outputURL
    }

    // MARK: - デマルチプレクサから取り出す

    /// デマルチプレクサのコールバックは throw できないので、
    /// 組み立て中に出たエラーを拾って呼び出し側に投げ直す
    private func collect(
        into samples: inout [(CMSampleBuffer, Bool)],
        run: ((TSDemuxer.PESPacket) -> Void) -> Void
    ) throws {
        var collected: [(CMSampleBuffer, Bool)] = []
        var buildError: Error?
        run { packet in
            guard buildError == nil else { return }
            do {
                switch packet.kind {
                case .h264:
                    try videoBuilder.append(payload: packet.payload, pts: packet.pts, dts: packet.dts) {
                        collected.append(($0, true))
                    }
                case .aac:
                    try audioBuilder.append(payload: packet.payload, pts: packet.pts) {
                        collected.append(($0, false))
                    }
                }
            } catch {
                buildError = error
            }
        }
        if let buildError { throw buildError }
        samples.append(contentsOf: collected)
    }

    // MARK: - ライターへの受け渡し

    private func enqueue(_ samples: [(CMSampleBuffer, Bool)]) async throws {
        buffered.append(contentsOf: samples.map { (buffer: $0.0, isVideo: $0.1) })
        guard try startWriterIfReady() else { return }

        for entry in buffered {
            guard let queue = entry.isVideo ? videoQueue : audioQueue else { continue }
            while queue.count > Self.queueLimit {
                lock.lock()
                let error = failure
                lock.unlock()
                if let error { throw error }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            queue.enqueue(entry.buffer)
        }
        buffered.removeAll(keepingCapacity: true)

        lock.lock()
        let error = failure
        lock.unlock()
        if let error { throw error }
    }

    /// 必要なフォーマットが出揃っていればライターを作る。作成済みなら true
    private func startWriterIfReady() throws -> Bool {
        if writer != nil { return true }
        guard demuxer.hasStreams else { return false }

        let kinds = demuxer.kinds
        let expectsVideo = kinds.contains(.h264)
        let expectsAudio = kinds.contains(.aac)
        // 音声だけのプレイリスト(音声が別レンディションに分かれている場合)もある
        guard expectsVideo || expectsAudio else { throw TSRemuxError.noSupportedStream }
        if expectsVideo && videoBuilder.formatDescription == nil { return false }
        if expectsAudio && audioBuilder.formatDescription == nil { return false }
        guard !buffered.isEmpty else { return false }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        var videoInput: AVAssetWriterInput?
        if let videoFormat = videoBuilder.formatDescription {
            let input = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            videoInput = input
        }
        var audioInput: AVAssetWriterInput?
        if let audioFormat = audioBuilder.formatDescription {
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw TSRemuxError.writeFailed(writer.error?.localizedDescription ?? "開始できません")
        }
        // 溜めたサンプルのうち最も早い時刻から始める。これより前は書き込めない
        let start = buffered
            .map { CMSampleBufferGetPresentationTimeStamp($0.buffer) }
            .min { CMTimeCompare($0, $1) < 0 } ?? .zero
        writer.startSession(atSourceTime: start)

        expectedInputs = 0
        if let videoInput {
            let queue = SampleQueue()
            videoQueue = queue
            expectedInputs += 1
            attach(input: videoInput, queue: queue, label: "ts.video")
        }
        if let audioInput {
            let queue = SampleQueue()
            audioQueue = queue
            expectedInputs += 1
            attach(input: audioInput, queue: queue, label: "ts.audio")
        }
        self.writer = writer
        return true
    }

    /// ライターが要求してきたぶんだけキューから流し込む。
    /// キューが空でもまだ続きがある場合は、ブロック内で待つ
    /// (ready のまま return すると次に呼ばれる保証がないため)
    private func attach(input: AVAssetWriterInput, queue: SampleQueue, label: String) {
        input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) { [weak self] in
            guard let self else { return }
            while input.isReadyForMoreMediaData {
                guard let buffer = queue.dequeueWaiting() else {
                    input.markAsFinished()
                    self.markInputFinished(error: nil)
                    return
                }
                if !input.append(buffer) {
                    input.markAsFinished()
                    self.markInputFinished(
                        error: TSRemuxError.writeFailed(
                            self.writer?.error?.localizedDescription ?? "サンプルを追加できません"))
                    return
                }
            }
        }
    }

    private func markInputFinished(error: Error?) {
        lock.lock()
        inputsFinished += 1
        if failure == nil { failure = error }
        lock.unlock()
    }
}
