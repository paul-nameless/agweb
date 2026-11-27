import CommonCrypto
import CryptoKit
import Foundation
import Security

// CTAP2 over USB HID, host-free: CBOR decoding, CTAPHID framing, the PIN/UV auth protocols and the commands agweb's
// own security key client sends (SecurityKeyCTAP.swift drives the device).

// MARK: CBOR decoding

/// A decoded CBOR item. Floats, undefined and other simple values are `.other`; tags are dropped for their content.
public indirect enum CBORValue: Equatable, Sendable {
    case int(Int), bytes([UInt8]), text(String), array([CBORValue]), map([(CBORValue, CBORValue)]), bool(Bool), null, other

    public static func == (a: CBORValue, b: CBORValue) -> Bool {
        switch (a, b) {
        case let (.int(x), .int(y)): x == y
        case let (.bytes(x), .bytes(y)): x == y
        case let (.text(x), .text(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.map(x), .map(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.bool(x), .bool(y)): x == y
        case (.null, .null), (.other, .other): true
        default: false
        }
    }

    public subscript(_ key: Int) -> CBORValue? { lookup(.int(key)) }
    public subscript(_ key: String) -> CBORValue? { lookup(.text(key)) }

    private func lookup(_ key: CBORValue) -> CBORValue? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var bytes: [UInt8]? { if case .bytes(let value) = self { value } else { nil } }
    public var int: Int? { if case .int(let value) = self { value } else { nil } }
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [CBORValue]? { if case .array(let value) = self { value } else { nil } }
    public var pairs: [(CBORValue, CBORValue)]? { if case .map(let value) = self { value } else { nil } }
}

/// Reads CBOR items one after another, with each item's byte range, so an item can be copied verbatim (a security
/// key's attStmt). Malformed input, indefinite lengths and nesting deeper than 16 read as nil.
public struct CBORReader {
    public let bytes: [UInt8]
    public private(set) var position: Int
    static let maxDepth = 16

    public init(_ bytes: [UInt8], position: Int = 0) { (self.bytes, self.position) = (bytes, position) }

    public var atEnd: Bool { position >= bytes.count }

    /// The next item and the bytes it spans.
    public mutating func readRaw() -> (value: CBORValue, range: Range<Int>)? {
        let start = position
        guard let value = read(depth: 0) else { return nil }
        return (value, start..<position)
    }

    public mutating func read() -> CBORValue? { read(depth: 0) }

    private mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, count <= bytes.count - position else { return nil }
        defer { position += count }
        return bytes[position..<position + count]
    }

    /// The initial byte's major type and its argument; nil for reserved or indefinite lengths.
    private mutating func head() -> (major: UInt8, info: UInt8, value: UInt64)? {
        guard let first = take(1)?.first else { return nil }
        let major = first >> 5, info = first & 0x1f
        switch info {
        case ..<24: return (major, info, UInt64(info))
        case 24...27:
            guard let raw = take(1 << Int(info - 24)) else { return nil }
            return (major, info, raw.reduce(0) { $0 << 8 | UInt64($1) })
        default: return nil
        }
    }

    private mutating func read(depth: Int) -> CBORValue? {
        guard depth <= Self.maxDepth, let (major, info, value) = head() else { return nil }
        switch major {
        case 0: return value <= UInt64(Int.max) ? .int(Int(value)) : nil
        case 1: return value <= UInt64(Int.max) ? .int(-1 - Int(value)) : nil
        case 2:
            guard value <= UInt64(bytes.count), let raw = take(Int(value)) else { return nil }
            return .bytes(Array(raw))
        case 3:
            guard value <= UInt64(bytes.count), let raw = take(Int(value)), let text = String(validating: raw, as: UTF8.self) else { return nil }
            return .text(text)
        case 4:
            // Each item takes at least a byte: a count beyond what's left is malformed, not an allocation.
            guard value <= UInt64(bytes.count - position) else { return nil }
            var items: [CBORValue] = []
            for _ in 0..<Int(value) {
                guard let item = read(depth: depth + 1) else { return nil }
                items.append(item)
            }
            return .array(items)
        case 5:
            guard value <= UInt64(bytes.count - position) / 2 else { return nil }
            var pairs: [(CBORValue, CBORValue)] = []
            for _ in 0..<Int(value) {
                guard let key = read(depth: depth + 1), let item = read(depth: depth + 1) else { return nil }
                pairs.append((key, item))
            }
            return .map(pairs)
        case 6: return read(depth: depth + 1)
        default:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: return .other // undefined, simple values, floats (their bytes were taken by head)
            }
        }
    }
}

