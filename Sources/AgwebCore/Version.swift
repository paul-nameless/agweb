/// Release versions as GitHub tags and CFBundleShortVersionString spell them: "v0.10.1" or "0.10.1".
public enum Version {
    /// Whether `a` is a later version than `b`, part by part as numbers, so 0.10.0 is after 0.9.1; a missing part is 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// "v0.10.1" -> "0.10.1".
    public static func bare(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    static func parts(_ version: String) -> [Int] {
        bare(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
