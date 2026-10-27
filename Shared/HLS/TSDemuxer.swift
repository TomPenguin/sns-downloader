import Foundation

/// MPEG-2 TS (188 バイト固定パケット) から PES を取り出すデマルチプレクサ。
///
/// HLS の `.ts` セグメントは AVFoundation がファイルとして読めない
/// (ローカルの MPEG-TS はコンテナとして未対応) ため、自前で分解して
/// 映像・音声の基本ストリームを取り出し、AVAssetWriter で mp4 に書き直す。
///
/// 対応するのは H.264 (stream_type 0x1B) と ADTS AAC (0x0F / 0x11) のみ。
/// セグメントをまたいで状態を保つので、1 本のストリームにつき 1 インスタンス使う。
final class TSDemuxer {

    /// PMT で宣言された基本ストリームの種別
    enum StreamKind {
        case h264
        case aac
    }

    /// 組み立てが完了した PES 1 つ分
    struct PESPacket {
        let kind: StreamKind
        /// 90kHz 単位の表示時刻。PES ヘッダに入っていなければ nil
        let pts: Int64?
        /// 90kHz 単位のデコード時刻。PES ヘッダに DTS がなければ PTS と同じ
        let dts: Int64?
        let payload: Data
    }

    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47

    private var pmtPID: Int?
    private var streamKinds: [Int: StreamKind] = [:]
    /// PID ごとの組み立て途中の PES
    private var pending: [Int: Data] = [:]
    /// 188 バイトに満たずに持ち越したバイト列
    private var leftover = Data()

    /// PMT を読み終えて映像・音声の PID が判明しているか
    var hasStreams: Bool { !streamKinds.isEmpty }
    var kinds: Set<StreamKind> {
        Set(streamKinds.values.map { $0 })
    }

    /// セグメント 1 つ分のデータを流し込む。完成した PES を順に onPacket に渡す
    func push(_ data: Data, onPacket: (PESPacket) -> Void) {
        var buffer: Data
        if leftover.isEmpty {
            buffer = data
        } else {
            buffer = leftover
            buffer.append(data)
            leftover = Data()
        }

        var offset = buffer.startIndex
        while offset + Self.packetSize <= buffer.endIndex {
            // 同期が外れたら次の 0x47 まで読み飛ばす
            guard buffer[offset] == Self.syncByte else {
                offset += 1
                continue
            }
            handlePacket(buffer[offset..<(offset + Self.packetSize)], onPacket: onPacket)
            offset += Self.packetSize
        }
        if offset < buffer.endIndex {
            leftover = Data(buffer[offset...])
        }
    }

    /// 最後のセグメントまで流し終えたあとに呼び、組み立て途中の PES を吐き出す
    func flush(onPacket: (PESPacket) -> Void) {
        for (pid, data) in pending {
            emit(pid: pid, data: data, onPacket: onPacket)
        }
        pending.removeAll()
        leftover = Data()
    }

    // MARK: - パケット単位の処理

    private func handlePacket(_ packet: Data, onPacket: (PESPacket) -> Void) {
        let base = packet.startIndex
        let payloadUnitStart = packet[base + 1] & 0x40 != 0
        let pid = (Int(packet[base + 1] & 0x1F) << 8) | Int(packet[base + 2])
        let adaptationControl = (packet[base + 3] >> 4) & 0x03

        // スクランブルされたパケットは中身を読めない
        guard packet[base + 3] & 0xC0 == 0 else { return }

        var payloadStart = base + 4
        if adaptationControl == 0b10 || adaptationControl == 0b11 {
            let adaptationLength = Int(packet[base + 4])
            payloadStart = base + 5 + adaptationLength
        }
        guard adaptationControl == 0b01 || adaptationControl == 0b11,
              payloadStart < packet.endIndex else {
            return
        }
        let payload = packet[payloadStart...]

        if pid == 0 {
            parsePAT(payload, payloadUnitStart: payloadUnitStart)
        } else if pid == pmtPID {
            parsePMT(payload, payloadUnitStart: payloadUnitStart)
        } else if streamKinds[pid] != nil {
            if payloadUnitStart {
                if let previous = pending[pid] {
                    emit(pid: pid, data: previous, onPacket: onPacket)
                }
                pending[pid] = Data(payload)
            } else if pending[pid] != nil {
                pending[pid]?.append(contentsOf: payload)
            }
        }
    }

    // MARK: - PSI (PAT / PMT)

