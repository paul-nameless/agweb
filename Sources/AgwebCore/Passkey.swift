import CryptoKit
import Foundation

/// The bytes of a WebAuthn ceremony that agweb answers as its own authenticator: attestation "none", ES256 only.
public enum WebAuthn {
    public static let es256 = -7
    /// User present and verified; backup eligible and backed up when the key moves with the Keychain, like a synced
    /// passkey (not a fresh workspace's, gone at close); on creation, attested credential data.
    public static func flags(create: Bool, synced: Bool) -> UInt8 {
        0x01 | 0x04 | (synced ? 0x08 | 0x10 : 0) | (create ? 0x40 : 0)
    }

    public static func coseKey(publicKey: P256.Signing.PublicKey) -> [UInt8] {
        let raw = [UInt8](publicKey.rawRepresentation)
        return CBOR.map([(CBOR.int(1), CBOR.int(2)), (CBOR.int(3), CBOR.int(es256)), (CBOR.int(-1), CBOR.int(1)),
                         (CBOR.int(-2), CBOR.bytes(Array(raw[..<32]))), (CBOR.int(-3), CBOR.bytes(Array(raw[32...])))])
    }

    /// Sign count stays 0, as for synced passkeys: sites then skip the clone check.
    public static func authenticatorData(rpID: String, flags: UInt8, credentialID: [UInt8]? = nil, coseKey: [UInt8]? = nil) -> [UInt8] {
        var out = [UInt8](SHA256.hash(data: Data(rpID.utf8))) + [flags, 0, 0, 0, 0]
        if let credentialID, let coseKey {
            out += [UInt8](repeating: 0, count: 16) // AAGUID: none
            out += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)] + credentialID + coseKey
        }
        return out
    }

    public static func attestationObject(authenticatorData: [UInt8]) -> [UInt8] {
        attestationObject(format: "none", statement: CBOR.map([]), authenticatorData: authenticatorData)
    }

    /// `statement`: the attStmt map, already CBOR, as a security key gave it.
    public static func attestationObject(format: String, statement: [UInt8], authenticatorData: [UInt8]) -> [UInt8] {
        CBOR.map([(CBOR.text("fmt"), CBOR.text(format)), (CBOR.text("attStmt"), statement), (CBOR.text("authData"), CBOR.bytes(authenticatorData))])
    }

    /// The FIDO AppID extension's id: https, on the page's own registrable domain. Google's sign-in names the gstatic
    /// facet list, which Chrome allows for google.com.
    public static func appIDAllowed(_ appID: String, host: String, suffixes: PublicSuffixes) -> Bool {
        guard let url = URL(string: appID), url.scheme == "https", let appHost = url.host?.lowercased() else { return false }
        let host = host.lowercased()
        if appID == "https://www.gstatic.com/securitykey/origins.json" { return host == "google.com" || host.hasSuffix(".google.com") }
        guard let site = suffixes.registrableDomain(of: host) else { return false }
        return suffixes.registrableDomain(of: appHost) == site
    }

    /// In the key order the spec serializes, which some servers compare byte for byte.
    public static func clientDataJSON(type: String, challenge: [UInt8], origin: String, crossOrigin: Bool) -> [UInt8] {
        func quoted(_ text: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return Array(#"{"type":\#(quoted(type)),"challenge":\#(quoted(base64url(challenge))),"origin":\#(quoted(origin)),"crossOrigin":\#(crossOrigin)}"#.utf8)
    }

    public static func base64url(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64url(_ text: String) -> [UInt8]? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).map { [UInt8]($0) }
    }

    /// The origin as clientDataJSON states it: no default port.
    public static func origin(scheme: String, host: String, port: Int) -> String {
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port == 0
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(shownHost)" + (defaultPort ? "" : ":\(port)")
    }

    /// https, or http on the machine itself.
    public static func isSecure(scheme: String, host: String) -> Bool {
        scheme == "https" || (scheme == "http" && (host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"))
    }

    /// HTML's "is a registrable domain suffix of or is equal to": the page's host, or a parent of it that is neither a
    /// public suffix nor inside the host's own one, so `a.github.io` can't claim `github.io`, nor `a.b.kobe.jp`
    /// (`*.kobe.jp`) claim `kobe.jp`. An IP address only as itself.
    public static func rpIDAllowed(_ rpID: String, host: String, suffixes: PublicSuffixes) -> Bool {
        let rpID = rpID.lowercased(), host = host.lowercased()
        guard !rpID.isEmpty else { return false }
        if rpID == host { return true }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        guard host.hasSuffix("." + rpID), !suffixes.isPublicSuffix(rpID) else { return false }
        let hostSuffix = suffixes.publicSuffix(of: host)
        return hostSuffix != rpID && !hostSuffix.hasSuffix("." + rpID)
    }
}

/// The public suffix list (publicsuffix.org), ICANN and private sections alike. Hosts arrive as ASCII, so the list's
/// Unicode rules are turned into punycode (`公司.cn` into `xn--55qx5d.cn`) to match them.
public struct PublicSuffixes: Sendable {
    private let rules: Set<String>, wildcards: Set<String>, exceptions: Set<String>

    public init(list: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for line in list.split(whereSeparator: \.isNewline) {
            var rule = line.prefix { !$0.isWhitespace }.lowercased()
            if rule.isEmpty || rule.hasPrefix("//") { continue }
            if !rule.allSatisfy(\.isASCII) { rule = rule.split(separator: ".").map { Punycode.label(String($0)) }.joined(separator: ".") }
            if rule.hasPrefix("!") { exceptions.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { wildcards.insert(String(rule.dropFirst(2))) }
            else { rules.insert(rule) }
        }
        (self.rules, self.wildcards, self.exceptions) = (rules, wildcards, exceptions)
    }

    /// The list's algorithm: an exception rule wins, then the longest matching rule, then "*" (the last label).
    public func publicSuffix(of domain: String) -> String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return domain }
        let tails = labels.indices.map { labels[$0...].joined(separator: ".") }
        if let i = tails.indices.first(where: { exceptions.contains(tails[$0]) }), i + 1 < labels.count { return tails[i + 1] }
        for i in tails.indices {
            if rules.contains(tails[i]) || (i + 1 < tails.count && wildcards.contains(tails[i + 1])) { return tails[i] }
        }
        return tails[tails.count - 1]
    }

    /// The public suffix and one label more; nil for a public suffix itself.
    public func registrableDomain(of domain: String) -> String? {
        let domain = domain.lowercased()
        guard !isPublicSuffix(domain) else { return nil }
        let suffix = publicSuffix(of: domain)
        return domain.dropLast(suffix.count + 1).split(separator: ".").last.map { "\($0).\(suffix)" }
    }

    public func isPublicSuffix(_ domain: String) -> Bool {
        let domain = domain.lowercased()
        return domain.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) || publicSuffix(of: domain) == domain
    }
}