extension CBOR {
    /// One item filling all of `bytes`; nil when malformed or followed by more.
    public static func decode(_ bytes: [UInt8]) -> CBORValue? {
        var reader = CBORReader(bytes)
        guard let value = reader.read(), reader.atEnd else { return nil }
        return value
    }

    /// A map's entries with each value's own bytes, for copying one verbatim.
    public static func mapEntries(_ bytes: [UInt8]) -> [(key: CBORValue, value: CBORValue, raw: [UInt8])]? {
        guard let first = bytes.first, first >> 5 == 5 else { return nil }
        guard case .map(let pairs)? = decode(bytes) else { return nil }
        // Decoded once to validate, then walked for the ranges.
        var reader = CBORReader(bytes)
        var entries: [(key: CBORValue, value: CBORValue, raw: [UInt8])] = []
        guard skipHead(&reader) else { return nil }
        for _ in pairs {
            guard let key = reader.read(), let (value, range) = reader.readRaw() else { return nil }
            entries.append((key, value, Array(bytes[range])))
        }
        return entries
    }

    /// Moves past a map's initial byte and count.
    private static func skipHead(_ reader: inout CBORReader) -> Bool {
        let first = reader.bytes[reader.position]
        let info = first & 0x1f
        let extra = info < 24 ? 0 : info <= 27 ? 1 << Int(info - 24) : -1
        guard extra >= 0, reader.bytes.count >= 1 + extra else { return false }
        reader = CBORReader(reader.bytes, position: 1 + extra)
        return true
    }

    public static func bool(_ value: Bool) -> [UInt8] { [value ? 0xf5 : 0xf4] }
    public static func array(_ items: [[UInt8]]) -> [UInt8] { head(4, UInt64(items.count)) + items.flatMap { $0 } }
}

// MARK: WebAuthn structures from a key

extension WebAuthn {
    public static let eddsa = -8

    /// An attestation object's format, its attStmt as the key encoded it, and its authenticator data.
    public static func parseAttestationObject(_ bytes: [UInt8]) -> (format: String, statement: [UInt8], authData: [UInt8])? {
        guard let entries = CBOR.mapEntries(bytes) else { return nil }
        func entry(_ name: String) -> (value: CBORValue, raw: [UInt8])? {
            entries.first { $0.key == .text(name) }.map { ($0.value, $0.raw) }
        }
        guard let format = entry("fmt")?.value.text, let statement = entry("attStmt"), case .map = statement.value,
              let authData = entry("authData")?.value.bytes else { return nil }
        return (format, statement.raw, authData)
    }

    public struct AuthenticatorData: Sendable, Equatable {
        public let flags: UInt8
        public let signCount: UInt32
        public let aaguid: [UInt8]?
        public let credentialID: [UInt8]?
        public let coseKey: [UInt8]?
    }

    /// rpIdHash, flags, sign count and, when the AT flag is set, the attested credential data.
    public static func parseAuthenticatorData(_ bytes: [UInt8]) -> AuthenticatorData? {
        guard bytes.count >= 37 else { return nil }
        let flags = bytes[32]
        let count = bytes[33..<37].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard flags & 0x40 != 0 else { return AuthenticatorData(flags: flags, signCount: count, aaguid: nil, credentialID: nil, coseKey: nil) }
        guard bytes.count >= 55 else { return nil }
        let aaguid = Array(bytes[37..<53])
        let length = Int(bytes[53]) << 8 | Int(bytes[54])
        guard bytes.count >= 55 + length else { return nil }
        let id = Array(bytes[55..<55 + length])
        var reader = CBORReader(bytes, position: 55 + length)
        guard let (key, range) = reader.readRaw(), case .map = key else { return nil }
        return AuthenticatorData(flags: flags, signCount: count, aaguid: aaguid, credentialID: id, coseKey: Array(bytes[range]))
    }

