import Foundation

/// One JSON line per command, for debugging agweb itself; only builds with AGWEB_COMMAND_LOG write it (scripts/build.sh
/// does, a release build doesn't). Never a value an agent typed, filled or evaluated, nor a query string.
public enum CommandLog {
    /// Commands whose arguments are text the agent supplied: passwords, cookies, code, saved state, mocked bodies.
    /// `fill` and `select` keep their target.
    public static let textCommands: Set<String> = ["type", "eval", "fill", "select", "dialog-accept", "cookie-set", "state-load", "route"]
    /// Options logged with their value; any other is logged as present only (route's --header and --body carry tokens).
    static let shownOptions: Set<String> = ["timeout", "text", "url", "filename", "path", "profile", "max-results", "download-dir", "filter",
                                            "color-scheme", "button", "delay", "width", "height", "status"]

    public static func line(_ request: Request, ok: Bool, output: String, at time: Date, seconds: Double) -> String {
        var args = request.args
        if textCommands.contains(request.command) {
            let kept = ["fill", "select"].contains(request.command) ? Array(args.prefix(1)) : []
            args = kept + (args.count > kept.count ? ["<hidden>"] : [])
        }
        var entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: time),
            "workspace": request.workspace,
            "command": request.command,
            "args": args.map(withoutQuery),
            "ms": Int(seconds * 1000),
            "ok": ok,
        ]
        let options = request.options.reduce(into: [String: String]()) { shown, option in
            shown[option.key] = option.value.isEmpty || shownOptions.contains(option.key) ? withoutQuery(option.value) : "<hidden>"
        }
        if !options.isEmpty { entry["options"] = options }
        if !ok { entry["error"] = output.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A magic link or OAuth redirect carries its token in the query or fragment.
    static func withoutQuery(_ text: String) -> String {
        guard text.hasPrefix("http://") || text.hasPrefix("https://"), var url = URLComponents(string: text),
              url.query != nil || url.fragment != nil else { return text }
        url.query = nil
        url.fragment = nil
        return (url.string ?? text) + "?…"
    }
}
