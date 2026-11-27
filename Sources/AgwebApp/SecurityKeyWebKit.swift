import AgwebCore
import Foundation
import WebAuthnSPI

/// The key through WebKit's own CTAP2 and U2F client (`_WKWebAuthenticationPanel`), with none of its UI: WebKit finds
/// the key, waits for it to be plugged in, and asks agweb for the PIN.
@MainActor
final class WebKitSecurityKey: SecurityKeyBackend {
    private let panel = AGWKeyPanel()
    private var pinWrong = false

    static var missing: String? { AGWKeyPanel.missing() }

    private static func requirement(_ text: String) -> Int {
        switch text { case "required": 0; case "discouraged": 2; default: 1 }
    }

    private func wire(_ ui: KeyUI) {
        pinWrong = false
        panel.onLog = { KeyLog.write($0) }
        panel.onUpdate = { [weak self] update in if update == 4 { self?.pinWrong = true } }
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
                guard let rawId, let attestationObject else { return done.resume(throwing: Self.failure(error)) }
                KeyLog.write("webkit: made credential \(rawId.count) bytes, attestationObject \(attestationObject.count) bytes, transports \(transports ?? [])")
                // _WKWebAuthenticationTransport: 0 usb, 1 nfc, 2 internal, 3 ble?, the rest unknown here.
                let names = (transports ?? []).compactMap { ["usb", "nfc", "internal", "ble"].indices.contains($0.intValue) ? ["usb", "nfc", "internal", "ble"][$0.intValue] : nil }
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
                guard let rawId, let authData, let signature else { return done.resume(throwing: Self.failure(error)) }
                let outputs = extensions.flatMap { CBOR.decode([UInt8]($0)) }
                KeyLog.write("webkit: signed with credential \(rawId.count) bytes, authData \(authData.count) bytes, userHandle \(userHandle?.count ?? 0) bytes, extensions \(extensions.map { KeyLog.hex([UInt8]($0)) } ?? "none")")
                done.resume(returning: KeySigned(id: [UInt8](rawId), authData: [UInt8](authData), signature: [UInt8](signature),
                                                 userHandle: userHandle.map { [UInt8]($0) }, viaAppID: outputs?["appid"]?.bool ?? false))
            }
        }
    }

    func cancel() { panel.cancel() }
}