    /// A COSE public key's algorithm, and what getPublicKey() returns for it: SubjectPublicKeyInfo DER for ES256 and
    /// Ed25519, nil for any other algorithm (as the spec allows).
    public static func publicKeyInfo(cose: [UInt8]) -> (algorithm: Int, spki: [UInt8]?)? {
        guard let key = CBOR.decode(cose), let algorithm = key[3]?.int else { return nil }
        switch (key[1]?.int, key[-1]?.int, key[-2]?.bytes, key[-3]?.bytes) {
        case (2, 1, let x?, let y?) where algorithm == es256 && x.count == 32 && y.count == 32:
            return (algorithm, (try? P256.Signing.PublicKey(rawRepresentation: x + y)).map { [UInt8]($0.derRepresentation) })
        case (1, 6, let x?, _) where algorithm == eddsa && x.count == 32:
            return (algorithm, [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00] + x)
        default:
            return (algorithm, nil)
        }
    }
}

// MARK: CTAPHID framing

public enum CTAPHID {
    public static let ping: UInt8 = 0x01, msg: UInt8 = 0x03, initialize: UInt8 = 0x06, cbor: UInt8 = 0x10, cancel: UInt8 = 0x11
    public static let keepalive: UInt8 = 0x3B, error: UInt8 = 0x3F
    public static let broadcast: UInt32 = 0xffff_ffff
    /// INIT's capability flags.
    public static let capabilityWink: UInt8 = 0x01, capabilityCBOR: UInt8 = 0x04, capabilityNoMSG: UInt8 = 0x08
    /// KEEPALIVE's status byte.
    public static let processing: UInt8 = 1, userPresenceNeeded: UInt8 = 2

    static func channel(_ cid: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: cid >> ($0 * 8)) } }

    /// The most one message can carry: an init packet and 128 continuation packets (sequence numbers 0 to 127).
    public static func maxPayload(reportSize: Int = 64) -> Int { reportSize - 7 + 128 * (reportSize - 5) }

    /// `payload` split into one init packet and continuation packets, each zero-padded to `reportSize`. Callers keep
    /// `payload` within `maxPayload`; past it the sequence numbers would be wrong, never a crash.
    public static func packets(cid: UInt32, command: UInt8, payload: [UInt8], reportSize: Int = 64) -> [[UInt8]] {
        let channel = channel(cid)
        func padded(_ packet: [UInt8]) -> [UInt8] { packet + [UInt8](repeating: 0, count: reportSize - packet.count) }
        let first = min(payload.count, reportSize - 7)
        var out = [padded(channel + [command | 0x80, UInt8(payload.count >> 8 & 0xff), UInt8(payload.count & 0xff)] + payload[..<first])]
        var offset = first, sequence: UInt8 = 0
        while offset < payload.count {
            let end = min(payload.count, offset + reportSize - 5)
            out.append(padded(channel + [sequence] + payload[offset..<end]))
            offset = end
            sequence &+= 1
        }
        return out
    }

    public struct FramingError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Puts a response back together from its packets; another channel's packets are ignored.
    public struct Reassembler {
        public let cid: UInt32
        private var command: UInt8?
        private var total = 0
        private var payload: [UInt8] = []
        private var sequence: UInt8 = 0

        public init(cid: UInt32) { self.cid = cid }

        /// The message once its last packet arrives, its command without the high bit.
        public mutating func feed(_ packet: [UInt8]) throws -> (command: UInt8, payload: [UInt8])? {
            guard packet.count >= 7, Array(packet[0..<4]) == CTAPHID.channel(cid) else { return nil }
            if packet[4] & 0x80 != 0 {
                command = packet[4] & 0x7f
                total = Int(packet[5]) << 8 | Int(packet[6])
                payload = Array(packet[7..<min(packet.count, 7 + total)])
                sequence = 0
            } else {
                guard command != nil else { throw FramingError(description: "a continuation packet with no message started") }
                guard packet[4] == sequence else { throw FramingError(description: "continuation packet \(packet[4]) where \(sequence) was due") }
                sequence += 1
                payload += packet[5..<min(packet.count, 5 + total - payload.count)]
            }
            guard let done = command, payload.count >= total else { return nil }
            command = nil
            return (done, payload)
        }
    }
}

