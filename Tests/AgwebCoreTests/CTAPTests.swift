import CryptoKit
import Foundation
import Testing
import AgwebCore

private func hex(_ text: String) -> [UInt8] {
    var out: [UInt8] = [], chars = Array(text)
    while chars.count >= 2 { out.append(UInt8(String(chars[0..<2]), radix: 16)!); chars.removeFirst(2) }
    return out
}

@Test func cborDecodesWhatTheEncoderWrites() {
    let encoded = CBOR.map([(CBOR.int(1), CBOR.text("fido")), (CBOR.int(-7), CBOR.bytes([1, 2, 3])),
                            (CBOR.text("list"), CBOR.array([CBOR.int(0), CBOR.int(23), CBOR.int(24), CBOR.int(65_536), CBOR.int(-1000)])),
                            (CBOR.text("opts"), CBOR.map([(CBOR.text("rk"), CBOR.bool(true)), (CBOR.text("up"), CBOR.bool(false))]))])
    let value = CBOR.decode(encoded)
    #expect(value?[1]?.text == "fido")
    #expect(value?[-7]?.bytes == [1, 2, 3])
    #expect(value?["list"]?.array?.compactMap(\.int) == [0, 23, 24, 65_536, -1000])
    #expect(value?["opts"]?["rk"]?.bool == true)
    #expect(value?["opts"]?["up"]?.bool == false)
    #expect(value?["missing"] == nil)
    #expect(CBOR.decode([0xf6]) == .null)
    #expect(CBOR.decode([0xfb, 0, 0, 0, 0, 0, 0, 0, 0]) == .other) // a float
    #expect(CBOR.decode([0xc0, 0x61, 0x61]) == .text("a")) // a tag is dropped for its content
}

