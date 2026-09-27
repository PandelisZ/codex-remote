import Foundation

/// A tiny read-only XML tree. The EC2 Query API answers in XML and Codex Remote reads only a
/// handful of fields from it, so a full XML library would be overkill.
public final class XMLTreeNode: @unchecked Sendable {
    public let name: String
    public internal(set) var text: String = ""
    public internal(set) var children: [XMLTreeNode] = []
    public weak var parent: XMLTreeNode?

    init(name: String) { self.name = name }

    public subscript(_ childName: String) -> XMLTreeNode? {
        children.first { $0.name == childName }
    }

    public func all(_ childName: String) -> [XMLTreeNode] {
        children.filter { $0.name == childName }
    }

    /// Depth-first search for the first descendant with this name.
    public func find(_ name: String) -> XMLTreeNode? {
        if self.name == name { return self }
        for child in children {
            if let hit = child.find(name) { return hit }
        }
        return nil
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func parse(_ data: Data) -> XMLTreeNode? {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTreeNode?
    private var stack: [XMLTreeNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = XMLTreeNode(name: elementName)
        node.parent = stack.last
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }
}