// MARK: PIN/UV auth protocols

/// PIN/UV auth protocol 1 or 2 (CTAP 2.1 §6.5): the secret shared with the key, and what's done with it.
public struct PinProtocol: Sendable {
    public let version: Int
    /// Protocol 1: SHA-256 of the ECDH x-coordinate. Protocol 2: its HMAC key then its AES key.
    let secret: [UInt8]

    /// The shared secret from the ECDH x-coordinate `z`.
    public init(version: Int, z: [UInt8]) {
        self.version = version
        if version == 2 {
            let ikm = SymmetricKey(data: z), salt = Data(repeating: 0, count: 32)
            func derive(_ info: String) -> [UInt8] {
                HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Array($0) }
            }
            secret = derive("CTAP2 HMAC key") + derive("CTAP2 AES key")
        } else {
            secret = Array(SHA256.hash(data: Data(z)))
        }
    }

    /// Key agreement with the key's COSE key (from getKeyAgreement): the platform's COSE key to send, and the protocol.
    public static func agree(version: Int, authenticatorKey: CBORValue,
                             platformKey: P256.KeyAgreement.PrivateKey = .init()) -> (platformCOSE: [UInt8], pin: PinProtocol)? {
        guard authenticatorKey[1]?.int == 2, authenticatorKey[-1]?.int == 1, let x = authenticatorKey[-2]?.bytes, let y = authenticatorKey[-3]?.bytes,
              x.count == 32, y.count == 32, let peer = try? P256.KeyAgreement.PublicKey(rawRepresentation: x + y),
              let shared = try? platformKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let z = shared.withUnsafeBytes { Array($0) }
        let raw = [UInt8](platformKey.publicKey.rawRepresentation)
        let cose = CBOR.map([(CBOR.int(1), CBOR.int(2)), (CBOR.int(3), CBOR.int(-25)), (CBOR.int(-1), CBOR.int(1)),
                             (CBOR.int(-2), CBOR.bytes(Array(raw[..<32]))), (CBOR.int(-3), CBOR.bytes(Array(raw[32...])))])
        return (cose, PinProtocol(version: version, z: z))
    }

    private var aesKey: [UInt8] { version == 2 ? Array(secret[32...]) : secret }

    public func encrypt(_ plain: [UInt8]) -> [UInt8]? {
        guard version == 2 else { return Self.aes256CBC(encrypt: true, key: aesKey, iv: [UInt8](repeating: 0, count: 16), data: plain) }
        var iv = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &iv) == errSecSuccess else { return nil }
        return Self.aes256CBC(encrypt: true, key: aesKey, iv: iv, data: plain).map { iv + $0 }
    }

    public func decrypt(_ cipher: [UInt8]) -> [UInt8]? {
        guard version == 2 else { return Self.aes256CBC(encrypt: false, key: aesKey, iv: [UInt8](repeating: 0, count: 16), data: cipher) }
        guard cipher.count >= 16 else { return nil }
        return Self.aes256CBC(encrypt: false, key: aesKey, iv: Array(cipher[..<16]), data: Array(cipher[16...]))
    }

    /// pinUvAuthParam over `message` with `key` (a PIN token): 16 bytes of HMAC-SHA-256 for protocol 1, all 32 for 2.
    public static func authenticate(version: Int, key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        let mac = Array(HMAC<SHA256>.authenticationCode(for: Data(message), using: SymmetricKey(data: key)))
        return version == 2 ? mac : Array(mac[..<16])
    }

    /// pinHashEnc: the first 16 bytes of SHA-256 of the PIN, encrypted.
    public func pinHashEnc(_ pin: [UInt8]) -> [UInt8]? {
        var hash = Array(Array(SHA256.hash(data: Data(pin)))[..<16])
        defer { hash.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return encrypt(hash)
    }

    /// AES-256-CBC with no padding; nil unless the data is whole blocks.
    public static func aes256CBC(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard key.count == 32, iv.count == 16, data.count % 16 == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv,
                             data, data.count, &out, out.count, &moved)
        return status == kCCSuccess && moved == data.count ? out : nil
    }
}