@Test(arguments: [
    [UInt8](), [0x18], [0x5f, 0x41, 0x00, 0xff], [0x9f, 0xff], [0x62, 0x61], [0x62, 0xff, 0xfe], [0x1c],
    [0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0xbb, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
    [0x5b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [0x01, 0x02],
    [UInt8](repeating: 0x81, count: 40) + [0x00],
])
func cborRefusesMalformedInput(bytes: [UInt8]) {
    #expect(CBOR.decode(bytes) == nil)
}

@Test func cborKeepsAnItemsOwnBytes() throws {
    let statement = CBOR.map([(CBOR.text("alg"), CBOR.int(-7)), (CBOR.text("sig"), CBOR.bytes([9, 9]))])
    let object = WebAuthn.attestationObject(format: "packed", statement: statement, authenticatorData: [1, 2, 3])
    let parsed = try #require(WebAuthn.parseAttestationObject(object))
    #expect(parsed.format == "packed")
    #expect(parsed.statement == statement)
    #expect(parsed.authData == [1, 2, 3])
    #expect(WebAuthn.parseAttestationObject([0xa0]) == nil)
}

@Test func framingSplitsAndReassembles() throws {
    let payload = (0..<300).map { UInt8($0 & 0xff) }
    let packets = CTAPHID.packets(cid: 0x0102_0304, command: CTAPHID.cbor, payload: payload)
    // 57 bytes in the init packet, then 59 per continuation: 57 + 4 × 59 = 293, so 5 continuations.
    #expect(packets.count == 6)
    #expect(packets.allSatisfy { $0.count == 64 })
    #expect(Array(packets[0][0..<7]) == [1, 2, 3, 4, 0x90, 0x01, 0x2c])
    #expect(packets[1][4] == 0 && packets[5][4] == 4)
    var reassembler = CTAPHID.Reassembler(cid: 0x0102_0304)
    // Another channel's packet is ignored.
    #expect(try reassembler.feed(CTAPHID.packets(cid: 9, command: CTAPHID.cbor, payload: [1])[0]) == nil)
    for packet in packets.dropLast() { #expect(try reassembler.feed(packet) == nil) }
    let done = try #require(try reassembler.feed(packets[5]))
    #expect(done.command == CTAPHID.cbor && done.payload == payload)

    let empty = CTAPHID.packets(cid: 7, command: CTAPHID.ping, payload: [])
    #expect(empty.count == 1)
    var small = CTAPHID.Reassembler(cid: 7)
    #expect(try small.feed(empty[0])?.payload == [])

    var skipped = CTAPHID.Reassembler(cid: 0x0102_0304)
    _ = try skipped.feed(packets[0])
    #expect(throws: CTAPHID.FramingError.self) { try skipped.feed(packets[2]) }
}

@Test func aesMatchesNISTVector() {
    // SP 800-38A F.2.5, CBC-AES256.Encrypt, first block.
    let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    let iv = hex("000102030405060708090a0b0c0d0e0f"), plain = hex("6bc1bee22e409f96e93d7e117393172a")
    #expect(PinProtocol.aes256CBC(encrypt: true, key: key, iv: iv, data: plain) == hex("f58c4c04d6e5f1ba779eabfb5f7bfbd6"))
    #expect(PinProtocol.aes256CBC(encrypt: false, key: key, iv: iv, data: hex("f58c4c04d6e5f1ba779eabfb5f7bfbd6")) == plain)
    #expect(PinProtocol.aes256CBC(encrypt: true, key: key, iv: iv, data: [1, 2, 3]) == nil)
}

@Test(arguments: [1, 2])
func pinProtocolsAgreeWithTheKey(version: Int) throws {
    // The key's side, computed independently of PinProtocol.agree.
    let authenticator = P256.KeyAgreement.PrivateKey()
    let raw = [UInt8](authenticator.publicKey.rawRepresentation)
    let cose = try #require(CBOR.decode(CBOR.map([(CBOR.int(1), CBOR.int(2)), (CBOR.int(3), CBOR.int(-25)), (CBOR.int(-1), CBOR.int(1)),
                                                 (CBOR.int(-2), CBOR.bytes(Array(raw[..<32]))), (CBOR.int(-3), CBOR.bytes(Array(raw[32...])))])))
    let (platformCOSE, pin) = try #require(PinProtocol.agree(version: version, authenticatorKey: cose))
    let platform = try #require(CBOR.decode(platformCOSE))
    #expect(platform[1]?.int == 2 && platform[3]?.int == -25 && platform[-1]?.int == 1)
    let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: try #require(platform[-2]?.bytes) + (try #require(platform[-3]?.bytes)))
    let z = try authenticator.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
    let keySide = PinProtocol(version: version, z: z)

    let token = (0..<32).map { UInt8($0) }
    let sent = try #require(keySide.encrypt(token))
    #expect(sent.count == (version == 2 ? 48 : 32))
    #expect(pin.decrypt(sent) == token)
    #expect(keySide.decrypt(try #require(pin.pinHashEnc(Array("1234".utf8)))) == Array(Array(SHA256.hash(data: Data("1234".utf8)))[..<16]))

    if version == 1 {
        // Protocol 1's secret is SHA-256 of the x-coordinate, with a zero IV.
        let secret = Array(SHA256.hash(data: Data(z)))
        #expect(PinProtocol.aes256CBC(encrypt: true, key: secret, iv: [UInt8](repeating: 0, count: 16), data: token) == pin.encrypt(token))
    }
    let hash = [UInt8](repeating: 0xab, count: 32)
    let mac = Array(HMAC<SHA256>.authenticationCode(for: Data(hash), using: SymmetricKey(data: token)))
    #expect(PinProtocol.authenticate(version: version, key: token, hash) == (version == 2 ? mac : Array(mac[..<16])))
}

@Test func pinProtocolRefusesABadKey() {
    #expect(PinProtocol.agree(version: 1, authenticatorKey: .map([(.int(1), .int(2))])) == nil)
}

@Test func getInfoParses() throws {
    let options = CBOR.map([(CBOR.text("rk"), CBOR.bool(true)), (CBOR.text("clientPin"), CBOR.bool(true)), (CBOR.text("up"), CBOR.bool(true))])
    let algorithms = CBOR.array([CBOR.map([(CBOR.text("alg"), CBOR.int(-7)), (CBOR.text("type"), CBOR.text("public-key"))]),
                                 CBOR.map([(CBOR.text("alg"), CBOR.int(-8)), (CBOR.text("type"), CBOR.text("public-key"))])])
    let cbor = CBOR.map([(CBOR.int(1), CBOR.array([CBOR.text("U2F_V2"), CBOR.text("FIDO_2_0"), CBOR.text("FIDO_2_1")])),
                         (CBOR.int(2), CBOR.array([CBOR.text("credProtect")])), (CBOR.int(3), CBOR.bytes([UInt8](repeating: 0xee, count: 16))),
                         (CBOR.int(4), options), (CBOR.int(5), CBOR.int(1200)), (CBOR.int(6), CBOR.array([CBOR.int(2), CBOR.int(1)])),
                         (CBOR.int(7), CBOR.int(8)), (CBOR.int(8), CBOR.int(128)), (CBOR.int(10), algorithms)])
    let info = try #require(CTAP2.parseInfo(cbor))
    #expect(info.versions == ["U2F_V2", "FIDO_2_0", "FIDO_2_1"])
    #expect(info.extensions == ["credProtect"])
    #expect(info.aaguid.count == 16)
    #expect(info.options == ["rk": true, "clientPin": true, "up": true])
    #expect(info.maxMsgSize == 1200 && info.maxCredentialCountInList == 8 && info.maxCredentialIdLength == 128)
    #expect(info.pinUvAuthProtocols == [2, 1])
    #expect(info.algorithms == [-7, -8])
    #expect(CTAP2.parseInfo([0x01]) == nil)
}

