import CoreMedia
import Foundation

enum TSBuildError: LocalizedError {
    case missingParameterSets
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingParameterSets:
            return "動画の変換に失敗しました(映像の設定情報が見つかりません)"
        case .formatDescriptionFailed(let status):
            return "動画の変換に失敗しました(フォーマット \(status))"
        case .sampleBufferFailed(let status):
            return "動画の変換に失敗しました(サンプル \(status))"
        }
    }
}

/// H.264 の Annex B バイトストリーム(PES のペイロード)を
/// AVAssetWriter に渡せる AVCC 形式の CMSampleBuffer に組み替える。
///
/// mp4 に書くにはサンプルごとの尺が必要だが、PES からは開始時刻しか分からない。
/// そのため 1 サンプル分だけ保持して、次のサンプルの DTS が来てから尺を確定させる。
final class H264SampleBuilder {

    static let timescale: CMTimeScale = 90_000

    private(set) var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private struct PendingSample {
        let data: Data
        let pts: Int64
        let dts: Int64
        let isKeyframe: Bool
    }
    private var pending: PendingSample?
    /// 最後のサンプルの尺には直前の値を流用する(次の DTS がないため)
    private var lastDuration: Int64 = 3_000 // 30fps 相当

    func append(payload: Data, pts: Int64?, dts: Int64?, onSample: (CMSampleBuffer) throws -> Void) throws {
        var avcc = Data()
        var isKeyframe = false

        for nal in Self.nalUnits(in: payload) {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            switch type {
            case 7:
                if sps == nil { sps = nal }
            case 8:
                if pps == nil { pps = nal }
            case 9, 12:
                break // アクセスユニットデリミタ・フィラーは mp4 に不要
            default:
                if type == 5 { isKeyframe = true }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(nal)
            }
        }

        if formatDescription == nil, let sps, let pps {
            formatDescription = try Self.makeFormatDescription(sps: sps, pps: pps)
        }
        guard !avcc.isEmpty, let pts else { return }
        let decodeTime = dts ?? pts

        if let previous = pending {
            let duration = max(1, decodeTime - previous.dts)
            lastDuration = duration
            try emit(previous, duration: duration, onSample: onSample)
        }
        pending = PendingSample(data: avcc, pts: pts, dts: decodeTime, isKeyframe: isKeyframe)
    }

    func flush(onSample: (CMSampleBuffer) throws -> Void) throws {
        if let previous = pending {
            try emit(previous, duration: lastDuration, onSample: onSample)
        }
        pending = nil
    }

    private func emit(
        _ sample: PendingSample,
        duration: Int64,
        onSample: (CMSampleBuffer) throws -> Void
    ) throws {
        guard let formatDescription else { throw TSBuildError.missingParameterSets }
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: Self.timescale),
            presentationTimeStamp: CMTime(value: sample.pts, timescale: Self.timescale),
            decodeTimeStamp: CMTime(value: sample.dts, timescale: Self.timescale)
        )
        let buffer = try makeSampleBuffer(
            data: sample.data,
            formatDescription: formatDescription,
            timing: timing,
            sampleSizes: [sample.data.count]
        )
        if !sample.isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        try onSample(buffer)
    }

    private static func makeFormatDescription(sps: Data, pps: Data) throws -> CMFormatDescription {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description else {
            throw TSBuildError.formatDescriptionFailed(status)
        }
        return description
    }

    /// Annex B のスタートコード (00 00 01 / 00 00 00 01) で区切って NAL を取り出す
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(index: Int, prefix: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3))
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    starts.append((index, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }

        var result: [Data] = []
        for (position, start) in starts.enumerated() {
            let from = start.index + start.prefix
            let to = position + 1 < starts.count ? starts[position + 1].index : bytes.count
            guard from < to else { continue }
            result.append(Data(bytes[from..<to]))
        }
        return result
    }
}

/// ADTS AAC (PES のペイロード) を CMSampleBuffer に組み替える。
///
/// ADTS ヘッダは mp4 では不要なので外し、ヘッダから作った
/// AudioSpecificConfig をフォーマット記述に持たせる。
final class AACSampleBuilder {

    /// AAC は 1 フレーム固定 1024 サンプル
    private static let samplesPerFrame: Int64 = 1_024
    private static let sampleRates: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    private(set) var formatDescription: CMFormatDescription?
    private var sampleRate: Int = 0
    /// 次に書き出すフレームの時刻(サンプル数単位)。PES の PTS で補正する
    private var nextTimestamp: Int64?

