import Foundation

/// One WebKit content rule (Safari content blocker JSON).
public struct ContentRule: Codable, Hashable, Sendable {
    public struct Trigger: Codable, Hashable, Sendable {
        public var urlFilter: String
        public var caseSensitive: Bool?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var loadContext: [String]?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter", caseSensitive = "url-filter-is-case-sensitive", resourceType = "resource-type"
            case loadType = "load-type", loadContext = "load-context", ifDomain = "if-domain", unlessDomain = "unless-domain"
        }
    }

    public struct Action: Codable, Hashable, Sendable {
        public var type: String
        public var selector: String?
    }

    public var trigger: Trigger
    public var action: Action
}

/// Converts uBlock Origin / Adblock Plus filter lists to WebKit content rules. Takes the part WebKit can express:
/// network filters with their usual options, exceptions, element hiding and its exceptions. Skips regex filters,
/// scriptlets, procedural cosmetics (:has-text), redirects and the options WebKit has no equivalent for.
public struct FilterConverter: Sendable {
    /// WebKit refuses a list over 150,000 rules.
    public static let maxRules = 140_000
    /// uBO's `!#if` tokens that hold here: WebKit is Safari's engine; no HTML filtering, scriptlets or MV3.
    static let platform: Set<String> = ["env_safari"]

    private var network: [String] = []
    private var badfilters: Set<String> = []
    /// Generic selectors, each with the sites it must not hide on (~site##selector).
    private var genericHides: [String: Set<String>] = [:]
    /// Site-specific selectors and the sites they hide on.
    private var specificHides: [String: Set<String>] = [:]
    /// site#@#selector: the sites where a selector must not hide. Applied when the lists are built, so an exception
    /// counts whichever list, or line, comes first.
    private var hideExceptions: [String: Set<String>] = [:]
    /// #@#selector: never hidden.
    private var genericOff: Set<String> = []

    public init() {}