@Test func commandsEncode() throws {
    let hash = [UInt8](repeating: 1, count: 32)
    let make = CTAP2.makeCredential(clientDataHash: hash, rpID: "example.com", rpName: "Example", userID: [7], userName: "ann", displayName: "",
                                    algorithm: -7, exclude: [[5, 5]], residentKey: true, uv: false, auth: .init(param: [9], version: 2))
    #expect(make.first == CTAP2.makeCredential)
    let request = try #require(CBOR.decode(Array(make.dropFirst())))
    #expect(request[1]?.bytes == hash)
    #expect(request[2]?["id"]?.text == "example.com" && request[2]?["name"]?.text == "Example")
    #expect(request[3]?["id"]?.bytes == [7] && request[3]?["name"]?.text == "ann" && request[3]?["displayName"] == nil)
    #expect(request[4]?.array?.first?["alg"]?.int == -7)
    #expect(request[5]?.array?.first?["id"]?.bytes == [5, 5])
    #expect(request[7]?["rk"]?.bool == true && request[7]?["uv"] == nil)
    #expect(request[8]?.bytes == [9] && request[9]?.int == 2)

    let probe = CTAP2.getAssertion(rpID: "example.com", clientDataHash: hash, allow: [[1], [2]], up: false, auth: nil)
    let asked = try #require(CBOR.decode(Array(probe.dropFirst())))
    #expect(probe.first == CTAP2.getAssertion)
    #expect(asked[1]?.text == "example.com" && asked[3]?.array?.count == 2 && asked[5]?["up"]?.bool == false && asked[6] == nil)
    let plain = try #require(CBOR.decode(Array(CTAP2.getAssertion(rpID: "a.com", clientDataHash: hash, allow: [], auth: nil).dropFirst())))
    #expect(plain[3] == nil && plain[5] == nil)

    let token = try #require(CBOR.decode(Array(CTAP2.getPinToken(protocol: 2, keyAgreement: CBOR.map([]), pinHashEnc: [3], permissions: 0x02, rpID: "a.com").dropFirst())))
    #expect(token[1]?.int == 2 && token[2]?.int == 9 && token[6]?.bytes == [3] && token[9]?.int == 2 && token[10]?.text == "a.com")
    let legacy = try #require(CBOR.decode(Array(CTAP2.getPinToken(protocol: 1, keyAgreement: CBOR.map([]), pinHashEnc: [3]).dropFirst())))
    #expect(legacy[2]?.int == 5 && legacy[9] == nil)
    #expect(CBOR.decode(Array(CTAP2.getRetries(protocol: 1).dropFirst()))?[2]?.int == 1)
    #expect(CTAP2.parseRetries(CBOR.map([(CBOR.int(3), CBOR.int(8))])) == 8)
    #expect(CTAP2.parsePinToken(CBOR.map([(CBOR.int(2), CBOR.bytes([4, 4]))])) == [4, 4])
}

/// Authenticator data as a key returns it on creation: rpIdHash, flags UP|UV|AT, count, AAGUID, id, COSE key.
private func madeAuthData(id: [UInt8], cose: [UInt8]) -> [UInt8] {
    // Appended in parts: macOS 15's compiler gives up type-checking it as one expression.
    var data = [UInt8](repeating: 0xaa, count: 32)
    data += [0x45, 0, 0, 0, 3]
    data += [UInt8](repeating: 0xcc, count: 16)
    data += [0, UInt8(id.count)]
    return data + id + cose
}