// MARK: CTAP2 commands

public enum CTAP2 {
    public static let makeCredential: UInt8 = 0x01, getAssertion: UInt8 = 0x02, getInfo: UInt8 = 0x04, clientPIN: UInt8 = 0x06
    /// pinUvAuthToken permissions.
    public static let permissionMakeCredential: UInt8 = 0x01, permissionGetAssertion: UInt8 = 0x02

    public struct Info: Sendable, Equatable {
        public var versions: [String] = [], extensions: [String] = [], aaguid: [UInt8] = []
        public var options: [String: Bool] = [:]
        public var maxMsgSize: Int?, maxCredentialCountInList: Int?, maxCredentialIdLength: Int?
        public var pinUvAuthProtocols: [Int] = []
        public var algorithms: [Int] = []
        public init() {}
    }

    public static func parseInfo(_ cbor: [UInt8]) -> Info? {
        guard let map = CBOR.decode(cbor), map.pairs != nil else { return nil }
        var info = Info()
        info.versions = map[1]?.array?.compactMap(\.text) ?? []
        info.extensions = map[2]?.array?.compactMap(\.text) ?? []
        info.aaguid = map[3]?.bytes ?? []
        for (key, value) in map[4]?.pairs ?? [] { if let key = key.text, let value = value.bool { info.options[key] = value } }
        info.maxMsgSize = map[5]?.int
        info.pinUvAuthProtocols = map[6]?.array?.compactMap(\.int) ?? []
        info.maxCredentialCountInList = map[7]?.int
        info.maxCredentialIdLength = map[8]?.int
        info.algorithms = map[10]?.array?.compactMap { $0["alg"]?.int } ?? []
        return info
    }

    private static func command(_ code: UInt8, _ pairs: [([UInt8], [UInt8])]) -> [UInt8] { [code] + CBOR.map(pairs) }

    public static func getRetries(protocol version: Int) -> [UInt8] {
        command(clientPIN, [(CBOR.int(1), CBOR.int(version)), (CBOR.int(2), CBOR.int(1))])
    }

    public static func getKeyAgreement(protocol version: Int) -> [UInt8] {
        command(clientPIN, [(CBOR.int(1), CBOR.int(version)), (CBOR.int(2), CBOR.int(2))])
    }

    /// getPinToken (0x05), or with `permissions` getPinUvAuthTokenUsingPinWithPermissions (0x09).
    public static func getPinToken(protocol version: Int, keyAgreement: [UInt8], pinHashEnc: [UInt8], permissions: UInt8? = nil, rpID: String? = nil) -> [UInt8] {
        var pairs = [(CBOR.int(1), CBOR.int(version)), (CBOR.int(2), CBOR.int(permissions == nil ? 5 : 9)),
                     (CBOR.int(3), keyAgreement), (CBOR.int(6), CBOR.bytes(pinHashEnc))]
        if let permissions {
            pairs.append((CBOR.int(9), CBOR.int(Int(permissions))))
            if let rpID { pairs.append((CBOR.int(0x0A), CBOR.text(rpID))) }
        }
        return command(clientPIN, pairs)
    }

    public static func parseRetries(_ cbor: [UInt8]) -> Int? { CBOR.decode(cbor)?[3]?.int }
    public static func parseKeyAgreement(_ cbor: [UInt8]) -> CBORValue? { CBOR.decode(cbor)?[1] }
    public static func parsePinToken(_ cbor: [UInt8]) -> [UInt8]? { CBOR.decode(cbor)?[2]?.bytes }

    private static func descriptors(_ ids: [[UInt8]]) -> [UInt8] {
        CBOR.array(ids.map { CBOR.map([(CBOR.text("id"), CBOR.bytes($0)), (CBOR.text("type"), CBOR.text("public-key"))]) })
    }

    private static func options(_ pairs: [(String, Bool)]) -> [UInt8] { CBOR.map(pairs.map { (CBOR.text($0.0), CBOR.bool($0.1)) }) }

    public struct Auth: Sendable {
        public let param: [UInt8], version: Int
        public init(param: [UInt8], version: Int) { (self.param, self.version) = (param, version) }
    }

