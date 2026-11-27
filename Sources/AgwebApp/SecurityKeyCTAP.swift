import AgwebCore
import Foundation
import IOKit.hid

/// Agweb's own security key client: CTAP2 over USB HID (CTAP.swift has the bytes). Each ceremony runs on a thread of
/// its own, since every call to the key blocks until it answers or the person touches it.
@MainActor
final class CTAPSecurityKey: SecurityKeyBackend {
    private var session: CTAPSession?

    func create(_ request: KeyCreate, _ ui: KeyUI) async throws -> KeyMade {
        try await run(ui, timeout: request.timeout, what: "create for \(request.rpID)") { try $0.create(request) }
    }

    func get(_ request: KeyGet, _ ui: KeyUI) async throws -> KeySigned {
        try await run(ui, timeout: request.timeout, what: "get for \(request.rpID)") { try $0.get(request) }
    }

    func cancel() { session?.cancel() }

    private func run<T: Sendable>(_ ui: KeyUI, timeout: TimeInterval, what: String, _ body: @escaping @Sendable (CTAPSession) throws -> T) async throws -> T {
        guard session == nil else { throw KeyError("NotAllowedError", "the security key is busy with another request") }
        let session = CTAPSession(ui: KeyUIBridge(ui), deadline: Date().addingTimeInterval(timeout))
        self.session = session
        defer { self.session = nil }
        KeyLog.write("ctap: \(what), timeout \(Int(timeout)) s")
        let started = Date()
        do {
            let value = try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
                let thread = Thread {
                    let result = Result { try body(session) }
                    session.finish()
                    done.resume(with: result)
                }
                thread.name = "agweb security key"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            KeyLog.write("ctap: \(what) done in \(Self.ms(since: started)) ms")
            return value
        } catch let error as KeyError {
            KeyLog.write("ctap: \(what) failed after \(Self.ms(since: started)) ms: \(error.name): \(error.message)")
            throw error
        } catch {
            KeyLog.write("ctap: \(what) failed after \(Self.ms(since: started)) ms: \(error)")
            throw KeyError("NotAllowedError", "the security key failed: \(error)")
        }
    }

    nonisolated static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

/// The ceremony's bar, reached from the key's thread.
private final class KeyUIBridge: @unchecked Sendable {
    private let ui: KeyUI

    init(_ ui: KeyUI) { self.ui = ui }

    func show(_ step: KeyStep) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ui.show(step) } }
    }

    /// Blocks the key's thread until the person answers in the bar; nil when they cancel or `stop` says to give up.
    func pin(retries: Int?, wrong: Bool, stop: () -> Bool) -> String? {
        let answered = DispatchSemaphore(value: 0)
        let box = PinBox()
        Task { @MainActor in
            box.set(await self.ui.pin(retries: retries, wrong: wrong))
            answered.signal()
        }
        while answered.wait(timeout: .now() + 0.2) == .timedOut { if stop() { return nil } }
        return box.take()
    }
}

private final class PinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String?) { lock.withLock { self.value = value } }
    func take() -> String? { lock.withLock { defer { value = nil }; return value } }
}

/// One ceremony on the key's thread. `cancel` comes from the main actor.
private final class CTAPSession: @unchecked Sendable {
    let ui: KeyUIBridge
    let deadline: Date
    private let lock = NSLock()
    private var cancelled = false
    private var key: HIDKey?
    private var cid = CTAPHID.broadcast
    /// The key's maxMsgSize from getInfo; CTAP's default until then.
    private var maxMessage = 1024

