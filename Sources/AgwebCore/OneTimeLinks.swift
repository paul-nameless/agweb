import Foundation

/// Links that act when loaded (sign-in callbacks, a deploy page with `autoload=1&token=…`): a restored tab must not
/// load one by itself after a restart, or the action runs again.
public enum OneTimeLinks {
    private static let names: Set = ["autoload", "ticket", "otp", "nonce", "sig", "signature"]

    public static func contains(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // OAuth's implicit flow puts its tokens in the fragment.
        let fragment = URLComponents(string: "?" + (parts.fragment ?? ""))?.queryItems ?? []
        let items = Set(((parts.queryItems ?? []) + fragment).map { $0.name.lowercased() })
        // code alone is common (?code=swift); with state it is an OAuth callback.
        return items.contains { $0.contains("token") || names.contains($0) } || items.isSuperset(of: ["code", "state"])
    }
}