    /// PSI セクションの本体を取り出す。payload_unit_start のときだけ
    /// 先頭に pointer_field が入る。セクションが複数パケットに分かれる場合は
    /// 扱わない (PAT/PMT が 184 バイトを超えることは実質ない)
    private func sectionBody(_ payload: Data, payloadUnitStart: Bool) -> Data? {
        guard payloadUnitStart else { return nil }
        let pointer = Int(payload[payload.startIndex])
        let start = payload.startIndex + 1 + pointer
        guard start < payload.endIndex else { return nil }
        return Data(payload[start...])
    }

    private func parsePAT(_ payload: Data, payloadUnitStart: Bool) {
        guard pmtPID == nil,
              let section = sectionBody(payload, payloadUnitStart: payloadUnitStart),
              section.count >= 12,
              section[0] == 0x00 else {
            return
        }
        let sectionLength = (Int(section[1] & 0x0F) << 8) | Int(section[2])
        // table_id(1) + section_length フィールド(2) + ヘッダ(5) ... CRC(4) の手前まで
        let end = min(3 + sectionLength - 4, section.count)
        var offset = 8
        while offset + 4 <= end {
            let programNumber = (Int(section[offset]) << 8) | Int(section[offset + 1])
            let pid = (Int(section[offset + 2] & 0x1F) << 8) | Int(section[offset + 3])
            if programNumber != 0 { // 0 は NIT
                pmtPID = pid
                return
            }
            offset += 4
        }
    }

    private func parsePMT(_ payload: Data, payloadUnitStart: Bool) {
        guard streamKinds.isEmpty,
              let section = sectionBody(payload, payloadUnitStart: payloadUnitStart),
              section.count >= 16,
              section[0] == 0x02 else {
            return
        }
        let sectionLength = (Int(section[1] & 0x0F) << 8) | Int(section[2])
        let end = min(3 + sectionLength - 4, section.count)
        let programInfoLength = (Int(section[10] & 0x0F) << 8) | Int(section[11])
        var offset = 12 + programInfoLength

        while offset + 5 <= end {
            let streamType = section[offset]
            let pid = (Int(section[offset + 1] & 0x1F) << 8) | Int(section[offset + 2])
            let esInfoLength = (Int(section[offset + 3] & 0x0F) << 8) | Int(section[offset + 4])
            switch streamType {
            case 0x1B: // H.264
                if !streamKinds.values.contains(where: { $0 == .h264 }) {
                    streamKinds[pid] = .h264
                }
            case 0x0F, 0x11: // ADTS AAC / LATM AAC
                if !streamKinds.values.contains(where: { $0 == .aac }) {
                    streamKinds[pid] = .aac
                }
            default:
                break
            }
            offset += 5 + esInfoLength
        }
    }

    // MARK: - PES

    private func emit(pid: Int, data: Data, onPacket: (PESPacket) -> Void) {
        guard let kind = streamKinds[pid], let packet = Self.parsePES(data, kind: kind) else { return }
        onPacket(packet)
    }

    private static func parsePES(_ data: Data, kind: StreamKind) -> PESPacket? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9,
              bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01 else {
            return nil
        }
        let ptsDTSFlags = (bytes[7] >> 6) & 0x03
        let headerDataLength = Int(bytes[8])
        let payloadStart = 9 + headerDataLength
        guard payloadStart <= bytes.count else { return nil }

        var pts: Int64?
        var dts: Int64?
        if ptsDTSFlags & 0x02 != 0, bytes.count >= 14 {
            pts = readTimestamp(bytes, at: 9)
            if ptsDTSFlags == 0x03, bytes.count >= 19 {
                dts = readTimestamp(bytes, at: 14)
            }
        }
        return PESPacket(kind: kind, pts: pts, dts: dts ?? pts, payload: Data(bytes[payloadStart...]))
    }

    /// PES ヘッダの 5 バイト 33bit タイムスタンプ (90kHz)
    private static func readTimestamp(_ bytes: [UInt8], at index: Int) -> Int64 {
        let b0 = Int64(bytes[index])
        let b1 = Int64(bytes[index + 1])
        let b2 = Int64(bytes[index + 2])
        let b3 = Int64(bytes[index + 3])
        let b4 = Int64(bytes[index + 4])
        return ((b0 >> 1) & 0x07) << 30
            | b1 << 22
            | ((b2 >> 1) & 0x7F) << 15
            | b3 << 7
            | ((b4 >> 1) & 0x7F)
    }
}
