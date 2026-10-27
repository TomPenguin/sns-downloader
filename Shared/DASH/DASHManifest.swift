import Foundation

/// MPD (MPEG-DASH のマニフェスト) の最小パーサ。
///
/// 対応するのは静的 (VOD) マニフェストで、セグメントの指定方法は
/// SegmentTemplate (SegmentTimeline / @duration の両方)、SegmentList、
/// および分割なしの BaseURL 単体。複数 Period は最初の 1 つだけを見る。
enum DASHManifest {

    struct Representation {
        let id: String
        let bandwidth: Int
        let height: Int?
        let initialization: URL?
        let segments: [URL]
        /// セグメントに分かれておらず 1 ファイルで配信されている場合の URL
        let singleFile: URL?
    }

    struct Parsed {
        /// type="dynamic" (ライブ配信)
        let isDynamic: Bool
        /// ContentProtection が宣言されている (DRM)
        let isProtected: Bool
        let video: [Representation]
        let audio: [Representation]
    }

    static func parse(_ data: Data, baseURL: URL) throws -> Parsed {
        guard let root = MPDNode.parse(data), root.name == "MPD" else {
            throw StreamError.manifestParseFailed
        }

        // BaseURL が宣言されていれば、それ自体が動画ファイルを指していることがある
        // (1 ファイル配信 + バイトレンジ指定)。相対 URL の解決基点とは別に覚えておく
        let manifestDeclared = resolve(root.child("BaseURL")?.trimmedText, against: baseURL)
        let manifestBase = manifestDeclared ?? baseURL
        let manifestDuration = duration(from: root["mediaPresentationDuration"])

        guard let period = root.child("Period") else { throw StreamError.manifestParseFailed }
        let periodDeclared = resolve(period.child("BaseURL")?.trimmedText, against: manifestBase)
            ?? manifestDeclared
        let periodBase = periodDeclared ?? manifestBase
        let periodDuration = duration(from: period["duration"]) ?? manifestDuration

        var video: [Representation] = []
        var audio: [Representation] = []
        var isProtected = false

        for adaptationSet in period.children("AdaptationSet") {
            if adaptationSet.child("ContentProtection") != nil { isProtected = true }
            let setDeclared = resolve(adaptationSet.child("BaseURL")?.trimmedText, against: periodBase)
                ?? periodDeclared
            let setBase = setDeclared ?? periodBase

            for representation in adaptationSet.children("Representation") {
                if representation.child("ContentProtection") != nil { isProtected = true }

                let kind = contentKind(representation: representation, adaptationSet: adaptationSet)
                guard kind != nil else { continue }

                let declared = resolve(representation.child("BaseURL")?.trimmedText, against: setBase)
                    ?? setDeclared
                let parsed = makeRepresentation(
                    representation: representation,
                    adaptationSet: adaptationSet,
                    period: period,
                    base: declared ?? setBase,
                    declaredBase: declared,
                    periodDuration: periodDuration
                )
                if kind == .video {
                    video.append(parsed)
                } else {
                    audio.append(parsed)
                }
            }
        }

        return Parsed(
            isDynamic: root["type"] == "dynamic",
            isProtected: isProtected,
            video: video,
            audio: audio
        )
    }

    // MARK: - Representation

    private enum ContentKind {
        case video
        case audio
    }

    private static func contentKind(
        representation: MPDNode,
        adaptationSet: MPDNode
    ) -> ContentKind? {
        let declared = adaptationSet["contentType"]
            ?? representation["mimeType"]?.components(separatedBy: "/").first
            ?? adaptationSet["mimeType"]?.components(separatedBy: "/").first
        switch declared {
        case "video": return .video
        case "audio": return .audio
        case "text", "image", "application": return nil
        default: break
        }

        // contentType も mimeType もない場合はコーデック名で判断する
        let codecs = (representation["codecs"] ?? adaptationSet["codecs"] ?? "").lowercased()
        if codecs.hasPrefix("avc") || codecs.hasPrefix("hvc") || codecs.hasPrefix("hev")
            || codecs.hasPrefix("vp") || codecs.hasPrefix("av01") {
            return .video
        }
        if codecs.hasPrefix("mp4a") || codecs.hasPrefix("opus") || codecs.hasPrefix("ac-3")
            || codecs.hasPrefix("ec-3") {
            return .audio
        }
        // 解像度を持っていれば映像とみなす
        return representation["width"] != nil ? .video : nil
    }