    public mutating func add(_ text: String) {
        // One entry per open !#if: whether its branch applies.
        var conditions: [Bool] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") { conditions.append(Self.evaluate(String(line.dropFirst(5)))); continue }
            if line.hasPrefix("!#else") { if !conditions.isEmpty { conditions[conditions.count - 1].toggle() }; continue }
            if line.hasPrefix("!#endif") { _ = conditions.popLast(); continue }
            guard !conditions.contains(false), !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
            if let range = line.range(of: "#@#") {
                addHideException(sites: line[..<range.lowerBound], selector: String(line[range.upperBound...]))
            } else if let range = line.range(of: "##") {
                addHide(sites: line[..<range.lowerBound], selector: String(line[range.upperBound...]))
            } else if line.contains("#?#") || line.contains("#$#") || line.contains("#%#") || line.contains("#@$#")
                        || line.contains("#@?#") || line.contains("$$") {
                continue
            } else if line.hasSuffix("$badfilter") || line.contains(",badfilter") || line.contains("$badfilter,") {
                badfilters.insert(Self.removingBadfilter(line))
            } else {
                network.append(line)
            }
        }
    }

    /// The rules as lists WebKit compiles one by one: network lists, then generic hiding, then site-specific hiding.
    /// An `ignore-previous-rules` only reaches rules in its own list, so each list carries the exceptions it needs.
    public func lists(maxRules: Int = maxRules) -> (network: [[ContentRule]], hiding: [[ContentRule]]) {
        var blocks: [ContentRule] = [], allows: [ContentRule] = [], important: [ContentRule] = []
        var genericOffRules: [ContentRule] = [], specificOffRules: [ContentRule] = []
        var seen: Set<ContentRule> = []
        for line in network where !badfilters.contains(line) {
            guard let parsed = Self.network(line) else { continue }
            if let hide = parsed.hideOff {
                if hide.generic { genericOffRules.append(parsed.rule) }
                if hide.specific { specificOffRules.append(parsed.rule) }
                continue
            }
            guard seen.insert(parsed.rule).inserted else { continue }
            if parsed.rule.action.type == "ignore-previous-rules" {
                allows.append(parsed.rule)
            } else if parsed.important {
                important.append(parsed.rule)
            } else {
                blocks.append(parsed.rule)
            }
        }
        // The page an agent or the person opens always loads; only what it pulls in is filtered.
        let topFrame = ContentRule(trigger: .init(urlFilter: ".*", resourceType: ["document"], loadContext: ["top-frame"]),
                                   action: .init(type: "ignore-previous-rules"))
        let room = max(1, maxRules - allows.count - important.count - 1)
        var network: [[ContentRule]] = stride(from: 0, to: max(blocks.count, 1), by: room).map { start in
            Array(blocks[start..<min(start + room, blocks.count)]) + allows
        }
        network[network.count - 1] += important
        network = network.map { $0 + [topFrame] }

        let generic = genericHides.keys.filter { !genericOff.contains($0) }.sorted().map { selector in
            let unless = genericHides[selector, default: []].union(hideExceptions[selector] ?? [])
            return ContentRule(trigger: .init(urlFilter: ".*", unlessDomain: unless.isEmpty ? nil : unless.sorted().map { "*" + $0 }),
                               action: .init(type: "css-display-none", selector: selector))
        }
        let specific = specificHides.keys.sorted().compactMap { selector -> ContentRule? in
            let sites = specificHides[selector, default: []].subtracting(hideExceptions[selector] ?? [])
            guard !sites.isEmpty else { return nil }
            return ContentRule(trigger: .init(urlFilter: ".*", ifDomain: sites.sorted().map { "*" + $0 }),
                               action: .init(type: "css-display-none", selector: selector))
        }
        let hiding = [Array(generic.prefix(maxRules - genericOffRules.count)) + genericOffRules,
                      Array(specific.prefix(maxRules - specificOffRules.count)) + specificOffRules]
        return (network, hiding.filter { !$0.isEmpty })
    }

    // MARK: !#if

    /// A uBO preprocessor condition: tokens joined by !, &&, || and parentheses.
    static func evaluate(_ expression: String) -> Bool {
        var tokens: [String] = []
        var rest = Substring(expression)
        while let first = rest.first {
            if first == " " { rest = rest.dropFirst() } else if rest.hasPrefix("&&") || rest.hasPrefix("||") {
                tokens.append(String(rest.prefix(2))); rest = rest.dropFirst(2)
            } else if "!()".contains(first) {
                tokens.append(String(first)); rest = rest.dropFirst()
            } else {
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !name.isEmpty else { return false }
                tokens.append(String(name)); rest = rest.dropFirst(name.count)
            }
        }
        var i = 0
        func next() -> String? { i < tokens.count ? tokens[i] : nil }
        func primary() -> Bool {
            guard let token = next() else { return false }
            i += 1
            if token == "!" { return !primary() }
            if token == "(" {
                let value = any()
                if next() == ")" { i += 1 }
                return value
            }
            return platform.contains(token)
        }
        func all() -> Bool {
            var value = primary()
            while next() == "&&" { i += 1; let right = primary(); value = value && right }
            return value
        }
        func any() -> Bool {
            var value = all()
            while next() == "||" { i += 1; let right = all(); value = value || right }
            return value
        }
        return any()
    }

    // MARK: Sites

    /// A filter's site list as WebKit's if-domain or unless-domain; nil when the filter must be skipped.
    /// WebKit can't match an entity (example.*) or hold both lists. A block or a hide is skipped rather than applied
    /// where the list says not to; an exception keeps what it can, since applying it more widely only lets more through.
    static func domains(_ list: Substring, separator: Character, exception: Bool) -> (on: [String], off: [String])? {
        var on: [String] = [], off: [String] = [], droppedOn = false
        for entry in list.split(separator: separator) {
            let entry = entry.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = entry.hasPrefix("~")
            let site = negated ? String(entry.dropFirst()) : entry
            let plain = !site.isEmpty && site.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
                && (site.contains(".") || site == "localhost")
            switch (plain, negated) {
            case (true, false): on.append(site)
            case (true, true): off.append(site)
            case (false, false): droppedOn = true
            case (false, true): if !exception { return nil }
            }
        }
        if droppedOn && on.isEmpty { return nil }
        if !on.isEmpty && !off.isEmpty {
            // ~www.a.com inside a.com: one trigger can't say both.
            if !exception && off.contains(where: { site in on.contains { site == $0 || site.hasSuffix("." + $0) } }) { return nil }
            off = []
        }
        return (on, off)
    }

    // MARK: Element hiding

    /// uBO's procedural and action operators; plain CSS (:has, :not, :is) passes.
    static let procedural = [":has-text(", ":-abp-", ":upward(", ":xpath(", ":matches-css", ":style(", ":remove(", ":watch-attr(",
                             ":min-text-length(", ":others(", ":matches-path(", ":matches-attr(", ":matches-prop(", ":remove-attr(",
                             ":remove-class(", ":matches-media(", ":contains(", ":nth-ancestor(", ":if(", ":if-not(", ":shadow-dom"]

    static func cleanSelector(_ selector: String) -> String? {
        let selector = selector.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, !selector.hasPrefix("+js("), !selector.hasPrefix("^"), selector.allSatisfy(\.isASCII),
              !procedural.contains(where: selector.contains) else { return nil }
        return selector
    }

    private mutating func addHide(sites list: Substring, selector: String) {
        guard let selector = Self.cleanSelector(selector), let sites = Self.domains(list, separator: ",", exception: false) else { return }
        if sites.on.isEmpty {
            genericHides[selector, default: []].formUnion(sites.off)
        } else {
            specificHides[selector, default: []].formUnion(sites.on)
        }
    }

    private mutating func addHideException(sites list: Substring, selector: String) {
        guard let selector = Self.cleanSelector(selector), let sites = Self.domains(list, separator: ",", exception: true) else { return }
        if sites.on.isEmpty {
            // ~a.com#@#.x would be "hide .x only on a.com": rare, and not worth a rule kind of its own.
            if sites.off.isEmpty { genericOff.insert(selector) }
        } else {
            hideExceptions[selector, default: []].formUnion(sites.on)
        }
    }

    // MARK: Network filters

    struct Parsed {
        var rule: ContentRule
        var important = false
        /// An exception for element hiding ($generichide, $specifichide, $elemhide), not for loads.
        var hideOff: (generic: Bool, specific: Bool)?
    }

    static let types: [String: [String]] = [
        "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "xmlhttprequest": ["fetch"], "xhr": ["fetch"], "font": ["font"], "media": ["media"], "websocket": ["websocket"],
        "ping": ["ping"], "beacon": ["ping"], "other": ["other"], "popup": ["popup"], "document": ["document"], "doc": ["document"],
        "subdocument": ["document"], "frame": ["document"],
    ]
    /// What a filter with no type, or a negated one, applies to: uBO leaves pages and popups out of it.
    static let defaultTypes = ["image", "style-sheet", "script", "font", "media", "fetch", "websocket", "ping", "other", "svg-document"]

    static func network(_ line: String) -> Parsed? {
        var text = Substring(line)
        let allow = text.hasPrefix("@@")
        if allow { text = text.dropFirst(2) }
        var pattern = text, options: [Substring] = []
        // A regex filter's own $ lands in the options and fails them; regex filters are skipped anyway.
        if let dollar = text.lastIndex(of: "$") {
            pattern = text[..<dollar]
            options = text[text.index(after: dollar)...].split(separator: ",")
        }
        var trigger = ContentRule.Trigger(urlFilter: "")
        var important = false, hideOff: (generic: Bool, specific: Bool)?
        var types: [String] = [], negatedTypes: [String] = [], subdocument = false, document = false
        for option in options {
            let (name, value) = option.firstIndex(of: "=").map { (option[..<$0], option[option.index(after: $0)...]) } ?? (option, "")
            switch name {
            case "third-party", "3p": trigger.loadType = ["third-party"]
            case "~third-party", "first-party", "1p", "~3p": trigger.loadType = ["first-party"]
            case "important": important = true
            case "match-case": trigger.caseSensitive = true
            case "all": types += defaultTypes + ["document", "popup"]
            case "domain", "from":
                guard let sites = domains(value, separator: "|", exception: allow) else { return nil }
                trigger.ifDomain = sites.on.isEmpty ? nil : sites.on.map { "*" + $0 }
                trigger.unlessDomain = sites.off.isEmpty ? nil : sites.off.map { "*" + $0 }
            case "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide":
                guard allow else { return nil }
                let generic = !name.hasPrefix("s"), specific = !name.hasPrefix("g")
                hideOff = (generic || hideOff?.generic == true, specific || hideOff?.specific == true)
            case _ where name.hasPrefix("~"):
                guard let mapped = Self.types[String(name.dropFirst())] else { return nil }
                negatedTypes += mapped
            default:
                guard let mapped = Self.types[String(name)] else { return nil }
                if name == "subdocument" || name == "frame" { subdocument = true }
                if name == "document" || name == "doc" { document = true }
                types += mapped
            }
        }
        guard let filter = urlFilter(pattern) else { return nil }
        trigger.urlFilter = filter
        if let hideOff {
            // Matched against the page's address, in the hiding lists; types and party don't apply there.
            let rule = ContentRule(trigger: .init(urlFilter: filter, ifDomain: trigger.ifDomain, unlessDomain: trigger.unlessDomain),
                                   action: .init(type: "ignore-previous-rules"))
            return Parsed(rule: rule, hideOff: hideOff)
        }
        if !negatedTypes.isEmpty {
            types += (types.isEmpty ? defaultTypes : []).filter { !negatedTypes.contains($0) }
            if types.isEmpty { return nil }
        }
        if !types.isEmpty { trigger.resourceType = Array(Set(types)).sorted() }
        // A frame filter must not block the page itself; a document one blocks only the page.
        if subdocument && !document && types.allSatisfy({ $0 == "document" }) { trigger.loadContext = ["child-frame"] }
        // $document on an exception lets everything on that site's pages through.
        if allow && document, trigger.ifDomain == nil, pattern.hasPrefix("||"), let host = host(of: pattern.dropFirst(2)) {
            trigger = .init(urlFilter: ".*", ifDomain: ["*" + host])
        }
        return Parsed(rule: ContentRule(trigger: trigger, action: .init(type: allow ? "ignore-previous-rules" : "block")), important: important)
    }

    /// "example.com^" or "example.com/" to example.com, when the pattern is a bare host.
    static func host(of pattern: Substring) -> String? {
        let host = pattern.prefix { $0 != "^" && $0 != "/" }
        guard host.contains("."), host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              host.count + 1 >= pattern.count else { return nil }
        return host.lowercased()
    }

    /// The filter's pattern as WebKit's regex subset (no alternation, no counted repeats); nil for regex filters and
    /// anything with characters that subset can't hold.
    static func urlFilter(_ pattern: Substring) -> String? {
        var pattern = pattern
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil }
        guard pattern.allSatisfy({ $0.isASCII && !"{}[]()\\\"' ".contains($0) }) else { return nil }
        var out = ""
        if pattern.hasPrefix("||") {
            out = "^[^:]+://+([^:/]+\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            out = "^"
            pattern = pattern.dropFirst()
        }
        var anchoredEnd = false
        if pattern.hasSuffix("|") { anchoredEnd = true; pattern = pattern.dropLast() }
        while pattern.hasPrefix("*") { pattern = pattern.dropFirst() }
        while pattern.hasSuffix("*") { pattern = pattern.dropLast(); anchoredEnd = false }
        if pattern.isEmpty { return out.isEmpty ? ".*" : nil }
        // Too short to mean anything ("ad"); uBO drops these too.
        if out.isEmpty && pattern.filter({ $0 != "^" && $0 != "*" }).count < 3 { return nil }
        let separator = "[^a-zA-Z0-9_.%-]"
        let hostOnly = out.hasPrefix("^[^:]+") && !pattern.contains("/")
        for (i, char) in pattern.enumerated() {
            switch char {
            case "*": out += ".*"
            case "^" where i == pattern.count - 1:
                // After a bare host the next character is always / or :; elsewhere ^ also matches the end.
                if hostOnly { out += "[:/]" } else { out += "(" + separator + ".*)?$"; anchoredEnd = false }
            case "^": out += separator
            case "|": return nil
            case ".", "+", "?", "$": out += "\\" + String(char)
            default: out.append(char)
            }
        }
        if anchoredEnd { out += "$" }
        return out
    }

    static func removingBadfilter(_ line: String) -> String {
        guard let dollar = line.lastIndex(of: "$") else { return line }
        let options = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
        return String(line[..<dollar]) + (options.isEmpty ? "" : "$" + options.joined(separator: ","))
    }
}
