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
        let host = hostOf(text)
        let local = isLocal(host)
        guard !host.isEmpty, let url = URL(string: (local ? "http://" : "https://") + text) else { throw Failure("bad url \(text)") }
        return url
    }

    /// What a person types in the address field: an address as `url` takes it, or else a DuckDuckGo search. A search
    /// has a space, or is one word without a dot (localhost and IP addresses are addresses); `router/` or
    /// `http://router` reach a one-word host. Agents' `goto` keeps `url`, so a typo fails instead of searching.
    public static func typed(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let address = text.hasPrefix("/") || text.hasPrefix("[") || text.contains("/")
            || text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
            || hostOf(text).contains(".") || isLocal(hostOf(text))
        if text.rangeOfCharacter(from: .whitespaces) == nil, address, let url = try? url(text) { return url }
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return URL(string: "https://duckduckgo.com/?q=" + (text.addingPercentEncoding(withAllowedCharacters: plain) ?? text))
    }

    private static func hostOf(_ text: String) -> String {
        text.hasPrefix("[") ? String(text.prefix { $0 != "]" }) + "]" : text.prefix { !":/?#".contains($0) }.lowercased()
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "[::1]"
            || host.range(of: "^\\d+\\.\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
    }
}