/// RFC 3492, for one label of the public suffix list.
enum Punycode {
    static func label(_ text: String) -> String {
        let input = text.unicodeScalars.map(\.value)
        guard input.contains(where: { $0 >= 0x80 }) else { return text }
        let base: UInt32 = 36, tMin: UInt32 = 1, tMax: UInt32 = 26
        func digit(_ d: UInt32) -> Character { Character(UnicodeScalar(d < 26 ? d + 97 : d + 22)!) }
        func adapt(_ delta: UInt32, _ points: UInt32, _ first: Bool) -> UInt32 {
            var delta = first ? delta / 700 : delta / 2, k: UInt32 = 0
            delta += delta / points
            while delta > (base - tMin) * tMax / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + 38)
        }
        var output = String(input.filter { $0 < 0x80 }.map { Character(UnicodeScalar($0)!) })
        let basic = UInt32(output.count)
        if basic > 0 { output.append("-") }
        var n: UInt32 = 128, delta: UInt32 = 0, bias: UInt32 = 72, handled = basic
        while handled < input.count {
            let m = input.filter { $0 >= n }.min()!
            delta += (m - n) * (handled + 1)
            n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta, k = base
                    while true {
                        let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return "xn--" + output
    }
}

/// The CBOR (RFC 8949) a WebAuthn reply needs, in CTAP2 canonical form: map keys sorted by length, then bytewise.
public enum CBOR {
    static func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
        let m = major << 5
        switch value {
        case ..<24: return [m | UInt8(value)]
        case ..<0x100: return [m | 24, UInt8(value)]
        case ..<0x10000: return [m | 25] + (0..<2).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        case ..<0x1_0000_0000: return [m | 26] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        default: return [m | 27] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }

    public static func int(_ value: Int) -> [UInt8] { value >= 0 ? head(0, UInt64(value)) : head(1, UInt64(-1 - value)) }
    public static func bytes(_ value: [UInt8]) -> [UInt8] { head(2, UInt64(value.count)) + value }
    public static func text(_ value: String) -> [UInt8] { head(3, UInt64(value.utf8.count)) + Array(value.utf8) }

    public static func map(_ pairs: [([UInt8], [UInt8])]) -> [UInt8] {
        let sorted = pairs.sorted { $0.0.count != $1.0.count ? $0.0.count < $1.0.count : $0.0.lexicographicallyPrecedes($1.0) }
        return head(5, UInt64(pairs.count)) + sorted.flatMap { $0.0 + $0.1 }
    }
}
