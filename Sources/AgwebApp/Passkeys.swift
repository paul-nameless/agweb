import AgwebCore
import AppKit
import CryptoKit
import Foundation
import WebKit

/// One passkey as Settings lists it: under its profile, or a fresh workspace's (in memory).
struct PasskeyEntry: Identifiable {
    let passkey: Passkey
    /// "profile NAME" or "workspace NAME, in memory": the Settings section it's in.
    let group: String
    let delete: () throws -> Void
    var id: String { passkey.id }
}

/// Where a workspace's passkeys live: its named profile's file, or the fresh workspace itself.
enum PasskeyOwner {
    case profile(String)
    case workspace(Workspace)

    init(_ workspace: Workspace) { self = workspace.profile.map { .profile($0) } ?? .workspace(workspace) }
}

/// agweb as a passkey authenticator for its pages. A ceremony is answered only
/// for the agent's own tab during its command and for 10 s after, or right after the person's own click or key in
/// it; the origin comes from WebKit, never from the page.
@MainActor @Observable
final class Passkeys: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = Passkeys()
    static let handlerName = "agwebPasskey"
    /// How long after an agent command or the person's input a tab may still use passkeys: a site's button often
    /// fetches its options from the server first.
    static let grace = ProcessInfo.processInfo.environment["AGWEB_PASSKEY_SECONDS"].flatMap(TimeInterval.init) ?? 10
    static let perSite = 20

    @ObservationIgnored weak var browser: Browser?
    /// Bumped on every change, for Settings to redraw.
    private(set) var revision = 0
    /// Commands whose page may use passkeys while they run and for `grace` after: the ones acting on it, not
    /// `console` or `list` polling.
    static let commands: Set = ["open", "goto", "reload", "click", "dblclick", "check", "uncheck", "fill", "select", "type", "press",
                                "keydown", "keyup", "mousedown", "mouseup", "eval", "wait"]

    var enabled: Bool { Settings.store.bool(forKey: Settings.passkeys) }

    // MARK: Store

    /// Named profiles' passkeys: the login Keychain for the person's instance, a 0600 file in any other root
    /// (AGWEB_PASSKEY_STORE=keychain tries the Keychain there).
    @ObservationIgnored let store: PasskeyStore = Agweb.isDefaultRoot
        // Only a test build (its own bundle id, so its own Keychain items): another root of the person's build would share theirs.
        || (Agweb.isTestBuild(Agweb.bundleIdentifier) && ProcessInfo.processInfo.environment["AGWEB_PASSKEY_STORE"] == "keychain")
        ? KeychainPasskeyStore(service: Agweb.bundleIdentifier + ".passkey")
        : FilePasskeyStore(file: Agweb.root.appendingPathComponent("passkeys.json"))

    private func store(_ owner: PasskeyOwner) -> PasskeyStore {
        if case .workspace(let workspace) = owner { return workspace.passkeys }
        return store
    }

    /// What Settings and `agweb passkey list` show; an unreadable store shows as none.
    func list(_ owner: PasskeyOwner) -> [Passkey] { (try? stored(owner)) ?? [] }

    /// Read afresh each time: another instance on the root, or the person in Settings, may have changed it.
    private func stored(_ owner: PasskeyOwner) throws -> [Passkey] {
        do {
            switch owner {
            case .workspace(let workspace): return workspace.passkeys.all()
            case .profile(let name): return try store.all().filter { ($0.profile ?? "") == name }
            }
        } catch { throw Refusal("NotAllowedError", "\(error)") }
    }

    /// Whether an agent made it, by the protected copy; unreadable or unmarked counts as the person's. `telling`: a locked
    /// Keychain throws its own reason instead.
    private func agentMade(_ passkey: Passkey, _ store: PasskeyStore, telling: Bool = false) throws -> Bool {
        do { return try store.secret(passkey.id, interactive: false).agentMade } catch let failure as Failure where telling && failure.description.contains("Keychain is locked") {
            throw failure
        } catch { return false }
    }

    /// What `profile delete` must not take with it: the passkeys the person made there.
    func personMade(profile name: String) throws -> [String] {
        try store.all().filter { $0.profile == name && !((try? agentMade($0, store)) ?? false) }.map { "the passkey for \($0.label)" }
    }

    /// A deleted profile's passkeys go with it, or the profile stays: one made later with that name would get them.
    func forget(profile name: String) throws {
        defer { revision += 1 }
        setUsesKey(false, .profile(name))
        for passkey in try store.all() where passkey.profile == name { try? store.delete(passkey.id, interactive: false) }
        let left = try store.all().filter { $0.profile == name }.count
        if left > 0 { throw Failure("\(left) of profile \(name)'s passkeys couldn't be deleted from the Keychain, so the profile stays; try again, or delete them in Settings ▸ Passkeys") }
    }

    /// Every passkey Settings shows: named profiles' and fresh workspaces' (in memory).
    func entries() -> [PasskeyEntry] {
        var entries: [PasskeyEntry] = []
        for passkey in (try? store.all()) ?? [] {
            let owner = PasskeyOwner.profile(passkey.profile ?? "")
            entries.append(PasskeyEntry(passkey: passkey, group: "profile \(passkey.profile ?? "?")") { [weak self] in try self?.delete(passkey.id, owner) })
        }
        for workspace in browser?.model.workspaces ?? [] where workspace.profile == nil {
            for passkey in workspace.passkeys.all() {
                entries.append(PasskeyEntry(passkey: passkey, group: "workspace \(workspace.name), in memory") { [weak self] in
                    try self?.delete(passkey.id, .workspace(workspace))
                })
            }
        }
        return entries.sorted { ($0.passkey.rpID, $0.passkey.created) < ($1.passkey.rpID, $1.passkey.created) }
    }

    /// The shim is a user script: pages get it, or lose it, from their next load.
    func settingChanged() {
        for workspace in browser?.model.workspaces ?? [] { workspace.installScripts() }
    }

    /// Settings: the person's delete, after the owner check; the Keychain may ask them.
    func delete(_ id: String, _ owner: PasskeyOwner) throws {
        guard list(owner).contains(where: { $0.id == id }) else { return }
        try store(owner).delete(id, interactive: true)
        revision += 1
    }

    /// `passkey delete`: an agent deletes only a passkey an agent made.
    func agentDelete(_ id: String, _ owner: PasskeyOwner) throws -> Passkey {
        guard let passkey = list(owner).first(where: { $0.id == id }) else { throw Failure("no passkey \(id) in this workspace's profile; agweb passkey list shows them") }
        guard try agentMade(passkey, store(owner), telling: true) else { throw Failure("the passkey for \(passkey.label) is the person's; they delete it in Settings ▸ Passkeys") }
        try store(owner).delete(id, interactive: false)
        revision += 1
        return passkey
    }

    // MARK: Security key

    /// Whether the owner's sign-ups, and sign-ins no agweb passkey answers, go to a security key: the person's switch in
    /// Settings, never an agent's.
    func usesKey(_ owner: PasskeyOwner) -> Bool {
        if Settings.store.bool(forKey: Settings.securityKeyAll) { return true }
        guard case .profile(let name) = owner else { return false }
        return (Settings.store.stringArray(forKey: Settings.securityKeyProfiles) ?? []).contains(name)
    }

    func setUsesKey(_ on: Bool, _ owner: PasskeyOwner) {
        guard case .profile(let name) = owner else { return }
        let names = (Settings.store.stringArray(forKey: Settings.securityKeyProfiles) ?? []).filter { $0 != name } + (on ? [name] : [])
        Settings.store.set(names.sorted(), forKey: Settings.securityKeyProfiles)
        revision += 1
    }

    func keySettingChanged() { revision += 1 }

    /// The one ceremony the key serves (there is one key, and one person to touch it).
    @ObservationIgnored private var ceremony: KeyCeremony?

    /// The tab's page went away (its next page, the tab closing): a ceremony it started ends.
    func pageGone(_ tab: Tab, _ reason: String) {
        guard let ceremony, ceremony.tab === tab else { return }
        ceremony.cancel(reason, quiet: true)
    }

    /// For `agweb passkey hardware`: whether the workspace may use a key, and how.
    func keyStatus(_ workspace: Workspace) -> String {
        let owner = PasskeyOwner(workspace)
        let whose = workspace.profile.map { "profile \($0)" } ?? "fresh workspace \(workspace.name)"
        let choice = KeyBackendChoice.current
        guard usesKey(owner) else {
            return "security keys off for \(whose): only the person turns them on, in Settings ▸ Passkeys (for one profile or every workspace)"
        }
        return "security keys on for \(whose), through \(choice.label)\(choice.missing.map { " (unavailable: \($0))" } ?? ""): a site's passkey sign-up, "
            + "and a sign-in no agweb passkey answers, go to the key plugged into this Mac. The person touches it and types its PIN in the tab's bar, "
            + "so ask them first. Log: \(KeyLog.file.path)" + (enabled ? "" : "\nPasskeys are off in Agweb's Settings, so sites get no answer.")
    }

    private static func keyTimeout(_ options: [String: Any]) -> TimeInterval {
        min(max((options["timeout"] as? Double).map { $0 / 1000 } ?? 120, 30), 300)
    }

    /// Runs one ceremony on the key, with the tab's bar showing each step.
    private func withKey<T>(_ tab: Tab, origin: String, site: String, doing: String, timeout: TimeInterval,
                            _ body: (SecurityKeyBackend, KeyUI) async throws -> T) async throws -> T {
        guard ceremony == nil else { throw Refusal("NotAllowedError", "the security key is busy with another request") }
        let choice = KeyBackendChoice.current
        if let missing = choice.missing { throw Refusal("NotAllowedError", "security keys through \(choice.label) can't run here: \(missing)") }
        let ceremony = KeyCeremony(tab: tab, origin: origin, site: site, doing: doing, choice: choice)
        self.ceremony = ceremony
        ceremony.onPhase = { [weak self, weak tab, weak ceremony] in
            guard let self, let tab, let ceremony, self.ceremony === ceremony else { return }
            self.browser?.mainWindow.showKey(on: tab.webView, ceremony)
        }
        ceremony.onPhase?()
        let started = Date()
        KeyLog.write("ceremony: \(doing) \(site) for \(origin) in workspace \(tab.workspace.name) through \(choice.rawValue), timeout \(Int(timeout))s")
        let timer = Task { [weak ceremony] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { ceremony?.cancel("nobody used the security key in time") }
        }
        defer {
            timer.cancel()
            self.ceremony = nil
            browser?.mainWindow.hideKey(on: tab.webView)
        }
        do {
            let result = try await body(ceremony.backend, ceremony)
            if let cancelled = ceremony.cancelled { throw Refusal("NotAllowedError", cancelled.reason, quiet: cancelled.quiet) }
            KeyLog.write("ceremony: done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return result
        } catch {
            if let cancelled = ceremony.cancelled {
                KeyLog.write("ceremony: ended: \(cancelled.reason)")
                throw Refusal("NotAllowedError", cancelled.reason, quiet: cancelled.quiet)
            }
            KeyLog.write("ceremony: failed: \(error)")
            if let failure = error as? KeyError { throw Refusal(failure.name, failure.message) }
            throw error
        }
    }

    private func keyCreate(_ options: [String: Any], challenge: [UInt8], origin: String, host: String, tab: Tab, credProps: Bool) throws -> Prepared {
        let rpID = try rpID(options, key: "rp", host: host)
        let rpName = Self.clean((options["rp"] as? [String: Any])?["name"] as? String)
        let user = options["user"] as? [String: Any] ?? [:]
        guard let handle = (user["id"] as? String).flatMap(WebAuthn.fromBase64url), (1...64).contains(handle.count) else {
            throw Refusal("TypeError", "user.id must be 1 to 64 bytes")
        }
        let userName = Self.clean(user["name"] as? String), displayName = Self.clean(user["displayName"] as? String)
        let params = (options["pubKeyCredParams"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String ?? "public-key") == "public-key" }
        // The spec's default when the site names none: ES256, then RS256.
        let algorithms = params.isEmpty ? [WebAuthn.es256, -257] : params.compactMap { $0["alg"] as? Int }
        let selection = options["authenticatorSelection"] as? [String: Any] ?? [:]
        let residentKey = selection["residentKey"] as? String ?? (selection["requireResidentKey"] as? Bool == true ? "required" : "discouraged")
        let attestation = options["attestation"] as? String ?? "none"
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin, crossOrigin: false)
        let request = KeyCreate(
            clientDataHash: [UInt8](SHA256.hash(data: Data(clientData))), rpID: rpID, rpName: rpName, userID: handle, userName: userName, displayName: displayName, algorithms: algorithms,
            residentKey: residentKey, userVerification: selection["userVerification"] as? String ?? "preferred", attestation: attestation,
            exclude: (options["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(WebAuthn.fromBase64url) },
            timeout: Self.keyTimeout(options))
        return Prepared(title: "", detail: "", button: "", key: true) { [self] _ in
            let made = try await withKey(tab, origin: origin, site: rpID, doing: "create a passkey for", timeout: request.timeout) { backend, ui in
                try await backend.create(request, ui)
            }
            guard let parsed = WebAuthn.parseAttestationObject(made.attestationObject),
                  let authData = WebAuthn.parseAuthenticatorData(parsed.authData), let cose = authData.coseKey,
                  let key = WebAuthn.publicKeyInfo(cose: cose) else {
                KeyLog.write("ceremony: unreadable attestation object \(KeyLog.hex(made.attestationObject, limit: 512))")
                throw Refusal("NotAllowedError", "the security key's answer couldn't be read (see \(KeyLog.file.path))")
            }
            KeyLog.write("ceremony: attestation fmt \(parsed.format), algorithm \(key.algorithm), aaguid \(authData.aaguid.map { KeyLog.hex($0) } ?? "-"), site asked \(attestation)")
            // As browsers do: a site that didn't ask for attestation doesn't get the key's make and model.
            let object = attestation == "none" && parsed.format != "none"
                ? WebAuthn.attestationObject(format: "none", statement: CBOR.map([]), authenticatorData: parsed.authData) : made.attestationObject
            tab.events.append("passkey created on the security key for \(rpID) (user \(userName.isEmpty ? displayName : userName))")
            var reply: [String: Any] = [
                "id": WebAuthn.base64url(made.id), "clientDataJSON": WebAuthn.base64url(clientData), "attestationObject": WebAuthn.base64url(object),
                "authenticatorData": WebAuthn.base64url(parsed.authData), "algorithm": key.algorithm, "transports": made.transports,
                "attachment": "cross-platform", "credProps": credProps,
            ]
            if let discoverable = made.discoverable { reply["rk"] = discoverable }
            if let spki = key.spki { reply["publicKey"] = WebAuthn.base64url(spki) }
            return reply
        }
    }

    private func keyGet(_ options: [String: Any], challenge: [UInt8], origin: String, rpID: String, host: String, tab: Tab) throws -> Prepared {
        let allow = (options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(WebAuthn.fromBase64url) }
        let appID = (options["extensions"] as? [String: Any])?["appid"] as? String
        if let appID, !(PublicSuffixes.bundled.map { WebAuthn.appIDAllowed(appID, host: host, suffixes: $0) } ?? false) {
            throw Refusal("SecurityError", "\(host) can't use the AppID \(Self.clean(appID))")
        }
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin, crossOrigin: false)
        let request = KeyGet(clientDataHash: [UInt8](SHA256.hash(data: Data(clientData))), rpID: rpID, allow: allow,
                             userVerification: options["userVerification"] as? String ?? "preferred", appID: appID, timeout: Self.keyTimeout(options))
        return Prepared(title: "", detail: "", button: "", key: true) { [self] _ in
            let signed = try await withKey(tab, origin: origin, site: rpID, doing: "sign in to", timeout: request.timeout) { backend, ui in
                try await backend.get(request, ui)
            }
            tab.events.append("signed in to \(rpID) with the security key")
            var reply: [String: Any] = ["id": WebAuthn.base64url(signed.id), "clientDataJSON": WebAuthn.base64url(clientData),
                                        "authenticatorData": WebAuthn.base64url(signed.authData), "signature": WebAuthn.base64url(signed.signature),
                                        "attachment": "cross-platform"]
            if let handle = signed.userHandle, !handle.isEmpty { reply["userHandle"] = WebAuthn.base64url(handle) }
            if appID != nil { reply["extensions"] = ["appid": signed.viaAppID] }
            return reply
        }
    }

    // MARK: Ceremonies

    /// `quiet`: the page gets the error, the agent's Events don't, for a request nobody made (a page's own timer).
    private struct Refusal: Error {
        let name: String, message: String, quiet: Bool
        init(_ name: String, _ message: String, quiet: Bool = false) { (self.name, self.message, self.quiet) = (name, message, quiet) }
    }

    /// What a ceremony would do, checked; `commit` does it. The person's own click asks them first.
    private struct Prepared {
        let title: String, detail: String, button: String
        /// A security key's: the person's touch is their OK, so no sheet asks first.
        var key = false
        /// `byPerson`: the person said yes in the sheet, so the Keychain may ask them too.
        let commit: (_ byPerson: Bool) async throws -> [String: Any]
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let tab = browser?.tab(for: message.webView)
        // The page aborted its request: a ceremony it started on the key ends (only that page's own, by origin).
        if (message.body as? [String: Any])?["kind"] as? String == "cancel" {
            let origin = message.frameInfo.securityOrigin
            if let tab, let ceremony, ceremony.tab === tab,
               WebAuthn.origin(scheme: origin.protocol.lowercased(), host: origin.host.lowercased(), port: origin.port) == ceremony.origin {
                ceremony.cancel("the page cancelled the request", quiet: true)
            }
            return replyHandler(nil, nil)
        }
        func refuse(_ refusal: Refusal) {
            if !refusal.quiet { tab?.events.append("passkey request refused: \(refusal.message)") }
            replyHandler(["error": ["name": refusal.name, "message": refusal.message]], nil)
        }
        func run(_ prepared: Prepared, byPerson: Bool) {
            Task { @MainActor in
                do {
                    let reply = try await prepared.commit(byPerson)
                    tab?.passkeyAt = Date()
                    replyHandler(["credential": reply], nil)
                } catch let refusal as Refusal { refuse(refusal) } catch { refuse(Refusal("NotAllowedError", "\(error)")) }
            }
        }
        do {
            guard let tab else { throw Refusal("NotAllowedError", "agweb doesn't know this page") }
            let (prepared, byPerson) = try prepare(message, tab)
            guard byPerson && !prepared.key else { return run(prepared, byPerson: byPerson) }
            // An agent's request needs no prompt; the person sees what agweb's passkey is before it's made or used.
            guard let window = browser?.mainWindow.window, window.isVisible, window.attachedSheet == nil else {
                throw Refusal("NotAllowedError", "another question is open in the window")
            }
            tab.events.append("the person was asked to confirm a passkey request (their own click in the tab)")
            let alert = NSAlert()
            alert.messageText = prepared.title
            alert.informativeText = prepared.detail
            // No default button: a page that asks while the person types must not get a passkey from their Return key,
            // and the button wakes only after a moment, so a double-click the page invited can't land on it.
            let confirm = alert.addButton(withTitle: prepared.button)
            confirm.keyEquivalent = ""
            confirm.isEnabled = false
            alert.addButton(withTitle: "Cancel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { confirm.isEnabled = true }
            let commits = tab.commits
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return refuse(Refusal("NotAllowedError", "the person cancelled")) }
                // The page that asked is gone: a passkey it never receives would only shadow the account's real one.
                guard self?.browser?.tab(for: tab.webView) === tab, tab.commits == commits else {
                    return refuse(Refusal("NotAllowedError", "the page changed while the question was open", quiet: true))
                }
                run(prepared, byPerson: true)
            }
        } catch let refusal as Refusal { refuse(refusal) } catch { refuse(Refusal("NotAllowedError", "\(error)")) }
    }

    /// The checks, and whether the person (not an agent) asked: their click in the tab, no agent command on it.
    private func prepare(_ message: WKScriptMessage, _ tab: Tab) throws -> (Prepared, byPerson: Bool) {
        // First, and quiet: a page asking by itself (a timer, an ad frame) must not fill the agent's Events.
        let now = Date()
        let workspace = tab.workspace
        let personClicked = now.timeIntervalSince(tab.passkeyInputAt) < Self.grace
        // During `ask` the tab is the person's: their click there asks them. So is a click of theirs after the agent's
        // last command began, even inside the agent's window: it gets the sheet and the passkey is theirs.
        let byAgent = tab.asking == nil
            && ((workspace.busy && workspace.passkeyCommand && workspace.current === tab) || now < tab.agentUntil)
            && !(personClicked && tab.passkeyInputAt > workspace.lastCommandAt ?? .distantPast)
        guard byAgent || personClicked else {
            throw Refusal("NotAllowedError", "passkeys answer only during an agent's command on this tab or right after the person's own click in it", quiet: true)
        }
        guard enabled else { throw Refusal("NotAllowedError", "passkeys are off in Agweb's Settings") }
        let origin = message.frameInfo.securityOrigin
        let scheme = origin.protocol.lowercased(), host = origin.host.lowercased()
        guard !scheme.isEmpty, !host.isEmpty else { throw Refusal("NotAllowedError", "a sandboxed or data: frame can't use passkeys") }
        guard WebAuthn.isSecure(scheme: scheme, host: host) else { throw Refusal("SecurityError", "passkeys need https") }
        let originText = WebAuthn.origin(scheme: scheme, host: host, port: origin.port)
        // Native code can't read a frame's Permissions Policy, and anything the page reports could be forged.
        if !message.frameInfo.isMainFrame && !tab.isTop(originText) {
            throw Refusal("NotAllowedError", "a frame from another site can't use agweb's passkeys")
        }
        // Mid-navigation the tab's URL may already be the next page's, which a frame of that site would match.
        if !message.frameInfo.isMainFrame && tab.webView.isLoading {
            throw Refusal("NotAllowedError", "a frame can't use passkeys while the page loads; try again once it has")
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let options = body["publicKey"] as? [String: Any] else { throw Refusal("TypeError", "malformed passkey request") }
        guard let challenge = (options["challenge"] as? String).flatMap(WebAuthn.fromBase64url), !challenge.isEmpty else {
            throw Refusal("TypeError", "the request has no challenge")
        }
        let owner = PasskeyOwner(tab.workspace)
        if kind == "create" && usesKey(owner) {
            return (try keyCreate(options, challenge: challenge, origin: originText, host: host, tab: tab, credProps: body["credProps"] as? Bool ?? false), !byAgent)
        }
        if kind == "get" && usesKey(owner) {
            let rpID = try rpID(options, key: nil, host: host)
            if try matching(owner, rpID: rpID, options) == nil {
                return (try keyGet(options, challenge: challenge, origin: originText, rpID: rpID, host: host, tab: tab), !byAgent)
            }
        }
        switch kind {
        case "create": return (try create(options, challenge: challenge, origin: originText, host: host, owner: owner, tab: tab, credProps: body["credProps"] as? Bool ?? false), !byAgent)
        case "get": return (try get(options, challenge: challenge, origin: originText, host: host, owner: owner, tab: tab), !byAgent)
        default: throw Refusal("TypeError", "unknown passkey request \(Self.clean(kind))")
        }
    }

    private func rpID(_ options: [String: Any], key: String?, host: String) throws -> String {
        let rpID = (key.map { (options[$0] as? [String: Any])?["id"] } ?? options["rpId"]) as? String ?? host
        let allowed = PublicSuffixes.bundled.map { WebAuthn.rpIDAllowed(rpID, host: host, suffixes: $0) } ?? (rpID.lowercased() == host)
        guard allowed else { throw Refusal("SecurityError", "\(host) can't use passkeys for \(Self.clean(rpID))") }
        return rpID.lowercased()
    }

    private func place(_ workspace: Workspace) -> String {
        let keychain = store is KeychainPasskeyStore ? "in your login Keychain" : "in this instance's passkeys file"
        return workspace.profile.map { "\(keychain), for profile \($0)" } ?? "in this workspace's memory only (gone when the workspace closes or Agweb quits)"
    }

    /// The Keychain may ask the person only after their own OK, and then off the main thread: the whole app (every
    /// agent's command) would wait on its dialog.
    private func keychainCall<T>(_ owner: PasskeyOwner, byPerson: Bool, _ body: @escaping @Sendable (PasskeyStore, Bool) throws -> T) async throws -> T {
        let store = store(owner)
        if byPerson, let keychain = store as? KeychainPasskeyStore {
            return try await Task.detached { try body(keychain, true) }.value
        }
        return try body(store, false)
    }

    private func create(_ options: [String: Any], challenge: [UInt8], origin: String, host: String, owner: PasskeyOwner, tab: Tab, credProps: Bool) throws -> Prepared {
        let rpID = try rpID(options, key: "rp", host: host)
        let user = options["user"] as? [String: Any] ?? [:]
        guard let handle = (user["id"] as? String).flatMap(WebAuthn.fromBase64url), (1...64).contains(handle.count) else {
            throw Refusal("TypeError", "user.id must be 1 to 64 bytes")
        }
        let params = options["pubKeyCredParams"] as? [[String: Any]] ?? []
        guard params.isEmpty || params.contains(where: { $0["alg"] as? Int == WebAuthn.es256 && ($0["type"] as? String ?? "public-key") == "public-key" }) else {
            throw Refusal("NotSupportedError", "agweb's passkeys are ES256 (-7) only")
        }
        if (options["authenticatorSelection"] as? [String: Any])?["authenticatorAttachment"] as? String == "cross-platform" {
            throw Refusal("NotAllowedError", "the site asked for a security key; the person can let this profile use one in Settings ▸ Passkeys")
        }
        let handleText = WebAuthn.base64url(handle)
        let excluded = Set((options["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        // Signing up again with the same account replaces its passkey, as other authenticators do.
        func replaced() throws -> [Passkey] {
            let list = try stored(owner).filter { $0.rpID == rpID }
            if list.contains(where: { excluded.contains($0.id) }) {
                throw Refusal("InvalidStateError", "this profile already has a passkey for that account on \(rpID)")
            }
            let same = list.filter { $0.userHandle == handleText }
            guard list.count - same.count < Self.perSite else {
                throw Refusal("NotAllowedError", "this profile already holds \(Self.perSite) passkeys for \(rpID); delete some with agweb passkey delete")
            }
            return same
        }
        let replacing = try !replaced().isEmpty
        let userName = Self.clean(user["name"] as? String), displayName = Self.clean(user["displayName"] as? String)
        let shown = userName.isEmpty ? displayName : userName
        return Prepared(
            title: "Create a passkey for \(rpID)?",
            detail: "Agweb keeps this passkey for \(shown.isEmpty ? "your account" : shown) \(place(tab.workspace)). "
                + "Agents working there can sign in with it too. It isn't saved to Apple Passwords or 1Password; Settings ▸ Passkeys lists it."
                + (replacing ? " It replaces the passkey Agweb has for this account, which then no longer signs in." : ""),
            button: "Create Passkey"
        ) { [self] byPerson in
            let old = try replaced()
            // The person may replace even when the Keychain wants their OK to read the old one; the add then asks.
            let replacesPersons = try old.contains { try !agentMade($0, store(owner), telling: !byPerson) }
            // An agent deletes only what an agent made, and replacing is deleting.
            if replacesPersons && !byPerson {
                throw Refusal("InvalidStateError", "this profile has the person's passkey for that account on \(rpID); only the person can replace it")
            }
            let personMade = byPerson
            let key = P256.Signing.PrivateKey()
            var idBytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes) == errSecSuccess else { throw Refusal("NotAllowedError", "no random bytes for the passkey's id") }
            let profile: String? = if case .profile(let name) = owner { name } else { nil }
            let passkey = Passkey(id: WebAuthn.base64url(idBytes), rpID: rpID, userHandle: handleText, userName: userName, displayName: displayName,
                                  profile: profile, created: Date(), lastUsed: nil, byPerson: personMade)
            let authData = WebAuthn.authenticatorData(rpID: rpID, flags: WebAuthn.flags(create: true, synced: profile != nil), credentialID: idBytes,
                                                      coseKey: WebAuthn.coseKey(publicKey: key.publicKey))
            let clientData = WebAuthn.clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin, crossOrigin: false)
            let secret = PasskeySecret(key: key.derRepresentation, rpID: rpID, userHandle: handleText, profile: profile, byPerson: personMade)
            do {
                try await keychainCall(owner, byPerson: byPerson) { try $0.add(passkey, secret, interactive: $1) }
            } catch { throw Refusal("NotAllowedError", "couldn't save the passkey: \(error)") }
            for passkey in old { try? store(owner).delete(passkey.id, interactive: false) }
            revision += 1
            tab.events.append("passkey created for \(passkey.label)")
            return ["id": passkey.id, "clientDataJSON": WebAuthn.base64url(clientData),
                    "attestationObject": WebAuthn.base64url(WebAuthn.attestationObject(authenticatorData: authData)),
                    "authenticatorData": WebAuthn.base64url(authData), "publicKey": WebAuthn.base64url(key.publicKey.derRepresentation),
                    "credProps": credProps]
        }
    }

    private func get(_ options: [String: Any], challenge: [UInt8], origin: String, host: String, owner: PasskeyOwner, tab: Tab) throws -> Prepared {
        let rpID = try rpID(options, key: nil, host: host)
        guard let chosen = try matching(owner, rpID: rpID, options) else {
            let named = !(options["allowCredentials"] as? [Any] ?? []).isEmpty
            throw Refusal("NotAllowedError", "no agweb passkey for \(rpID) in this " + (tab.workspace.profile.map { "profile (\($0))" } ?? "fresh workspace")
                + (named && !usesKey(owner) ? "; if the account uses a security key, the person can let this profile use one in Settings ▸ Passkeys" : ""))
        }
        let shown = chosen.userName.isEmpty ? chosen.displayName : chosen.userName
        return Prepared(
            title: "Sign in to \(rpID)" + (shown.isEmpty ? "?" : " as \(shown)?"),
            detail: "With the passkey Agweb keeps \(place(tab.workspace)).",
            button: "Sign In"
        ) { [self] byPerson in
            guard var passkey = try stored(owner).first(where: { $0.id == chosen.id }) else {
                throw Refusal("NotAllowedError", "the passkey for \(chosen.label) was deleted")
            }
            let authData = WebAuthn.authenticatorData(rpID: rpID, flags: WebAuthn.flags(create: false, synced: passkey.profile != nil))
            let clientData = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin, crossOrigin: false)
            let signature: Data, secret: PasskeySecret
            do {
                let id = passkey.id
                secret = try await keychainCall(owner, byPerson: byPerson) { try $0.secret(id, interactive: $1) }
                // The listing can be rewritten without the Keychain asking; the key's own copy can't.
                guard secret.rpID == rpID, secret.userHandle == passkey.userHandle, secret.profile == passkey.profile else {
                    throw Failure("its Keychain item was changed outside Agweb")
                }
                signature = try secret.signingKey().signature(for: Data(authData + SHA256.hash(data: Data(clientData)))).derRepresentation
            } catch {
                throw Refusal("NotAllowedError", "the passkey for \(chosen.label) can't be used: \(error)")
            }
            passkey.lastUsed = Date()
            store(owner).used(passkey)
            revision += 1
            tab.events.append("signed in with a passkey for \(passkey.label)")
            return ["id": passkey.id, "clientDataJSON": WebAuthn.base64url(clientData), "authenticatorData": WebAuthn.base64url(authData),
                    "signature": WebAuthn.base64url(signature), "userHandle": secret.userHandle]
        }
    }

    /// The agweb passkey a sign-in would use: for the rp id, among those the site lists; with no list, the one used last.
    private func matching(_ owner: PasskeyOwner, rpID: String, _ options: [String: Any]) throws -> Passkey? {
        let allowedIDs = Set((options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        return try stored(owner).filter { $0.rpID == rpID && (allowedIDs.isEmpty || allowedIDs.contains($0.id)) }
            .max(by: { ($0.lastUsed ?? $0.created) < ($1.lastUsed ?? $1.created) })
    }

    /// Page-supplied names reach replies and Settings: one line, no control characters, short.
    private static func clean(_ text: String?) -> String {
        String((text ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }.prefix(64)
            .map(Character.init))
    }
}

extension Tab {
    /// Whether `origin` is the tab's top document's: a frame may use passkeys only on its own page.
    func isTop(_ origin: String) -> Bool {
        guard let url = webView.url, let scheme = url.scheme, let host = url.host else { return false }
        return WebAuthn.origin(scheme: scheme.lowercased(), host: host.lowercased(), port: url.port ?? 0) == origin
    }
}
