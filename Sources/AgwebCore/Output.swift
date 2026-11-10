import Foundation

/// Replies are markdown sections (`### Result`, `### Page`, ...). `--raw` and `--json` reshape them in the CLI.
public enum Output {
    /// Sections that describe the tab rather than answer the command.
    static let context: Set = ["Page", "Tabs", "Events"]
    /// Every title the app emits; a `### Heading` in an answer (an article from `text`, a response body) is content.
    static let titles: Set = context.union(["Result", "Snapshot", "Changes", "Found", "Download", "PDF", "Screenshot", "Video", "Routes", "Static"])

    static func isTitle(_ title: Substring) -> Bool {
        titles.contains(String(title)) || title.hasPrefix("Request ") || title.hasPrefix("Static ")
    }

    public static func sections(_ text: String) -> [(title: String, body: String)] {
        var result: [(String, [Substring])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### "), isTitle(line.dropFirst(4)) {
                result.append((String(line.dropFirst(4)), []))
            } else if result.isEmpty {
                result.append(("Result", [line]))
            } else {
                result[result.count - 1].1.append(line)
            }
        }
        return result.map { ($0.0, $0.1.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
    }

    /// The command's own answer without the page around it; a JSON string comes out unquoted.
    public static func raw(_ text: String) -> String {
        guard let body = sections(text).first(where: { !context.contains($0.title) })?.body else { return "" }
        if body.hasPrefix("\""), let string = try? JSONDecoder().decode(String.self, from: Data(body.utf8)) { return string }
        return body
    }

    /// One JSON object: `ok`, then each section by lowercased title. JSON bodies stay JSON, `- Key: value` lists
    /// become objects, anything else is a string. Output that is already a JSON object passes through.
    public static func json(_ text: String, ok: Bool) -> String {
        if ok, text.hasPrefix("{"), (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] { return text }
        var object: [String: Any] = ["ok": ok]
        if !ok {
            object["error"] = text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
        } else {
            // Changes and Found are lists of lines; read as `- key: value` pairs, two calls would collapse into one.
            for (title, body) in sections(text) {
                object[title.lowercased()] = ["Changes", "Found"].contains(title) ? body.split(separator: "\n").map(String.init) : value(body)
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func value(_ body: String) -> Any {
        if let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: .fragmentsAllowed) { return parsed }
        let lines = body.split(separator: "\n")
        let pairs = lines.compactMap { line -> (String, String)? in
            guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon]
            guard !key.contains(" "), !key.isEmpty else { return nil }
            return (key.lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if !lines.isEmpty, pairs.count == lines.count { return Dictionary(pairs, uniquingKeysWith: { a, _ in a }) }
        return body
    }
}
