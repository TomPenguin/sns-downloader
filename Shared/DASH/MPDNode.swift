import Foundation

/// MPD を読むためだけの最小 XML ツリー。
/// iOS の Foundation には XMLDocument がないため、XMLParser から自前で組み立てる
final class MPDNode {
    let name: String
    let attributes: [String: String]
    private(set) var children: [MPDNode] = []
    /// 要素のテキスト内容(BaseURL で使う)
    private(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(attribute: String) -> String? {
        attributes[attribute]
    }

    func child(_ name: String) -> MPDNode? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [MPDNode] {
        children.filter { $0.name == name }
    }

    /// 自分と子孫から最初に見つかった要素
    func firstDescendant(_ name: String) -> MPDNode? {
        if self.name == name { return self }
        for child in children {
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    static func parse(_ data: Data) -> MPDNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // 名前空間は展開せず、要素名をそのまま使う
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        return builder.root
    }

    fileprivate func append(_ child: MPDNode) {
        children.append(child)
    }

    fileprivate func appendText(_ string: String) {
        text += string
    }

    /// 前後の空白を落としたテキスト
    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        private(set) var root: MPDNode?
        private var stack: [MPDNode] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let node = MPDNode(name: elementName, attributes: attributes)
            stack.last?.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.appendText(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            stack.removeLast()
        }
    }
}
