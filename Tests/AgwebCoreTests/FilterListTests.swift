import Foundation
import Testing
import WebKit
@testable import AgwebCore

private func converted(_ text: String...) -> FilterConverter {
    var converter = FilterConverter()
    text.forEach { converter.add($0) }
    return converter
}

private func network(_ text: String) -> [ContentRule] { converted(text).lists().network.flatMap { $0 } }

/// Generic hiding rules, then site-specific ones.
private func hiding(_ text: String...) -> [ContentRule] {
    var converter = FilterConverter()
    text.forEach { converter.add($0) }
    return converter.lists().hiding.flatMap { $0 }
}

private func matches(_ rule: ContentRule, _ url: String) throws -> Bool { url.contains(try Regex(rule.trigger.urlFilter)) }

@Test func aHostFilterBlocksTheHostAndItsSubdomains() throws {
    let rule = try #require(network("||ads.example.com^$third-party").first)
    #expect(rule.trigger.urlFilter == "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[:/]")
    #expect(rule.trigger.loadType == ["third-party"])
    #expect(rule.action.type == "block")
    #expect(try matches(rule, "https://x.ads.example.com/a.js"))
    #expect(try matches(rule, "https://ads.example.com:8443/x"))
    #expect(try !matches(rule, "https://badads.example.com/"))
    #expect(try !matches(rule, "https://ads.example.com.evil/"))
}

@Test func aTrailingSeparatorAfterAPathAlsoMatchesTheEnd() throws {
    let rule = try #require(network("||example.com/track^").first)
    #expect(try matches(rule, "https://example.com/track"))
    #expect(try matches(rule, "https://example.com/track?x=1"))
    #expect(try !matches(rule, "https://example.com/tracker"))
}

@Test func everyNetworkListEndsWithTheTopFrameRule() throws {
    let blocks = (1...12).map { "||ads\($0).com^" }.joined(separator: "\n")
    let lists = converted(blocks + "\n@@||cdn.ads1.com^$script\n||keep.com^$important").lists(maxRules: 5).network
    #expect(lists.count > 1)
    for list in lists {
        #expect(list.count <= 5)
        let last = try #require(list.last)
        #expect(last.action.type == "ignore-previous-rules")
        #expect(last.trigger.resourceType == ["document"])
        #expect(last.trigger.loadContext == ["top-frame"])
        // The exception follows the blocks it may cancel, in every list.
        let exception = try #require(list.firstIndex { $0.trigger.urlFilter.contains("cdn") })
        #expect(list[..<exception].allSatisfy { $0.action.type == "block" })
    }
    #expect(lists.dropLast().allSatisfy { !$0.contains { $0.trigger.urlFilter.contains("keep") } })
    let important = try #require(lists.last?.firstIndex { $0.trigger.urlFilter.contains("keep") })
    #expect(lists.last![important - 1].trigger.urlFilter.contains("cdn"))
    #expect(Set(lists.flatMap { $0 }.filter { $0.action.type == "block" && !$0.trigger.urlFilter.contains("keep") }).count == 12)
}

@Test func optionsMapToWebKitTriggers() throws {
    let rule = try #require(network("/banner/ads.$script,xhr,domain=a.com|b.org").first)
    #expect(rule.trigger.urlFilter == "/banner/ads\\.")
    #expect(rule.trigger.resourceType == ["fetch", "script"])
    #expect(rule.trigger.ifDomain == ["*a.com", "*b.org"])
    let frame = try #require(network("||ads.net^$subdocument").first)
    #expect(frame.trigger.loadContext == ["child-frame"])
    let negated = try #require(network("||x.net^$~image").first)
    #expect(negated.trigger.resourceType?.contains("image") == false)
    #expect(negated.trigger.resourceType?.contains("script") == true)
}

@Test func sitesWebKitCannotMatch() throws {
    // A block keeps the sites it can name, and is skipped when an exclusion can't be kept.
    #expect(try #require(network("||x.com^$domain=a.com|b.*").first).trigger.ifDomain == ["*a.com"])
    #expect(network("||x.com^$domain=b.*").count == 1)
    #expect(network("||x.com^$domain=~b.*").count == 1)
    #expect(network("||x.com^$domain=a.com|~www.a.com").count == 1)
    // An exception keeps what it can: applied more widely it only lets more through.
    let allow = try #require(network("@@||sdk.com/ima.js$script,domain=maxisciences.com|gentside.*").first { $0.action.type == "ignore-previous-rules" && $0.trigger.ifDomain != nil })
    #expect(allow.trigger.ifDomain == ["*maxisciences.com"])
    #expect(hiding("~example.*##.bad").isEmpty)
    #expect(hiding("wp.pl,~www.wp.pl##.ad").isEmpty)
}

@Test(arguments: ["/ads[0-9]+/", "||x.com^$redirect=noop.js", "||x.com^$removeparam=utm", "||x.com^$csp=script-src 'none'",
                  "ad", "example.com##+js(nowebrtc)", "example.com##.ad:has-text(Sponsored)"])
func whatWebKitCannotExpressIsSkipped(filter: String) {
    #expect(network(filter).count == 1)
    #expect(hiding(filter).isEmpty)
}