    public static func makeCredential(clientDataHash: [UInt8], rpID: String, rpName: String, userID: [UInt8], userName: String, displayName: String,
                                      algorithm: Int, exclude: [[UInt8]], residentKey: Bool, uv: Bool, auth: Auth?) -> [UInt8] {
        var rp = [(CBOR.text("id"), CBOR.text(rpID))]
        if !rpName.isEmpty { rp.append((CBOR.text("name"), CBOR.text(rpName))) }
        var user = [(CBOR.text("id"), CBOR.bytes(userID))]
        if !userName.isEmpty { user.append((CBOR.text("name"), CBOR.text(userName))) }
        if !displayName.isEmpty { user.append((CBOR.text("displayName"), CBOR.text(displayName))) }
        var pairs = [(CBOR.int(1), CBOR.bytes(clientDataHash)), (CBOR.int(2), CBOR.map(rp)), (CBOR.int(3), CBOR.map(user)),
                     (CBOR.int(4), CBOR.array([CBOR.map([(CBOR.text("alg"), CBOR.int(algorithm)), (CBOR.text("type"), CBOR.text("public-key"))])]))]
        if !exclude.isEmpty { pairs.append((CBOR.int(5), descriptors(exclude))) }
        let chosen = (residentKey ? [("rk", true)] : []) + (uv ? [("uv", true)] : [])
        if !chosen.isEmpty { pairs.append((CBOR.int(7), options(chosen))) }
        if let auth { pairs += [(CBOR.int(8), CBOR.bytes(auth.param)), (CBOR.int(9), CBOR.int(auth.version))] }
        return command(makeCredential, pairs)
    }

    public struct Made: Sendable, Equatable {
        public let format: String, authData: [UInt8]
        /// attStmt as the key encoded it.
        public let statement: [UInt8]
    }

    public static func parseMadeCredential(_ cbor: [UInt8]) -> Made? {
        guard let entries = CBOR.mapEntries(cbor) else { return nil }
        let byKey = { (key: Int) in entries.first { $0.key == .int(key) } }
        guard let format = byKey(1)?.value.text, let authData = byKey(2)?.value.bytes, let statement = byKey(3), case .map = statement.value else { return nil }
        return Made(format: format, authData: authData, statement: statement.raw)
    }

    /// `up`: false for a silent probe (no touch), which tells whether the key holds one of `allow` for `rpID`.
    public static func getAssertion(rpID: String, clientDataHash: [UInt8], allow: [[UInt8]], up: Bool = true, uv: Bool = false, auth: Auth?) -> [UInt8] {
        var pairs = [(CBOR.int(1), CBOR.text(rpID)), (CBOR.int(2), CBOR.bytes(clientDataHash))]
        if !allow.isEmpty { pairs.append((CBOR.int(3), descriptors(allow))) }
        let chosen = (up ? [] : [("up", false)]) + (uv ? [("uv", true)] : [])
        if !chosen.isEmpty { pairs.append((CBOR.int(5), options(chosen))) }
        if let auth { pairs += [(CBOR.int(6), CBOR.bytes(auth.param)), (CBOR.int(7), CBOR.int(auth.version))] }
        return command(getAssertion, pairs)
    }

    public struct Assertion: Sendable, Equatable {
        public let credentialID: [UInt8], authData: [UInt8], signature: [UInt8]
        public let userID: [UInt8]?
        /// How many accounts for the site the key holds (discoverable sign-in); nil when it didn't say.
        public let count: Int?

        public init(credentialID: [UInt8], authData: [UInt8], signature: [UInt8], userID: [UInt8]?, count: Int?) {
            (self.credentialID, self.authData, self.signature, self.userID, self.count) = (credentialID, authData, signature, userID, count)
        }
    }

    /// The key may leave out the credential when the allow list had exactly one; it's that one.
    public static func parseAssertion(_ cbor: [UInt8], allow: [[UInt8]]) -> Assertion? {
        guard let map = CBOR.decode(cbor), let authData = map[2]?.bytes, let signature = map[3]?.bytes else { return nil }
        guard let id = map[1]?["id"]?.bytes ?? (allow.count == 1 ? allow[0] : nil) else { return nil }
        return Assertion(credentialID: id, authData: authData, signature: signature, userID: map[4]?["id"]?.bytes, count: map[5]?.int)
    }

