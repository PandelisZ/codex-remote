import Foundation

/// Rewrites only the region of a user-owned text file that Codex Remote claims, delimited by
/// sentinel comments. Anything outside the markers is preserved byte for byte, so a
/// hand-tuned `~/.ssh/config` survives every Codex Remote write.
public enum ManagedBlock {
    public static let begin = "# >>> codex-remote managed block — do not edit inside these markers >>>"
    public static let end = "# <<< codex-remote managed block <<<"

    public static func render(_ body: String) -> String {
        "\(begin)\n\(body.trimmingCharacters(in: .newlines))\n\(end)\n"
    }

    /// Replaces an existing block, or appends one if the file has none.
    public static func apply(body: String, to text: String) -> String {
        let block = render(body)
        guard let range = blockRange(in: text) else {
            let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            let spacer = text.isEmpty ? "" : "\n"
            return text + separator + spacer + block
        }
        return text.replacingCharacters(in: range, with: block)
    }

    public static func remove(from text: String) -> String {
        guard let range = blockRange(in: text) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }

    public static func extract(from text: String) -> String? {
        guard let range = blockRange(in: text) else { return nil }
        let block = String(text[range])
        return block
            .replacingOccurrences(of: begin + "\n", with: "")
            .replacingOccurrences(of: end + "\n", with: "")
    }

    private static func blockRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: begin) else { return nil }
        guard let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return nil }
        // Swallow the newline that follows the end marker so repeated writes do not
        // accumulate blank lines.
        var upper = stop.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return start.lowerBound..<upper
    }

    /// Writes `body` into the managed region of `url`, creating the file if needed.
    public static func write(body: String, to url: URL, permissions: Int = 0o600) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = apply(body: body, to: existing)
        guard updated != existing else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
