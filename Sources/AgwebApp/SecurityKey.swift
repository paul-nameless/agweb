import AgwebCore
import Foundation

// A USB security key (a YubiKey) as a second authenticator beside agweb's own passkeys, for profiles the person
// switched it on for in Settings ▸ Passkeys. Agweb speaks CTAP2 to it over USB HID itself (SecurityKeyCTAP.swift), after
// checking the origin and rp id; the person's PIN and touch happen in the tab's bar, never through an agent.

/// A passkey sign-up for the key: the page's options, checked, with the client data agweb built.
struct KeyCreate: Sendable {
    let clientDataHash: [UInt8]
    let rpID: String, rpName: String
    let userID: [UInt8], userName: String, displayName: String
    /// COSE algorithms in the page's order of preference.
    let algorithms: [Int]
    /// "required", "preferred" or "discouraged".
    let residentKey: String
    /// "required", "preferred" or "discouraged".
    let userVerification: String
    /// "none", "indirect", "direct" or "enterprise".
    let attestation: String
    let exclude: [[UInt8]]
    let timeout: TimeInterval
}

/// A passkey sign-in for the key.
struct KeyGet: Sendable {
    let clientDataHash: [UInt8]
    let rpID: String
    let allow: [[UInt8]]
    let userVerification: String
    /// The FIDO AppID extension's id, already checked against the page's site (U2F-era registrations, such as Google's).
    let appID: String?
    let timeout: TimeInterval
}

struct KeyMade: Sendable {
    let id: [UInt8]
    /// As the key made it, with its own attestation; Passkeys strips it to "none" when the site didn't ask for one.
    let attestationObject: [UInt8]
    let transports: [String]
    /// Whether the key stored it as a discoverable credential, when known.
    let discoverable: Bool?
}

struct KeySigned: Sendable {
    let id: [UInt8], authData: [UInt8], signature: [UInt8]
    let userHandle: [UInt8]?
    /// Signed for the AppID, not the rp id.
    let viaAppID: Bool
}

/// What the page gets: a DOMException name and a message, which also reaches the agent's Events.
struct KeyError: Error, Sendable {
    let name: String, message: String
    init(_ name: String = "NotAllowedError", _ message: String) { (self.name, self.message) = (name, message) }
    static let cancelled = KeyError("NotAllowedError", "the security key request was cancelled")
}

/// The steps the tab's bar shows.
enum KeyStep: Sendable { case insert, touch }

/// The person's side of a ceremony, shown in the tab that asked.
@MainActor protocol KeyUI: AnyObject {
    func show(_ step: KeyStep)
    /// The key's PIN, or nil when the person cancels. `retries`: attempts left, when the key says; `wrong`: the last one was.
    func pin(retries: Int?, wrong: Bool) async -> String?
}

/// The debug log, `<root>/logs/security-key.log` (0600): each step, the key's status codes and
/// what it reported about itself. Never a PIN, a PIN token or a shared secret.
enum KeyLog {
    private static let queue = DispatchQueue(label: "agweb.security-key-log")
    static var file: URL { Agweb.logsFolder.appendingPathComponent("security-key.log") }

    static func write(_ line: String) {
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
                                                     timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let text = "\(stamp) \(line)\n"
        queue.async {
            let url = file
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }

    static func hex(_ bytes: [UInt8], limit: Int = 64) -> String {
        bytes.prefix(limit).map { String(format: "%02x", $0) }.joined() + (bytes.count > limit ? "…(\(bytes.count) bytes)" : "")
    }
}

/// One security key ceremony in one tab: the bar's state and the person's answers. Cancelled by the bar, the page's
/// abort, its next page, the tab or workspace closing, or the time running out.
@MainActor @Observable
final class KeyCeremony: KeyUI {
    enum Phase: Equatable { case insert, touch, pin(retries: Int?, wrong: Bool) }

    private(set) var phase: Phase = .touch
    let site: String, doing: String, workspace: String
    /// The page's origin, whose abort may cancel it.
    @ObservationIgnored let origin: String
    @ObservationIgnored weak var tab: Tab?
    @ObservationIgnored let commits: Int
    @ObservationIgnored let key = CTAPSecurityKey()
    /// Shows the bar again for the new phase.
    @ObservationIgnored var onPhase: (() -> Void)?
    @ObservationIgnored private var pinReply: CheckedContinuation<String?, Never>?
    @ObservationIgnored private(set) var cancelled: (reason: String, quiet: Bool)?

    init(tab: Tab, origin: String, site: String, doing: String) {
        self.tab = tab
        self.origin = origin
        (self.site, self.doing, self.workspace, self.commits) = (site, doing, tab.workspace.name, tab.commits)
    }

    /// Whether the agent's Events have the current step.
    @ObservationIgnored private var told = false

    private func enter(_ next: Phase, event: String) {
        guard cancelled == nil else { return }
        if !told || next != phase { tab?.events.append("security key: " + event) }
        told = true
        phase = next
        KeyLog.write("ceremony: \(next)")
        onPhase?()
    }

    func show(_ step: KeyStep) {
        switch step {
        case .insert: enter(.insert, event: "waiting for the person to plug it in (the tab shows a bar)")
        case .touch: enter(.touch, event: "waiting for the person to touch it (the tab shows a bar)")
        }
    }

    func pin(retries: Int?, wrong: Bool) async -> String? {
        guard cancelled == nil else { return nil }
        enter(.pin(retries: retries, wrong: wrong), event: wrong ? "wrong PIN; waiting for the person to enter it again" : "waiting for the person to enter its PIN in the tab's bar")
        return await withCheckedContinuation { pinReply = $0 }
    }

    func submitPIN(_ pin: String) {
        guard let reply = pinReply else { return }
        pinReply = nil
        enter(.touch, event: "PIN entered; waiting for the person to touch it")
        reply.resume(returning: pin)
    }

    /// `quiet`: the page went away, so the agent's Events don't need it.
    func cancel(_ reason: String, quiet: Bool = false) {
        guard cancelled == nil else { return }
        cancelled = (reason, quiet)
        KeyLog.write("ceremony: cancelled: \(reason)")
        pinReply?.resume(returning: nil)
        pinReply = nil
        key.cancel()
    }
}
