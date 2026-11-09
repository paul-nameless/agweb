import Foundation

public enum Address {
    /// Accepts what people type: full URLs, absolute paths, `localhost:3000/x`, `192.168.1.5:8080`, `[::1]:8080`,
    /// `example.com`. Local hosts get http, everything else https.
    public static func url(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        let hostPort = text.range(of: "^([^:/?#\\s\\[]+|\\[[^\\]]*\\]):\\d+([/?#]|$)", options: .regularExpression) != nil
        let hasScheme = !hostPort && text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
        if hasScheme {
            guard let url = URL(string: text) else { throw Failure("bad url \(text)") }
            return url
        }
        let host = text.hasPrefix("[") ? String(text.prefix { $0 != "]" }) + "]" : text.prefix { !":/?#".contains($0) }.lowercased()
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "[::1]"
            || host.range(of: "^\\d+\\.\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
        guard !host.isEmpty, let url = URL(string: (local ? "http://" : "https://") + text) else { throw Failure("bad url \(text)") }
        return url
    }
}
