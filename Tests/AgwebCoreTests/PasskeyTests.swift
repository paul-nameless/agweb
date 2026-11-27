import CryptoKit
import Foundation
import Testing
import AgwebCore

private let suffixes = PublicSuffixes(list: try! String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/public_suffix_list.dat"), encoding: .utf8))

@Test(arguments: [
    ("example.com", "example.com", true),
    ("example.com", "login.example.com", true),
    ("login.example.com", "example.com", false),
    ("com", "example.com", false),
    ("co.uk", "shop.co.uk", false),
    ("shop.co.uk", "www.shop.co.uk", true),
    ("github.io", "a.github.io", false),
    ("a.github.io", "a.github.io", true),
    ("ample.com", "example.com", false),
    ("127.0.0.1", "127.0.0.1", true),
    ("0.0.1", "127.0.0.1", false),
    ("localhost", "localhost", true),
    ("", "example.com", false),
    ("kobe.jp", "a.b.kobe.jp", false),
    ("compute.amazonaws.com", "x.eu-west-1.compute.amazonaws.com", false),
    ("xn--55qx5d.cn", "a.xn--55qx5d.cn", false),
    ("city.kobe.jp", "www.city.kobe.jp", true),
])
func rpIDs(rpID: String, host: String, allowed: Bool) {
    #expect(WebAuthn.rpIDAllowed(rpID, host: host, suffixes: suffixes) == allowed)
}

@Test func publicSuffixRules() {
    #expect(suffixes.isPublicSuffix("com"))
    #expect(suffixes.isPublicSuffix("github.io"))
    #expect(!suffixes.isPublicSuffix("example.com"))
    #expect(suffixes.isPublicSuffix("anything.ck")) // *.ck
    #expect(!suffixes.isPublicSuffix("www.ck")) // !www.ck
    #expect(suffixes.publicSuffix(of: "a.b.kobe.jp") == "b.kobe.jp")
    #expect(suffixes.publicSuffix(of: "www.city.kobe.jp") == "kobe.jp")
    #expect(suffixes.isPublicSuffix("xn--55qx5d.cn")) // 公司.cn
}

@Test func origins() {
    #expect(WebAuthn.origin(scheme: "https", host: "example.com", port: 443) == "https://example.com")
    #expect(WebAuthn.origin(scheme: "https", host: "example.com", port: 0) == "https://example.com")
    #expect(WebAuthn.origin(scheme: "http", host: "localhost", port: 8080) == "http://localhost:8080")
    #expect(WebAuthn.isSecure(scheme: "http", host: "localhost"))
    #expect(!WebAuthn.isSecure(scheme: "http", host: "example.com"))
}

@Test func cborIsCanonical() {
    #expect(CBOR.int(-7) == [0x26])
    #expect(CBOR.int(500) == [0x19, 0x01, 0xf4])
    // Keys sorted by encoded length, then bytes: fmt, attStmt, authData.
    let object = WebAuthn.attestationObject(authenticatorData: [1, 2])
    // Built in steps: one long `+` chain timed out in the type checker on CI's macOS 15 runner.
    var expected: [UInt8] = [0xa3, 0x63]
    expected += Array("fmt".utf8)
    expected += [0x64]
    expected += Array("none".utf8)
    expected += [0x67]
    expected += Array("attStmt".utf8)
    expected += [0xa0, 0x68]
    expected += Array("authData".utf8)
    expected += [0x42, 1, 2]
    #expect(object == expected)
}

@Test func assertionVerifies() throws {
    let key = P256.Signing.PrivateKey()
    let id: [UInt8] = Array(repeating: 7, count: 16)
    let cose = WebAuthn.coseKey(publicKey: key.publicKey)
    #expect(cose.count == 77)
    let created = WebAuthn.authenticatorData(rpID: "example.com", flags: WebAuthn.flags(create: true, synced: true), credentialID: id, coseKey: cose)
    #expect(created.count == 37 + 16 + 2 + 16 + 77)
    #expect(created[32] == 0x5d) // UP, UV, BE, BS, AT
    let data = WebAuthn.authenticatorData(rpID: "example.com", flags: WebAuthn.flags(create: false, synced: true))
    #expect(data[32] == 0x1d)
    #expect(WebAuthn.flags(create: false, synced: false) == 0x05)
    let client = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: [1, 2, 3], origin: "https://example.com", crossOrigin: false)
    #expect(String(decoding: client, as: UTF8.self) == #"{"type":"webauthn.get","challenge":"AQID","origin":"https://example.com","crossOrigin":false}"#)
    let signed = Data(data + Array(SHA256.hash(data: Data(client))))
    let signature = try key.signature(for: signed)
    #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature.derRepresentation), for: signed))
    #expect(WebAuthn.fromBase64url(WebAuthn.base64url([255, 254, 253, 0])) == [255, 254, 253, 0])
}

@Test(arguments: [
    ("https://www.gstatic.com/securitykey/origins.json", "accounts.google.com", true),
    ("https://www.gstatic.com/securitykey/origins.json", "evil.com", false),
    ("https://login.example.com/app", "www.example.com", true),
    ("https://example.org/app", "example.com", false),
    ("http://example.com/app", "example.com", false),
    ("https://b.github.io", "a.github.io", false),
])
func appIDs(appID: String, host: String, allowed: Bool) {
    #expect(WebAuthn.appIDAllowed(appID, host: host, suffixes: suffixes) == allowed)
}

@Test func registrableDomains() {
    #expect(suffixes.registrableDomain(of: "a.b.example.co.uk") == "example.co.uk")
    #expect(suffixes.registrableDomain(of: "co.uk") == nil)
    // A key's own attestation statement goes in as it came; "fmt" sorts before "attStmt" and "authData" by length.
    let statement = CBOR.map([(CBOR.text("alg"), CBOR.int(-7))])
    let object = WebAuthn.attestationObject(format: "packed", statement: statement, authenticatorData: [9])
    // Built in parts: macOS 15's compiler gives up type-checking it as one expression.
    let format: [UInt8] = [0xa3, 0x63] + Array("fmt".utf8) + CBOR.text("packed")
    let statementPart: [UInt8] = [0x67] + Array("attStmt".utf8) + statement
    let authDataPart: [UInt8] = [0x68] + Array("authData".utf8) + [0x41, 9]
    #expect(object == format + statementPart + authDataPart)
}
