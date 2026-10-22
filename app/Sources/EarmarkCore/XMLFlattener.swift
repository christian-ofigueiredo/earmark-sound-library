import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Flattens XML (iXML, XMP) into `["BWFXML/USER/DESCRIPTION": "text"]`.
/// Repeated paths are joined with " | "; attributes become `path@name`.
enum XMLFlattener {
    static func flatten(_ data: Data) -> [String: String] {
        var bytes = data
        while let last = bytes.last, last == 0 || last == 0x20 || last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { return [:] }
        if let lt = bytes.firstIndex(of: UInt8(ascii: "<")), lt != bytes.startIndex {
            bytes = bytes[lt...]
        }
        let delegate = Delegate()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.out
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var out: [String: String] = [:]
        private var stack: [String] = []
        private var text: [String] = []
        private var hasChildren: [Bool] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if !hasChildren.isEmpty { hasChildren[hasChildren.count - 1] = true }
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            stack.append(local)
            text.append("")
            hasChildren.append(false)
            let path = stack.joined(separator: "/")
            for (k, v) in attributeDict {
                let value = v.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let name = k.split(separator: ":").last.map(String.init) ?? k
                out["\(path)@\(name)"] = value
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !text.isEmpty { text[text.count - 1] += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if !text.isEmpty { text[text.count - 1] += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let path = stack.joined(separator: "/")
            let value = (text.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let leaf = !(hasChildren.popLast() ?? false)
            if leaf, !value.isEmpty {
                if let existing = out[path] { out[path] = existing + " | " + value } else { out[path] = value }
            }
            _ = stack.popLast()
        }
    }
}