    init(ui: KeyUIBridge, deadline: Date) { (self.ui, self.deadline) = (ui, deadline) }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let key = lock.withLock { cancelled = true; return self.key }
        KeyLog.write("ctap: cancel requested")
        key?.sendCancel()
    }

    /// On the key's thread, which the device is scheduled on.
    func finish() {
        let key = lock.withLock { defer { self.key = nil }; return self.key }
        key?.close()
    }

    private func stop() -> Bool { isCancelled || Date() >= deadline }

    private static func failure(_ status: UInt8) -> KeyError {
        let (name, message) = CTAP2.failure(status)
        return KeyError(name, message)
    }

    private static let garbled = KeyError("NotAllowedError", "the security key's reply couldn't be read")

    // MARK: Transport

    private func transact(_ key: HIDKey, cid: UInt32, command: UInt8, payload: [UInt8], keepalive: ((UInt8) -> Void)? = nil) throws -> [UInt8] {
        // The page decides how many credential ids, and how long, a request carries.
        guard payload.count <= min(maxMessage, CTAPHID.maxPayload(reportSize: key.outputSize)) else {
            KeyLog.write("ctap: a \(payload.count)-byte request is over the key's \(maxMessage)-byte limit; not sent")
            throw KeyError("NotAllowedError", "the site's request is too large for the security key")
        }
        for packet in CTAPHID.packets(cid: cid, command: command, payload: payload, reportSize: key.outputSize) { try key.write(packet) }
        var reassembler = CTAPHID.Reassembler(cid: cid)
        while true {
            guard let packet = key.next(until: deadline, stop: { isCancelled }) else {
                if isCancelled { throw KeyError.cancelled }
                key.sendCancel()
                KeyLog.write("ctap: timed out waiting for the key")
                throw KeyError("NotAllowedError", "nobody touched the security key in time")
            }
            let message: (command: UInt8, payload: [UInt8])?
            do { message = try reassembler.feed(packet) } catch {
                KeyLog.write("ctap: framing error: \(error)")
                throw Self.garbled
            }
            guard let message else { continue }
            switch message.command {
            case CTAPHID.keepalive: keepalive?(message.payload.first ?? 0)
            case CTAPHID.error: throw Self.hidError(message.payload.first ?? 0x7F)
            case command: return message.payload
            default: KeyLog.write(String(format: "ctap: ignored a reply for command 0x%02X", message.command))
            }
        }
    }

    private static func hidError(_ code: UInt8) -> KeyError {
        let names: [UInt8: String] = [0x01: "INVALID_CMD", 0x02: "INVALID_PAR", 0x03: "INVALID_LEN", 0x04: "INVALID_SEQ", 0x05: "MSG_TIMEOUT",
                                      0x06: "CHANNEL_BUSY", 0x0A: "LOCK_REQUIRED", 0x0B: "INVALID_CHANNEL", 0x7F: "OTHER"]
        KeyLog.write("ctap: CTAPHID error \(names[code] ?? String(format: "0x%02X", code))")
        return code == 0x06 ? KeyError("NotAllowedError", "the security key is busy with another app; try again")
            : KeyError("NotAllowedError", String(format: "the security key failed (CTAPHID error 0x%02X)", code))
    }

    /// CTAPHID_INIT on the broadcast channel: the channel for this ceremony and the key's capabilities.
    private func initialize(_ key: HIDKey) throws -> (cid: UInt32, capabilities: UInt8) {
        var nonce = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else { throw KeyError("NotAllowedError", "no random bytes for the security key") }
        let reply = try transact(key, cid: CTAPHID.broadcast, command: CTAPHID.initialize, payload: nonce)
        guard reply.count >= 17, Array(reply[0..<8]) == nonce else {
            KeyLog.write("ctap: INIT reply of \(reply.count) bytes didn't match the nonce")
            throw Self.garbled
        }
        let cid = reply[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let capabilities = reply[16]
        KeyLog.write(String(format: "ctap: INIT channel %08X, CTAPHID version %d, device version %d.%d.%d, capabilities 0x%02X (wink %@, cbor %@, nmsg %@)",
                            cid, reply[12], reply[13], reply[14], reply[15], capabilities,
                            capabilities & CTAPHID.capabilityWink != 0 ? "yes" : "no", capabilities & CTAPHID.capabilityCBOR != 0 ? "yes" : "no",
                            capabilities & CTAPHID.capabilityNoMSG != 0 ? "yes" : "no"))
        return (cid, capabilities)
    }

    /// One CTAP2 command: its status byte and CBOR body. `touch`: the key will want one, so the bar asks for it.
    private func cbor(_ key: HIDKey, _ name: String, _ request: [UInt8], touch: Bool = false) throws -> (status: UInt8, body: [UInt8]) {
        KeyLog.write("ctap: → \(name) (\(request.count) bytes)")
        if touch { ui.show(.touch) }
        let started = Date()
        var last: UInt8 = 0
        let reply = try transact(key, cid: cid, command: CTAPHID.cbor, payload: request) { [ui] status in
            guard status != last else { return }
            last = status
            KeyLog.write("ctap: keepalive \(status == CTAPHID.userPresenceNeeded ? "UPNEEDED" : status == CTAPHID.processing ? "PROCESSING" : "\(status)")")
            if status == CTAPHID.userPresenceNeeded { ui.show(.touch) }
        }
        guard let status = reply.first else { throw Self.garbled }
        KeyLog.write("ctap: ← \(name) \(CTAP2.statusName(status)) (\(reply.count - 1) bytes, \(CTAPSecurityKey.ms(since: started)) ms)")
        return (status, Array(reply.dropFirst()))
    }

    /// The first FIDO key plugged in, opened, with what it says about itself; asks the person to plug one in when there's none.
    private func connect() throws -> (HIDKey, CTAP2.Info) {
        var asked = false
        while true {
            if isCancelled { throw KeyError.cancelled }
            let devices = HIDKey.plugged()
            if let device = devices.first {
                KeyLog.write("ctap: \(devices.count) FIDO device(s); using \(HIDKey.describe(device))")
                let key = try HIDKey(device)
                let cancelledMeanwhile = lock.withLock { self.key = key; return cancelled }
                if cancelledMeanwhile { throw KeyError.cancelled }
                let (cid, capabilities) = try initialize(key)
                lock.withLock { self.cid = cid }
                key.setChannel(cid)
                guard capabilities & CTAPHID.capabilityCBOR != 0 else {
                    throw KeyError("NotSupportedError", "this security key only speaks U2F (CTAP1), which agweb's own client doesn't yet")
                }
                let (status, body) = try cbor(key, "getInfo", [CTAP2.getInfo])
                guard status == CTAP2.ok else { throw Self.failure(status) }
                guard let info = CTAP2.parseInfo(body) else { throw Self.garbled }
                if let size = info.maxMsgSize, size >= 64 { maxMessage = size }
                KeyLog.write("ctap: getInfo versions \(info.versions), aaguid \(KeyLog.hex(info.aaguid)), options \(info.options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")), "
                             + "pinUvAuthProtocols \(info.pinUvAuthProtocols), extensions \(info.extensions), algorithms \(info.algorithms), maxMsgSize \(info.maxMsgSize.map(String.init) ?? "-"), "
                             + "maxCredentialCountInList \(info.maxCredentialCountInList.map(String.init) ?? "-"), maxCredentialIdLength \(info.maxCredentialIdLength.map(String.init) ?? "-")")
                return (key, info)
            }
            if !asked {
                asked = true
                KeyLog.write("ctap: no FIDO device plugged in; waiting")
                ui.show(.insert)
            }
            if Date() >= deadline { throw KeyError("NotAllowedError", "no security key was plugged in in time") }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: User verification

    /// Whether to verify with the PIN or the key's built-in sensor, from the site's wish and what the key has.
    private func verification(_ info: CTAP2.Info, _ wish: String) throws -> (pin: Bool, builtIn: Bool) {
        let hasPIN = info.options["clientPin"] == true, hasUV = info.options["uv"] == true
        if wish == "required" && !hasPIN && !hasUV {
            throw KeyError("NotAllowedError", "the site needs a PIN on the security key, and it has none; set one with ykman fido access change-pin")
        }
        let wanted = wish == "required" || (wish == "preferred" && (hasPIN || hasUV))
        KeyLog.write("ctap: user verification \(wish): \(wanted ? (hasPIN ? "PIN" : "built-in") : "none") (clientPin \(info.options["clientPin"].map(String.init) ?? "-"), uv \(info.options["uv"].map(String.init) ?? "-"))")
        return (wanted && hasPIN, wanted && !hasPIN && hasUV)
    }

    /// The PIN from the person, traded for a PIN token, and the pinUvAuthParam over `clientDataHash`. A wrong PIN asks again.
    private func pinAuth(_ key: HIDKey, _ info: CTAP2.Info, permissions: UInt8, rpID: String, clientDataHash: [UInt8]) throws -> CTAP2.Auth {
        let version = info.pinUvAuthProtocols.contains(2) ? 2 : 1
        let withPermissions = info.options["pinUvAuthToken"] == true
        KeyLog.write("ctap: PIN with protocol \(version), \(withPermissions ? "getPinUvAuthTokenUsingPinWithPermissions" : "getPinToken")")
        var wrong = false
        while true {
            let (retryStatus, retryBody) = try cbor(key, "clientPIN getRetries", CTAP2.getRetries(protocol: version))
            let retries = retryStatus == CTAP2.ok ? CTAP2.parseRetries(retryBody) : nil
            KeyLog.write("ctap: PIN retries left: \(retries.map(String.init) ?? "unknown")")
            if retries == 0 { throw Self.failure(CTAP2.pinBlocked) }
            guard let typed = ui.pin(retries: retries, wrong: wrong, stop: stop) else {
                if Date() >= deadline && !isCancelled { throw KeyError("NotAllowedError", "nobody entered the security key's PIN in time") }
                throw KeyError.cancelled
            }
            var pin = Array(typed.precomposedStringWithCanonicalMapping.utf8)
            defer { pin.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
            guard (4...63).contains(pin.count) else {
                KeyLog.write("ctap: a PIN of \(pin.count) bytes refused before sending (4 to 63)")
                wrong = true
                continue
            }
            let (agreeStatus, agreeBody) = try cbor(key, "clientPIN getKeyAgreement", CTAP2.getKeyAgreement(protocol: version))
            guard agreeStatus == CTAP2.ok else { throw Self.failure(agreeStatus) }
            guard let peer = CTAP2.parseKeyAgreement(agreeBody), let (platform, shared) = PinProtocol.agree(version: version, authenticatorKey: peer),
                  let pinHashEnc = shared.pinHashEnc(pin) else { throw Self.garbled }
            let request = CTAP2.getPinToken(protocol: version, keyAgreement: platform, pinHashEnc: pinHashEnc,
                                            permissions: withPermissions ? permissions : nil, rpID: withPermissions ? rpID : nil)
            let (status, body) = try cbor(key, withPermissions ? "clientPIN getPinUvAuthTokenUsingPinWithPermissions" : "clientPIN getPinToken", request)
            switch status {
            case CTAP2.ok:
                guard let sealed = CTAP2.parsePinToken(body), var token = shared.decrypt(sealed) else { throw Self.garbled }
                defer { token.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
                return CTAP2.Auth(param: PinProtocol.authenticate(version: version, key: token, clientDataHash), version: version)
            case CTAP2.pinInvalid:
                wrong = true
            default:
                throw Self.failure(status)
            }
        }
    }

    // MARK: Ceremonies

    func create(_ request: KeyCreate) throws -> KeyMade {
        let (key, info) = try connect()
        let listed = info.algorithms.isEmpty ? [WebAuthn.es256] : info.algorithms
        guard let algorithm = request.algorithms.first(where: { [WebAuthn.es256, WebAuthn.eddsa].contains($0) && listed.contains($0) }) else {
            KeyLog.write("ctap: no common algorithm: the site asked \(request.algorithms), the key lists \(listed)")
            throw Self.failure(0x26)
        }
        let (usePIN, builtIn) = try verification(info, request.userVerification)
        let residentKey = request.residentKey == "required" || (request.residentKey == "preferred" && info.options["rk"] == true && (usePIN || builtIn))
        var exclude = request.exclude
        if let longest = info.maxCredentialIdLength { exclude = exclude.filter { $0.count <= longest } }
        if let most = info.maxCredentialCountInList, most > 0, exclude.count > most {
            KeyLog.write("ctap: excludeList of \(exclude.count) cut to the key's \(most)")
            exclude = Array(exclude.prefix(most))
        }
        KeyLog.write("ctap: makeCredential alg \(algorithm), rk \(residentKey), excluding \(exclude.count), attestation wanted \(request.attestation)")
        var auth = usePIN ? try pinAuth(key, info, permissions: CTAP2.permissionMakeCredential, rpID: request.rpID, clientDataHash: request.clientDataHash) : nil
        while true {
            let command = CTAP2.makeCredential(clientDataHash: request.clientDataHash, rpID: request.rpID, rpName: request.rpName, userID: request.userID,
                                               userName: request.userName, displayName: request.displayName, algorithm: algorithm, exclude: exclude,
                                               residentKey: residentKey, uv: builtIn, auth: auth)
            let (status, body) = try cbor(key, "makeCredential", command, touch: true)
            // As WebKit does: the key gave up waiting for the touch before the site did, so ask it again.
            if CTAP2.touchTimeouts.contains(status), !stop() {
                KeyLog.write("ctap: the key stopped waiting for a touch; asking again")
                continue
            }
            if status == CTAP2.pinRequired, auth == nil, info.options["clientPin"] == true {
                auth = try pinAuth(key, info, permissions: CTAP2.permissionMakeCredential, rpID: request.rpID, clientDataHash: request.clientDataHash)
                continue
            }
            guard status == CTAP2.ok else { throw Self.failure(status) }
            guard let made = CTAP2.parseMadeCredential(body), let parsed = WebAuthn.parseAuthenticatorData(made.authData), let id = parsed.credentialID else {
                throw Self.garbled
            }
            KeyLog.write(String(format: "ctap: made a credential: fmt %@, id %d bytes, flags 0x%02X, aaguid %@", made.format, id.count, parsed.flags, KeyLog.hex(parsed.aaguid ?? [])))
            return KeyMade(id: id, attestationObject: WebAuthn.attestationObject(format: made.format, statement: made.statement, authenticatorData: made.authData),
                           transports: ["usb"], discoverable: residentKey)
        }
    }

    func get(_ request: KeyGet) throws -> KeySigned {
        let (key, info) = try connect()
        let (usePIN, builtIn) = try verification(info, request.userVerification)
        var allow = request.allow
        if let longest = info.maxCredentialIdLength {
            allow = allow.filter { $0.count <= longest }
            if allow.count < request.allow.count { KeyLog.write("ctap: \(request.allow.count - allow.count) ids longer than the key's \(longest) bytes left out") }
            if allow.isEmpty && !request.allow.isEmpty { throw Self.failure(CTAP2.noCredentials) }
        }
        // A key that doesn't say how many ids it takes gets one at a time, as Chrome does.
        let size = max(1, info.maxCredentialCountInList ?? 1)
        let chunks = allow.isEmpty ? [[]] : stride(from: 0, to: allow.count, by: size).map { Array(allow[$0..<min(allow.count, $0 + size)]) }
        var rpID = request.rpID, chunk = chunks[0]
        if chunks.count > 1 || (request.appID != nil && !allow.isEmpty) {
            // Silent probes (no touch, no PIN) find which rp id and which part of the list the key answers for.
            var found = false, unsure = false
            search: for candidate in [request.rpID] + (request.appID.map { [$0] } ?? []) {
                for (index, ids) in chunks.enumerated() {
                    let which = candidate == request.rpID ? "rp id" : "AppID"
                    let (status, _) = try cbor(key, "getAssertion probe (\(which), ids \(index + 1) of \(chunks.count), \(ids.count) of them)",
                                               CTAP2.getAssertion(rpID: candidate, clientDataHash: request.clientDataHash, allow: ids, up: false, auth: nil))
                    if status == CTAP2.ok {
                        (rpID, chunk, found) = (candidate, ids, true)
                        break search
                    }
                    if status != CTAP2.noCredentials { unsure = true }
                }
            }
            if !found {
                guard unsure else { throw Self.failure(CTAP2.noCredentials) }
                KeyLog.write("ctap: probes inconclusive; trying the rp id with the first ids")
            }
        }
        KeyLog.write("ctap: getAssertion for \(rpID == request.rpID ? "the rp id" : "the AppID") with \(chunk.count) ids")
        var auth = usePIN ? try pinAuth(key, info, permissions: CTAP2.permissionGetAssertion, rpID: rpID, clientDataHash: request.clientDataHash) : nil
        while true {
            let command = CTAP2.getAssertion(rpID: rpID, clientDataHash: request.clientDataHash, allow: chunk, uv: builtIn, auth: auth)
            let (status, body) = try cbor(key, "getAssertion", command, touch: true)
            // As WebKit does: the key gave up waiting for the touch before the site did, so ask it again.
            if CTAP2.touchTimeouts.contains(status), !stop() {
                KeyLog.write("ctap: the key stopped waiting for a touch; asking again")
                continue
            }
            if status == CTAP2.pinRequired, auth == nil, info.options["clientPin"] == true {
                auth = try pinAuth(key, info, permissions: CTAP2.permissionGetAssertion, rpID: rpID, clientDataHash: request.clientDataHash)
                continue
            }
            guard status == CTAP2.ok else { throw Self.failure(status) }
            guard let assertion = CTAP2.parseAssertion(body, allow: chunk) else { throw Self.garbled }
            if let count = assertion.count, count > 1 { KeyLog.write("ctap: the key holds \(count) accounts for the site; agweb used the first") }
            KeyLog.write("ctap: signed with id \(assertion.credentialID.count) bytes, user handle \(assertion.userID == nil ? "none" : "\(assertion.userID!.count) bytes")")
            return KeySigned(id: assertion.credentialID, authData: assertion.authData, signature: assertion.signature,
                             userHandle: assertion.userID, viaAppID: rpID != request.rpID)
        }
    }
}

/// A FIDO HID device, opened and scheduled on the run loop of the thread that opened it, which also reads it.
private final class HIDKey: @unchecked Sendable {
    let device: IOHIDDevice
    let inputSize: Int, outputSize: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private let runLoop: CFRunLoop
    /// Touched only on the opening thread, by the report callback and `next`.
    private var reports: [[UInt8]] = []
    private let writeLock = NSLock()
    private var closed = false
    private var cid = CTAPHID.broadcast
    private static let modeName = "agweb.ctaphid" as CFString

    /// FIDO devices only (usage page 0xF1D0), and without opening the manager: matching every HID device, or opening
    /// a keyboard, would make macOS ask for Input Monitoring.
    static func plugged() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xF1D0, kIOHIDPrimaryUsageKey: 0x01] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        return (set as NSSet).allObjects.map { $0 as! IOHIDDevice }
    }

    static func property<T>(_ device: IOHIDDevice, _ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }

    static func describe(_ device: IOHIDDevice) -> String {
        let vendor: Int = property(device, kIOHIDVendorIDKey) ?? 0, product: Int = property(device, kIOHIDProductIDKey) ?? 0
        let name: String = property(device, kIOHIDProductKey) ?? "?", maker: String = property(device, kIOHIDManufacturerKey) ?? "?"
        let input: Int = property(device, kIOHIDMaxInputReportSizeKey) ?? 0, output: Int = property(device, kIOHIDMaxOutputReportSizeKey) ?? 0
        return String(format: "%@ %@ (vendor %04X, product %04X), reports in %d out %d", maker, name, vendor, product, input, output)
    }

    init(_ device: IOHIDDevice) throws {
        self.device = device
        let input: Int = Self.property(device, kIOHIDMaxInputReportSizeKey) ?? 64, output: Int = Self.property(device, kIOHIDMaxOutputReportSizeKey) ?? 64
        (inputSize, outputSize) = (input > 0 ? input : 64, output > 0 ? output : 64)
        buffer = .allocate(capacity: inputSize)
        runLoop = CFRunLoopGetCurrent()
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            // deinit still runs (every property is set) and frees the buffer.
            closed = true
            KeyLog.write(String(format: "ctap: IOHIDDeviceOpen failed: 0x%08X", opened))
            throw KeyError("NotAllowedError", String(format: "the security key couldn't be opened (IOKit 0x%08X); another app may hold it", opened))
        }
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, Self.modeName)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, inputSize, { context, _, _, _, _, report, length in
            guard let context else { return }
            Unmanaged<HIDKey>.fromOpaque(context).takeUnretainedValue().received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { buffer.deallocate() }

    private func received(_ report: [UInt8]) { reports.append(report) }

    func setChannel(_ cid: UInt32) { writeLock.withLock { self.cid = cid } }

    func write(_ packet: [UInt8]) throws {
        let result: IOReturn = writeLock.withLock {
            guard !closed else { return kIOReturnNotOpen }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        }
        guard result == kIOReturnSuccess else {
            KeyLog.write(String(format: "ctap: IOHIDDeviceSetReport failed: 0x%08X", result))
            throw KeyError("NotAllowedError", String(format: "the security key stopped answering (IOKit 0x%08X); was it unplugged?", result))
        }
    }

    /// From any thread: CTAPHID_CANCEL on the ceremony's channel.
    func sendCancel() {
        writeLock.withLock {
            guard !closed, cid != CTAPHID.broadcast else { return }
            let packet = CTAPHID.packets(cid: cid, command: CTAPHID.cancel, payload: [], reportSize: outputSize)[0]
            _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        }
    }

    /// The next input report; nil at the deadline or when `stop` says so.
    func next(until deadline: Date, stop: () -> Bool) -> [UInt8]? {
        while reports.isEmpty {
            if stop() || Date() >= deadline { return nil }
            let slice = min(0.1, max(0.01, deadline.timeIntervalSinceNow))
            if CFRunLoopRunInMode(CFRunLoopMode(Self.modeName), slice, true) == .finished { Thread.sleep(forTimeInterval: 0.01) }
        }
        return reports.removeFirst()
    }

    /// On the opening thread.
    func close() {
        let wasClosed = writeLock.withLock { defer { closed = true }; return closed }
        guard !wasClosed else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, inputSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, Self.modeName)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