@Test func responsesParse() throws {
    let key = P256.Signing.PrivateKey().publicKey
    let cose = WebAuthn.coseKey(publicKey: key)
    let authData = madeAuthData(id: [1, 2, 3, 4], cose: cose)
    let statement = CBOR.map([(CBOR.text("alg"), CBOR.int(-7)), (CBOR.text("sig"), CBOR.bytes([8]))])
    let made = try #require(CTAP2.parseMadeCredential(CBOR.map([(CBOR.int(1), CBOR.text("packed")), (CBOR.int(2), CBOR.bytes(authData)), (CBOR.int(3), statement)])))
    #expect(made.format == "packed" && made.authData == authData && made.statement == statement)

    let parsed = try #require(WebAuthn.parseAuthenticatorData(authData + CBOR.map([(CBOR.text("credProtect"), CBOR.int(2))])))
    #expect(parsed.flags == 0x45 && parsed.signCount == 3 && parsed.aaguid == [UInt8](repeating: 0xcc, count: 16))
    #expect(parsed.credentialID == [1, 2, 3, 4] && parsed.coseKey == cose)
    let bare = try #require(WebAuthn.parseAuthenticatorData([UInt8](repeating: 0, count: 32) + [0x01, 0, 0, 1, 0]))
    #expect(bare.signCount == 256 && bare.credentialID == nil)
    #expect(WebAuthn.parseAuthenticatorData(Array(authData.prefix(60))) == nil)

    let signed = CBOR.map([(CBOR.int(1), CBOR.map([(CBOR.text("id"), CBOR.bytes([1])), (CBOR.text("type"), CBOR.text("public-key"))])),
                           (CBOR.int(2), CBOR.bytes([2])), (CBOR.int(3), CBOR.bytes([3])), (CBOR.int(4), CBOR.map([(CBOR.text("id"), CBOR.bytes([4]))])),
                           (CBOR.int(5), CBOR.int(2))])
    #expect(CTAP2.parseAssertion(signed, allow: []) == CTAP2.Assertion(credentialID: [1], authData: [2], signature: [3], userID: [4], count: 2))
    let unnamed = CBOR.map([(CBOR.int(2), CBOR.bytes([2])), (CBOR.int(3), CBOR.bytes([3]))])
    #expect(CTAP2.parseAssertion(unnamed, allow: [[9, 9]])?.credentialID == [9, 9])
    #expect(CTAP2.parseAssertion(unnamed, allow: [[9], [8]]) == nil)
}

@Test func coseKeysBecomeSPKI() throws {
    let p256 = P256.Signing.PrivateKey().publicKey
    let es256 = try #require(WebAuthn.publicKeyInfo(cose: WebAuthn.coseKey(publicKey: p256)))
    #expect(es256.algorithm == -7 && es256.spki == [UInt8](p256.derRepresentation))

    let ed = Curve25519.Signing.PrivateKey().publicKey
    let okp = CBOR.map([(CBOR.int(1), CBOR.int(1)), (CBOR.int(3), CBOR.int(-8)), (CBOR.int(-1), CBOR.int(6)), (CBOR.int(-2), CBOR.bytes([UInt8](ed.rawRepresentation)))])
    let eddsa = try #require(WebAuthn.publicKeyInfo(cose: okp))
    #expect(eddsa.algorithm == WebAuthn.eddsa && eddsa.spki?.count == 44 && Array(eddsa.spki!.suffix(32)) == [UInt8](ed.rawRepresentation))

    let rsa = CBOR.map([(CBOR.int(1), CBOR.int(3)), (CBOR.int(3), CBOR.int(-257)), (CBOR.int(-1), CBOR.bytes([1])), (CBOR.int(-2), CBOR.bytes([1, 0, 1]))])
    #expect(WebAuthn.publicKeyInfo(cose: rsa)?.algorithm == -257 && WebAuthn.publicKeyInfo(cose: rsa)?.spki == nil)
    #expect(WebAuthn.publicKeyInfo(cose: [0xa0]) == nil)
}

@Test func statusesMapToDOMErrors() {
    #expect(CTAP2.failure(0x19).name == "InvalidStateError")
    #expect(CTAP2.failure(0x26).name == "NotSupportedError" && CTAP2.failure(0x2B).name == "NotSupportedError")
    #expect(CTAP2.failure(0x28).name == "ConstraintError")
    #expect(CTAP2.failure(0x2E) == ("NotAllowedError", "the security key has no passkey for this site"))
    #expect(CTAP2.failure(0x99).message.contains("0x99"))
    #expect(CTAP2.statusName(0x31) == "PIN_INVALID" && CTAP2.statusName(0x77) == "0x77")
}
