import AgwebCore
import Foundation
import WebAuthnSPI

/// The key through WebKit's own CTAP2 and U2F client (`_WKWebAuthenticationPanel`), with none of its UI: WebKit finds
/// the key, waits for it to be plugged in, and asks agweb for the PIN.
@MainActor
final class WebKitSecurityKey: SecurityKeyBackend {
    private let panel = AGWKeyPanel()
    private var pinWrong = false
    /// What a panel update said went wrong. WebKit only reports it there and keeps looking for a key, so the ceremony is
    /// cancelled and this is what the page gets.
    private var failed: KeyError?

    static var missing: String? { AGWKeyPanel.missing() }

    private static func requirement(_ text: String) -> Int {
        switch text { case "required": 0; case "discouraged": 2; default: 1 }
    }

    private func wire(_ ui: KeyUI) {
        pinWrong = false
        failed = nil
        panel.onLog = { KeyLog.write($0) }
        panel.onUpdate = { [weak self] update in
            guard let self else { return }
            // _WKWebAuthenticationPanelUpdate; -1 is AGWKeyPanel's own: WebKit wanted to set the key's first PIN.
            switch update {
            case 4, 9, 10: pinWrong = true // PIN invalid, too short, too long: WebKit asks again
            case 1: fail(KeyError("NotAllowedError", "the security key has no passkey for this site"))
            case 2: fail(KeyError("NotAllowedError", "the security key's PIN is blocked; only resetting the key unblocks it"))
            case 3: fail(KeyError("NotAllowedError", "too many wrong PINs; unplug the security key and plug it in again"))
            case 8: fail(KeyError("NotAllowedError", "the security key is full; delete a passkey on it (ykman fido credentials delete)"))
            case -1: fail(KeyError("NotAllowedError", "the site needs a PIN on the security key, and it has none; set one with ykman fido access change-pin"))
            default: break
            }
        }
        panel.onPIN = { [weak self, weak ui] retries, reply in
            Task { @MainActor in
                let wrong = self?.pinWrong ?? false
                self?.pinWrong = false
                let pin = await ui?.pin(retries: retries == NSNotFound ? nil : retries, wrong: wrong)
                reply(pin)
            }
        }
        ui.show(.touch)
    }

    private func fail(_ error: KeyError) {
        guard failed == nil else { return }
        failed = error
        KeyLog.write("webkit: giving up: \(error.message)")
        panel.cancel()
    }

    private static func failure(_ error: Error?) -> KeyError {
        let error = error as NSError?
        KeyLog.write("webkit: failed: domain \(error?.domain ?? "-") code \(error?.code ?? 0) \(error?.localizedDescription ?? "no error") \(error?.userInfo ?? [:])")
        return KeyError("NotAllowedError", "WebKit's security key client: \(error?.localizedDescription ?? "no response")")
    }

    func create(_ request: KeyCreate, _ ui: KeyUI) async throws -> KeyMade {
        wire(ui)
        let residentKey = switch request.residentKey { case "required": 1; case "preferred": 2; default: 3 }
        let attestation = switch request.attestation { case "indirect": 1; case "direct": 2; case "enterprise": 3; default: 0 }
        return try await withCheckedThrowingContinuation { done in
            panel.makeCredential(hash: Data(request.clientDataHash), rpID: request.rpID, rpName: request.rpName, userID: Data(request.userID),
                                 userName: request.userName, displayName: request.displayName, algorithms: request.algorithms.map { NSNumber(value: $0) },
                                 residentKey: residentKey, userVerification: Self.requirement(request.userVerification), attestation: attestation,
                                 exclude: request.exclude.map { Data($0) }, timeout: request.timeout) { rawId, attestationObject, transports, error in
                guard let rawId, let attestationObject else { return done.resume(throwing: self.failed ?? Self.failure(error)) }
                KeyLog.write("webkit: made credential \(rawId.count) bytes, attestationObject \(attestationObject.count) bytes, transports \(transports ?? [])")
                // _WKWebAuthenticationTransport: usb, nfc, ble, internal, cable, hybrid, smart-card.
                let known = ["usb", "nfc", "ble", "internal", "cable", "hybrid", "smart-card"]
                let names = (transports ?? []).compactMap { known.indices.contains($0.intValue) ? known[$0.intValue] : nil }
                done.resume(returning: KeyMade(id: [UInt8](rawId), attestationObject: [UInt8](attestationObject), transports: names.isEmpty ? ["usb"] : names,
                                               discoverable: request.residentKey == "required" ? true : nil))
            }
        }
    }

    func get(_ request: KeyGet, _ ui: KeyUI) async throws -> KeySigned {
        wire(ui)
        return try await withCheckedThrowingContinuation { done in
            panel.getAssertion(hash: Data(request.clientDataHash), rpID: request.rpID, allow: request.allow.map { Data($0) },
                               userVerification: Self.requirement(request.userVerification), appID: request.appID, timeout: request.timeout) { rawId, authData, signature, userHandle, extensions, error in
                guard let rawId, let authData, let signature else { return done.resume(throwing: self.failed ?? Self.failure(error)) }
                let outputs = extensions.flatMap { CBOR.decode([UInt8]($0)) }
                KeyLog.write("webkit: signed with credential \(rawId.count) bytes, authData \(authData.count) bytes, userHandle \(userHandle?.count ?? 0) bytes, extensions \(extensions.map { KeyLog.hex([UInt8]($0)) } ?? "none")")
                done.resume(returning: KeySigned(id: [UInt8](rawId), authData: [UInt8](authData), signature: [UInt8](signature),
                                                 userHandle: userHandle.map { [UInt8]($0) }, viaAppID: outputs?["appid"]?.bool ?? false))
            }
        }
    }

    func cancel() { panel.cancel() }
}