    // MARK: Status codes

    public static let ok: UInt8 = 0x00, credentialExcluded: UInt8 = 0x19, noCredentials: UInt8 = 0x2E, keepaliveCancel: UInt8 = 0x2D
    public static let pinInvalid: UInt8 = 0x31, pinBlocked: UInt8 = 0x32, pinAuthInvalid: UInt8 = 0x33, pinAuthBlocked: UInt8 = 0x34
    public static let pinNotSet: UInt8 = 0x35, pinRequired: UInt8 = 0x36
    /// The key stopped waiting for a touch, which can be sooner than the site's timeout.
    public static let touchTimeouts: Set<UInt8> = [0x2F, 0x3A]

    private static let statuses: [UInt8: (name: String, message: String)] = [
        0x00: ("OK", "no error"),
        0x01: ("INVALID_COMMAND", "the security key doesn't know this command"),
        0x02: ("INVALID_PARAMETER", "the security key refused a parameter of agweb's request"),
        0x03: ("INVALID_LENGTH", "the security key refused the length of agweb's request"),
        0x05: ("TIMEOUT", "the security key timed out"),
        0x0B: ("INVALID_CHANNEL", "the security key refused agweb's channel"),
        0x11: ("CBOR_UNEXPECTED_TYPE", "the security key couldn't read agweb's request"),
        0x12: ("INVALID_CBOR", "the security key couldn't read agweb's request"),
        0x14: ("MISSING_PARAMETER", "the security key missed a parameter in agweb's request"),
        0x15: ("LIMIT_EXCEEDED", "the request was more than the security key takes"),
        0x19: ("CREDENTIAL_EXCLUDED", "the security key already holds a passkey for this account"),
        0x26: ("UNSUPPORTED_ALGORITHM", "the security key doesn't support the algorithms the site asked for"),
        0x27: ("OPERATION_DENIED", "the security key refused"),
        0x28: ("KEY_STORE_FULL", "the security key is full; delete a passkey on it (ykman fido credentials delete)"),
        0x2B: ("UNSUPPORTED_OPTION", "the security key doesn't support what the site asked for"),
        0x2D: ("KEEPALIVE_CANCEL", "the security key request was cancelled"),
        0x2E: ("NO_CREDENTIALS", "the security key has no passkey for this site"),
        0x2F: ("USER_ACTION_TIMEOUT", "nobody touched the security key in time"),
        0x3A: ("ACTION_TIMEOUT", "nobody touched the security key in time"),
        0x31: ("PIN_INVALID", "wrong PIN"),
        0x32: ("PIN_BLOCKED", "the security key's PIN is blocked; only resetting the key unblocks it"),
        0x33: ("PIN_AUTH_INVALID", "the security key refused agweb's PIN token"),
        0x34: ("PIN_AUTH_BLOCKED", "too many wrong PINs; unplug the security key and plug it in again"),
        0x35: ("PIN_NOT_SET", "the site needs user verification and the security key has no PIN; set one (ykman fido access change-pin)"),
        0x36: ("PUAT_REQUIRED", "the security key needs its PIN"),
        0x37: ("PIN_POLICY_VIOLATION", "the PIN doesn't meet the security key's rules"),
        0x39: ("REQUEST_TOO_LARGE", "the request is too large for the security key"),
        0x3C: ("UV_BLOCKED", "the security key's built-in verification is blocked; use its PIN"),
        0x3F: ("UV_INVALID", "the security key's built-in verification failed"),
    ]

    public static func statusName(_ code: UInt8) -> String { statuses[code]?.name ?? String(format: "0x%02X", code) }

    /// The DOMException name and message the page gets for a failed command.
    public static func failure(_ code: UInt8) -> (name: String, message: String) {
        let message = statuses[code]?.message ?? String(format: "the security key failed (CTAP status 0x%02X)", code)
        let name = switch code {
        case credentialExcluded: "InvalidStateError"
        case 0x26, 0x2B: "NotSupportedError"
        case 0x28: "ConstraintError"
        default: "NotAllowedError"
        }
        return (name, message)
    }
}
