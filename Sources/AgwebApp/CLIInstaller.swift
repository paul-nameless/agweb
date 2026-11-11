import AgwebCore
import AppKit

/// Links /usr/local/bin/agweb to the CLI in this bundle; see `CLILink`.
@MainActor
enum CLIInstaller {
    static var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agweb").path }

    static var status: String { CLILink.status(helper: helper) }

    /// What happened, in a sentence. A root-owned folder gets one administrator prompt; cancelling it returns nil.
    static func install(replacingForeign: Bool = false) -> String? {
        let outcome = CLILink.install(helper: helper, bundle: Bundle.main.bundlePath, replacingForeign: replacingForeign)
        guard outcome == .noPermission else { return CLILink.describe(outcome, helper: helper) }
        let command = CLILink.shellCommand(helper: helper)
        let quoted = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(quoted) with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return CLILink.describe(.linked, helper: helper) }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return nil }
        return CLILink.describe(.failed(error[NSAppleScript.errorMessage] as? String ?? "authorization failed"), helper: helper)
    }

    /// At launch: a link of ours that leads nowhere (the app moved) is pointed here. Nothing new is added.
    static func repair() {
        guard case .ours(let target) = LinkInstall.state(at: CLILink.path), target != helper, LinkInstall.isBroken(target) else { return }
        _ = CLILink.install(helper: helper, bundle: Bundle.main.bundlePath)
    }

    /// Help ▸ Install Command Line Tool and Settings: asks before replacing something else, then says what happened.
    static func runWithAlert() {
        var replace = false
        if case .foreign(let what) = LinkInstall.state(at: CLILink.path) {
            guard alert("\(CLILink.path) is \(what), not agweb's. Replace it with a link to this agweb?", buttons: ["Cancel", "Replace"]) == .alertSecondButtonReturn else { return }
            replace = true
        }
        if let result = install(replacingForeign: replace) { alert(result, buttons: ["OK"]) }
    }

    @discardableResult
    private static func alert(_ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Command Line Tool"
        alert.informativeText = text
        // The default button is the safe one.
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
