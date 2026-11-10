import AppKit
import WebKit
import AgwebCore

/// Requests, routes, cookies and storage state: the commands that read or change what a page stores and fetches.
extension Browser {
    // MARK: Network

    func requestList(_ tab: Tab, filter: String?, includeStatic: Bool, clear: Bool) async throws -> String {
        let regex = try filter.map { try NSRegularExpression(pattern: $0) }
        func keep(_ url: String) -> Bool { regex.map { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil } ?? true }
        var lines = tab.requests.enumerated().compactMap { index, entry -> String? in
            let url = entry["url"] as? String ?? ""
            guard keep(url) else { return nil }
            let status = entry["failure"].map { "failed: \($0)" } ?? (entry["status"].map { "\($0)" } ?? "pending")
            return "\(index + 1). [\(entry["method"] as? String ?? "GET")] \(url) => \(status)\((entry["routed"] as? Bool) == true ? " (routed)" : "") [\(entry["kind"] as? String ?? "")]"
        }
        if includeStatic {
            let json = try await tab.call("""
                return JSON.stringify(performance.getEntriesByType('resource').filter(e => !['fetch', 'xmlhttprequest'].includes(e.initiatorType))
                  .map(e => [e.name, e.initiatorType, e.responseStatus || 0]));
                """)
            let entries = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]] ?? []
            let statics = entries.compactMap { entry -> String? in
                guard let url = entry.first as? String, keep(url) else { return nil }
                let status = (entry.last as? Int).flatMap { $0 > 0 ? "\($0)" : nil } ?? "loaded"
                return "- [\(entry[1])] \(url) => \(status)"
            }
            if !statics.isEmpty { lines += ["### Static"] + statics }
        }
        if clear { tab.requests.removeAll() }
        return lines.isEmpty ? "no requests" + (filter.map { " matching \($0)" } ?? "") : lines.joined(separator: "\n")
    }

    func requestDetail(_ tab: Tab, _ number: String, part: String) throws -> String {
        guard let n = Int(number), tab.requests.indices.contains(n - 1) else { throw Failure("no request \(number); see agweb requests") }
        let entry = tab.requests[n - 1]
        func headers(_ key: String) -> String {
            (entry[key] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        func body(_ key: String) -> String { entry[key] as? String ?? "(none)" }
        switch part {
        case "request-headers": return headers("requestHeaders")
        case "request-body": return body("requestBody")
        case "response-headers": return headers("responseHeaders")
        case "response-body": return body("responseBody")
        default:
            let status = entry["failure"].map { "failed: \($0)" } ?? "\(entry["status"] ?? "pending") \(entry["statusText"] ?? "")"
            return ["### Request \(n)", "\(entry["method"] ?? "GET") \(entry["url"] ?? "")", "- Status: \(status)",
                    "#### Request headers", headers("requestHeaders"), "#### Request body", body("requestBody"),
                    "#### Response headers", headers("responseHeaders"), "#### Response body", body("responseBody")].joined(separator: "\n")
        }
    }

    func routeList(_ workspace: Workspace) -> String {
        workspace.routes.isEmpty ? "no routes" : "### Routes\n" + workspace.routes.map { route in
            "- \(route.pattern) => \(route.status ?? 200)" + (route.contentType.map { " \($0)" } ?? "") + (route.body.map { ", \($0.count) characters" } ?? "")
        }.joined(separator: "\n")
    }

    // MARK: Cookies and storage state

    func cookies(_ request: Request, in workspace: Workspace) async throws -> String {
        // Before reading or changing them, or a profile not loaded yet this run reports its logins missing.
        if let profile = workspace.profile { await Profiles.restoreSessionCookies(profile) }
        let store = workspace.dataStore.httpCookieStore
        let options = request.options
        let all = try await withTimeout(5, "reading cookies") { await store.allCookies() }
        let matching = all.filter { cookie in
            (options["domain"].map { cookie.domain.trimmingCharacters(in: ["."]).hasSuffix($0.trimmingCharacters(in: ["."])) } ?? true)
                && (options["path"].map { cookie.path == $0 } ?? true)
                && (request.args.first.map { request.command == "cookie-set" || request.command == "cookie-clear" || cookie.name == $0 } ?? true)
        }
        func line(_ c: HTTPCookie) -> String {
            var parts = ["\(c.name)=\(c.value)", "domain=\(c.domain)", "path=\(c.path)"]
            parts.append(c.expiresDate.map { "expires=\(Int($0.timeIntervalSince1970))" } ?? "session")
            if c.isHTTPOnly { parts.append("httpOnly") }
            if c.isSecure { parts.append("secure") }
            if let policy = c.sameSitePolicy { parts.append("sameSite=\(policy.rawValue)") }
            return "- " + parts.joined(separator: "; ")
        }
        switch request.command {
        case "cookie-list":
            return matching.isEmpty ? "no cookies" : matching.map(line).joined(separator: "\n")
        case "cookie-get":
            guard let name = request.args.first else { throw Failure("missing <name>") }
            guard !matching.isEmpty else { throw Failure("no cookie \(name)") }
            return matching.map(line).joined(separator: "\n")
        case "cookie-delete", "cookie-clear":
            if request.command == "cookie-delete", request.args.first == nil { throw Failure("missing <name>") }
            for cookie in matching { _ = try await withTimeout(5, "deleting a cookie") { await store.deleteCookie(cookie) } }
            return "deleted \(matching.count) cookies"
        default:
            guard request.args.count == 2 else { throw Failure("use: agweb cookie-set <name> <value> [--domain --path --expires --httpOnly --secure --sameSite]") }
            guard let domain = options["domain"] ?? workspace.current?.webView.url?.host else { throw Failure("no page to take the domain from; pass --domain") }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: request.args[0], .value: request.args[1], .domain: domain, .path: options["path"] ?? "/"]
            if let expires = options["expires"] {
                guard let seconds = Double(expires) else { throw Failure("--expires is a unix timestamp") }
                properties[.expires] = Date(timeIntervalSince1970: seconds)
            }
            if options["secure"] != nil { properties[.secure] = "TRUE" }
            if options["httpOnly"] != nil { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = options["sameSite"] {
                guard let policy = ["lax": HTTPCookieStringPolicy.sameSiteLax, "strict": .sameSiteStrict][sameSite.lowercased()] ?? (sameSite.lowercased() == "none" ? HTTPCookieStringPolicy(rawValue: "none") : nil) else {
                    throw Failure("--sameSite is Lax, Strict or None")
                }
                properties[.sameSitePolicy] = policy
            }
            guard let cookie = HTTPCookie(properties: properties) else { throw Failure("WebKit rejected that cookie") }
            _ = try await withTimeout(5, "setting a cookie") { await store.setCookie(cookie) }
            return "set " + line(cookie)
        }
    }

    /// Playwright's storage-state format: every cookie of the profile, and localStorage of the origins open in the
    /// workspace (others can't be read without loading them).
    func stateSave(_ workspace: Workspace) async throws -> String {
        let all = try await withTimeout(5, "reading cookies") { await workspace.dataStore.httpCookieStore.allCookies() }
        let cookies: [[String: Any]] = all.map { c in
            ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "expires": c.expiresDate?.timeIntervalSince1970 ?? -1,
             "httpOnly": c.isHTTPOnly, "secure": c.isSecure, "sameSite": c.sameSitePolicy.map { $0.rawValue.capitalized } ?? "None"]
        }
        var origins: [String: [[String: String]]] = [:]
        for tab in workspace.tabs where tab.webView.url?.scheme?.hasPrefix("http") == true {
            guard let json = try? await tab.call(PageScripts.readStorage),
                  let read = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let origin = read["origin"] as? String, let items = read["items"] as? [[String]] else { continue }
            origins[origin] = items.map { ["name": $0[0], "value": $0[1]] }
        }
        let state: [String: Any] = ["cookies": cookies, "origins": origins.sorted { $0.key < $1.key }.map { ["origin": $0.key, "localStorage": $0.value] }]
        return String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func stateLoad(_ workspace: Workspace, json: String) async throws -> String {
        guard let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw Failure("not storage-state JSON") }
        var count = 0
        for entry in state["cookies"] as? [[String: Any]] ?? [] {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: entry["name"] ?? "", .value: entry["value"] ?? "", .domain: entry["domain"] ?? "", .path: entry["path"] ?? "/"]
            if let expires = entry["expires"] as? Double, expires > 0 { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if entry["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            if entry["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = (entry["sameSite"] as? String)?.lowercased(), sameSite != "none" { properties[.sameSitePolicy] = sameSite }
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            _ = try await withTimeout(5, "setting a cookie") { await workspace.dataStore.httpCookieStore.setCookie(cookie) }
            count += 1
        }
        var now: [String] = [], later = workspace.pendingStorage
        for origin in state["origins"] as? [[String: Any]] ?? [] {
            guard let name = origin["origin"] as? String else { continue }
            let items = (origin["localStorage"] as? [[String: String]] ?? []).compactMap { item in item["name"].map { [$0, item["value"] ?? ""] } }
            if let tab = workspace.tabs.first(where: { $0.webView.url.map { "\($0.scheme ?? "")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" } == name }) {
                _ = try await tab.call(PageScripts.writeStorage, ["items": items])
                now.append(name)
            } else {
                later[name] = items
            }
        }
        workspace.pendingStorage = later
        return "loaded \(count) cookies" + (now.isEmpty ? "" : "; localStorage set for \(now.joined(separator: ", "))")
            + (later.isEmpty ? "" : "; localStorage waits for \(later.keys.sorted().joined(separator: ", ")) to load")
    }
}