@Test func badfilterCancelsItsFilter() {
    #expect(network("||x.com^$third-party\n||x.com^$third-party,badfilter").count == 1)
}

@Test func ifBlocksTakeTheBranchThatHoldsForWebKit() {
    func kept(_ text: String) -> [String] { network(text).dropLast().map(\.trigger.urlFilter) }
    #expect(kept("!#if env_firefox\n||x.com^\n!#endif\n||y.com^").count == 1)
    #expect(kept("!#if cap_html_filtering\n||x.com^\n!#else\n||y.com^\n!#endif").first?.contains("y\\.com") == true)
    #expect(kept("!#if env_safari\n||x.com^\n!#endif").count == 1)
    #expect(kept("!#if !env_firefox && !env_chromium\n||x.com^\n!#endif").count == 1)
    #expect(kept("!#if (env_chromium || env_safari)\n!#if env_mobile\n||x.com^\n!#else\n||y.com^\n!#endif\n!#endif").first?.contains("y\\.com") == true)
}

private let hidingList = [
    "##.ad-banner", "##.sponsor", "#@#.sponsor", "~news.com##.promo", "a.com,b.com##.sidebar-ad", "b.com#@#.ad-banner",
    "b.com#@#.sidebar-ad",
]

@Test func elementHidingAndItsExceptions() {
    let rules = hiding(hidingList.joined(separator: "\n"))
    #expect(rules.map(\.action.selector) == [".ad-banner", ".promo", ".sidebar-ad"])
    #expect(rules[0].trigger.unlessDomain == ["*b.com"])
    #expect(rules[1].trigger.unlessDomain == ["*news.com"])
    #expect(rules[2].trigger.ifDomain == ["*a.com"])
}

@Test func hidingExceptionsCountWhicheverComesFirst() {
    #expect(hiding(hidingList.reversed().joined(separator: "\n")) == hiding(hidingList.joined(separator: "\n")))
    // An exception in one list, its rule in a later one.
    #expect(hiding("b.com#@#.x", "##.x").first?.trigger.unlessDomain == ["*b.com"])
}

@Test func generichideLeavesSiteRulesAlone() throws {
    let lists = converted("##.generic\na.com##.only\n@@||a.com^$generichide\n@@||b.com^$specifichide\n@@||c.com^$elemhide").lists().hiding
    #expect(lists.count == 2)
    let generic = lists[0], specific = lists[1]
    func offOn(_ list: [ContentRule]) -> [String] { list.filter { $0.action.type == "ignore-previous-rules" }.map(\.trigger.urlFilter) }
    #expect(offOn(generic).contains { $0.contains("a\\.com") } && offOn(generic).contains { $0.contains("c\\.com") })
    #expect(!offOn(generic).contains { $0.contains("b\\.com") })
    #expect(offOn(specific).contains { $0.contains("b\\.com") } && offOn(specific).contains { $0.contains("c\\.com") })
    #expect(!offOn(specific).contains { $0.contains("a\\.com") })
    // Exceptions follow the rules they cancel.
    #expect(generic.first?.action.type == "css-display-none" && generic.last?.action.type == "ignore-previous-rules")
}

@Test func generichideByPathOrDomainOption() throws {
    let generic = try #require(converted("##.x\n@@||www.google.*/search?$generichide\n@@$ghide,domain=howtogeek.com|xda.com").lists().hiding.first)
    let offs = generic.filter { $0.action.type == "ignore-previous-rules" }
    #expect(offs.count == 2)
    #expect(try offs.contains { try matches($0, "https://www.google.de/search?q=x") })
    #expect(offs.contains { $0.trigger.ifDomain == ["*howtogeek.com", "*xda.com"] })
}

@Test func encodesToWebKitKeys() throws {
    let json = String(decoding: try JSONEncoder().encode(network("||x.com^$third-party")), as: UTF8.self)
    #expect(json.contains("\"url-filter\""))
    #expect(json.contains("\"load-type\":[\"third-party\"]"))
    #expect(!json.contains("if-domain"))
}

/// The real check: WebKit compiles what the converter writes, every option included. One rule it refuses fails the
/// whole list.
@MainActor
@Test func webKitCompilesEveryKindOfRule() async throws {
    let lists = converted("""
        ||ads.com^$third-party
        ||pop.com^$popup
        ||all.com^$all
        /track^$websocket,ping,other
        /Banner.$match-case
        ||x.com^$~third-party,domain=~y.com
        @@||site.com^$document
        *$script,domain=z.com
        ||frame.com^$subdocument
        @@||cdn.com/lib.js^$script,domain=a.com|b.*
        ||imp.com^$important
        ##.ad:has(> img)
        ~news.com##.promo
        a.com##.only
        @@||g.com^$generichide
        @@||s.com^$specifichide
        """).lists()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agweb-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try #require(WKContentRuleListStore(url: folder))
    for (i, list) in (lists.network + lists.hiding).enumerated() {
        let json = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        let compiled = try await store.compileContentRuleList(forIdentifier: "test-\(i)", encodedContentRuleList: json)
        #expect(compiled != nil)
    }
}