    private static func makeRepresentation(
        representation: MPDNode,
        adaptationSet: MPDNode,
        period: MPDNode,
        base: URL,
        declaredBase: URL?,
        periodDuration: Double?
    ) -> Representation {
        let id = representation["id"] ?? ""
        let bandwidth = representation["bandwidth"].flatMap { Int($0) } ?? 0
        let height = (representation["height"] ?? adaptationSet["height"]).flatMap { Int($0) }

        // 同じ指定が Representation / AdaptationSet / Period のどこに書かれていてもよい
        let template = representation.child("SegmentTemplate")
            ?? adaptationSet.child("SegmentTemplate")
            ?? period.child("SegmentTemplate")
        let list = representation.child("SegmentList")
            ?? adaptationSet.child("SegmentList")
            ?? period.child("SegmentList")

        var initialization: URL?
        var segments: [URL] = []

        if let template {
            (initialization, segments) = expand(
                template: template,
                id: id,
                bandwidth: bandwidth,
                base: base,
                periodDuration: periodDuration
            )
        } else if let list {
            initialization = list.child("Initialization")?["sourceURL"]
                .flatMap { resolve($0, against: base) }
            segments = list.children("SegmentURL").compactMap {
                $0["media"].flatMap { media in resolve(media, against: base) }
            }
        }

        // セグメントの URL が 1 つも取れないのは、1 ファイルをバイトレンジで
        // 分割しているか (SegmentList の mediaRange / SegmentBase の indexRange)、
        // そもそも分割していない場合。どちらも BaseURL のファイルを丸ごと落とせばよい
        guard segments.isEmpty else {
            return Representation(
                id: id, bandwidth: bandwidth, height: height,
                initialization: initialization, segments: segments, singleFile: nil
            )
        }
        return Representation(
            id: id, bandwidth: bandwidth, height: height,
            initialization: nil, segments: [], singleFile: declaredBase
        )
    }

    /// SegmentTemplate から初期化セグメントと各セグメントの URL を組み立てる
    private static func expand(
        template: MPDNode,
        id: String,
        bandwidth: Int,
        base: URL,
        periodDuration: Double?
    ) -> (initialization: URL?, segments: [URL]) {
        let initialization = template["initialization"].flatMap {
            resolve(
                substitute($0, id: id, bandwidth: bandwidth, number: nil, time: nil),
                against: base)
        }
        guard let media = template["media"] else { return (initialization, []) }

        let timescale = template["timescale"].flatMap { Int($0) } ?? 1
        let startNumber = template["startNumber"].flatMap { Int($0) } ?? 1
        var segments: [URL] = []

        func appendSegment(number: Int, time: Int) {
            if let url = resolve(
                substitute(media, id: id, bandwidth: bandwidth, number: number, time: time),
                against: base) {
                segments.append(url)
            }
        }

        if let timeline = template.child("SegmentTimeline") {
            var number = startNumber
            var time = 0
            let periodEnd = periodDuration.map { Int($0 * Double(timescale)) }
            for entry in timeline.children("S") {
                if let start = entry["t"].flatMap({ Int($0) }) { time = start }
                guard let segmentDuration = entry["d"].flatMap({ Int($0) }), segmentDuration > 0 else {
                    continue
                }
                var repeats = entry["r"].flatMap { Int($0) } ?? 0
                if repeats < 0 {
                    // r="-1" は Period の終わりまで繰り返す
                    guard let periodEnd, periodEnd > time else { continue }
                    repeats = (periodEnd - time) / segmentDuration - 1
                }
                for _ in 0...max(0, repeats) {
                    appendSegment(number: number, time: time)
                    time += segmentDuration
                    number += 1
                }
            }
            return (initialization, segments)
        }

        guard let segmentDuration = template["duration"].flatMap({ Int($0) }), segmentDuration > 0,
              let periodDuration else {
            return (initialization, segments)
        }
        let count = Int(ceil(periodDuration * Double(timescale) / Double(segmentDuration)))
        for index in 0..<max(0, count) {
            appendSegment(number: startNumber + index, time: index * segmentDuration)
        }
        return (initialization, segments)
    }

    // MARK: - テンプレート変数

    /// `$Number%05d$` のような識別子を実際の値に置き換える
    static func substitute(
        _ template: String,
        id: String,
        bandwidth: Int,
        number: Int?,
        time: Int?
    ) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "$") {
            result += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "$") else {
                result += rest[open...]
                return result
            }
            let token = String(rest[afterOpen..<close])
            result += value(for: token, id: id, bandwidth: bandwidth, number: number, time: time)
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private static func value(
        for token: String,
        id: String,
        bandwidth: Int,
        number: Int?,
        time: Int?
    ) -> String {
        if token.isEmpty { return "$" } // "$$" はドル記号そのもの
        let parts = token.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let format = parts.count > 1 ? "%" + parts[1] : nil

        func formatted(_ number: Int) -> String {
            guard let format else { return String(number) }
            return String(format: format, number)
        }

        switch name {
        case "RepresentationID": return id
        case "Bandwidth": return formatted(bandwidth)
        case "Number": return number.map(formatted) ?? ""
        case "Time": return time.map(formatted) ?? ""
        default: return ""
        }
    }

    // MARK: - ヘルパー

    private static func resolve(_ uri: String?, against base: URL) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        return URL(string: uri, relativeTo: base)?.absoluteURL
    }

    /// ISO 8601 の期間表記 ("PT1H2M12.5S") を秒に直す
    static func duration(from text: String?) -> Double? {
        guard let text, text.hasPrefix("P") else { return nil }
        var seconds: Double = 0
        var number = ""
        var isTimePart = false
        var found = false

        for character in text.dropFirst() {
            if character == "T" {
                isTimePart = true
                number = ""
                continue
            }
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else {
                number = ""
                continue
            }
            switch character {
            case "Y": seconds += value * 365 * 86_400
            case "D": seconds += value * 86_400
            case "H": seconds += value * 3_600
            case "M": seconds += isTimePart ? value * 60 : value * 30 * 86_400
            case "S": seconds += value
            default: break
            }
            found = true
            number = ""
        }
        return found ? seconds : nil
    }
}