    func append(payload: Data, pts: Int64?, onSample: (CMSampleBuffer) throws -> Void) throws {
        let bytes = [UInt8](payload)
        var offset = 0
        var frames: [Data] = []

        while offset + 7 <= bytes.count {
            guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else {
                offset += 1 // 同期が外れた
                continue
            }
            let frameLength = (Int(bytes[offset + 3] & 0x03) << 11)
                | (Int(bytes[offset + 4]) << 3)
                | (Int(bytes[offset + 5]) >> 5)
            guard frameLength > 7, offset + frameLength <= bytes.count else { break }

            if formatDescription == nil {
                try makeFormatDescription(header: Array(bytes[offset..<(offset + 7)]))
            }
            let headerLength = bytes[offset + 1] & 0x01 == 1 ? 7 : 9
            frames.append(Data(bytes[(offset + headerLength)..<(offset + frameLength)]))
            offset += frameLength
        }

        guard !frames.isEmpty, let formatDescription, sampleRate > 0 else { return }

        // PES の PTS (90kHz) をサンプル数に直す。初回と、ずれが 1 フレームを
        // 超えたときだけ合わせ直す(毎回合わせると丸め誤差で音が途切れる)
        if let pts {
            let timestamp = pts * Int64(sampleRate) / 90_000
            if let current = nextTimestamp {
                if abs(timestamp - current) > Self.samplesPerFrame {
                    nextTimestamp = timestamp
                }
            } else {
                nextTimestamp = timestamp
            }
        }
        guard let start = nextTimestamp else { return }

        var data = Data()
        var sizes: [Int] = []
        for frame in frames {
            data.append(frame)
            sizes.append(frame.count)
        }
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: Self.samplesPerFrame, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        let buffer = try makeSampleBuffer(
            data: data,
            formatDescription: formatDescription,
            timing: timing,
            sampleSizes: sizes
        )
        nextTimestamp = start + Int64(frames.count) * Self.samplesPerFrame
        try onSample(buffer)
    }

    /// AAC のマジッククッキー(= mp4 の esds ボックスの中身)を組み立てる。
    ///
    /// AudioSpecificConfig をそのまま渡すと、中身が空の esds が書かれてしまい
    /// AVFoundation が読み直したときにデコーダ設定を復元できない。
    /// ES_Descriptor → DecoderConfigDescriptor → DecoderSpecificInfo の
    /// 入れ子にしてから渡す必要がある
    private static func makeMagicCookie(audioSpecificConfig config: [UInt8]) -> [UInt8] {
        /// タグ + 4 バイト長(0x80 3 つで埋める拡張形式)+ 中身
        func descriptor(tag: UInt8, payload: [UInt8]) -> [UInt8] {
            [tag, 0x80, 0x80, 0x80, UInt8(payload.count)] + payload
        }
        let specificInfo = descriptor(tag: 0x05, payload: config)
        let decoderConfig = descriptor(
            tag: 0x04,
            payload: [
                0x40, // objectTypeIndication: MPEG-4 Audio
                0x15, // streamType: AudioStream
                0x00, 0x00, 0x00, // bufferSizeDB
                0x00, 0x00, 0x00, 0x00, // maxBitrate
                0x00, 0x00, 0x00, 0x00, // avgBitrate
            ] + specificInfo
        )
        let syncLayer = descriptor(tag: 0x06, payload: [0x02])
        return descriptor(
            tag: 0x03,
            payload: [0x00, 0x00, 0x00] + decoderConfig + syncLayer // ES_ID + flags
        )
    }

    private func makeFormatDescription(header: [UInt8]) throws {
        let profile = (header[2] >> 6) & 0x03
        let frequencyIndex = Int((header[2] >> 2) & 0x0F)
        let channels = ((header[2] & 0x01) << 2) | ((header[3] >> 6) & 0x03)
        guard frequencyIndex < Self.sampleRates.count else {
            throw TSBuildError.formatDescriptionFailed(-1)
        }
        sampleRate = Self.sampleRates[frequencyIndex]

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(profile + 1), // AudioObjectType (AAC-LC = 2)
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // AudioSpecificConfig: audioObjectType(5) + samplingFrequencyIndex(4)
        //                      + channelConfiguration(4) + 残り 3 ビットは 0
        let objectType = UInt8(profile + 1)
        let config: [UInt8] = [
            (objectType << 3) | UInt8(frequencyIndex >> 1),
            UInt8((frequencyIndex & 0x01) << 7) | (channels << 3),
        ]
        let cookie = Self.makeMagicCookie(audioSpecificConfig: config)

        var description: CMFormatDescription?
        let status = cookie.withUnsafeBytes { cookieBytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookieBytes.count,
                magicCookie: cookieBytes.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw TSBuildError.formatDescriptionFailed(status)
        }
        formatDescription = description
    }
}

/// データと尺から CMSampleBuffer を作る
func makeSampleBuffer(
    data: Data,
    formatDescription: CMFormatDescription,
    timing: CMSampleTimingInfo,
    sampleSizes: [Int]
) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else {
        throw TSBuildError.sampleBufferFailed(status)
    }
    status = data.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: data.count
        )
    }
    guard status == noErr else { throw TSBuildError.sampleBufferFailed(status) }

    var sampleBuffer: CMSampleBuffer?
    var timingInfo = timing
    var sizes = sampleSizes
    status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: sampleSizes.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timingInfo,
        sampleSizeEntryCount: sizes.count,
        sampleSizeArray: &sizes,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw TSBuildError.sampleBufferFailed(status)
    }
    return sampleBuffer
}
