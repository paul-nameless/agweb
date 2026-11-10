public enum Commands {
    public static let all = [
        "open", "goto", "reload", "go-back", "go-forward", "snapshot", "click", "dblclick", "check", "uncheck", "drag",
        "hover", "mousemove", "mousedown", "mouseup", "mousewheel", "fill", "select", "type", "press", "keydown", "keyup",
        "upload", "download", "eval", "highlight", "screenshot", "pdf", "resize", "emulate", "wait", "video-start", "video-chapter", "video-stop",
        "console", "requests", "request", "request-headers", "request-body", "response-headers", "response-body", "route",
        "route-list", "unroute", "cookie-list", "cookie-get", "cookie-set", "cookie-delete", "cookie-clear", "state-save",
        "state-load", "dialog-accept", "dialog-dismiss", "tab-list", "tab-new", "tab-select", "tab-close", "show", "close",
        "list", "close-all", "profile-list", "profile-delete", "quit",
    ]

    /// Names agents reach for that mean something agweb spells differently.
    static let guesses = [
        "tabs": "tab-list", "tab": "tab-list", "list-tabs": "tab-list", "select-tab": "tab-select", "switch-tab": "tab-select",
        "switch": "tab-select", "sessions": "list", "sleep": "wait", "network": "requests", "navigate": "goto", "back": "go-back",
        "forward": "go-forward", "evaluate": "eval", "triple-click": "click", "scroll": "mousewheel",
    ]

    public static func unknown(_ name: String) -> String {
        if name == "run-code" { return "no run-code: agweb has no Playwright engine; use role=/text= targets, eval and separate commands" }
        let suggestion = guesses[name] ?? all.map { ($0, distance($0, name)) }.filter { $0.1 <= 2 }.min { $0.1 < $1.1 }?.0
        return "unknown command '\(name)'" + (suggestion.map { "; did you mean \($0)?" } ?? "; run agweb help")
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let b = Array(b)
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
