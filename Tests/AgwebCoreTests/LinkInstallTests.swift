import Foundation
import Testing
import AgwebCore

private func scratch() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agweb-link-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Test func linkStateTellsOursFromTheirs() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    #expect(LinkInstall.state(at: "\(dir)/none") == .missing)
    try fm.createSymbolicLink(atPath: "\(dir)/ours", withDestinationPath: "/Applications/Agweb.app/Contents/Helpers/agweb")
    #expect(LinkInstall.state(at: "\(dir)/ours") == .ours(target: "/Applications/Agweb.app/Contents/Helpers/agweb"))
    try fm.createSymbolicLink(atPath: "\(dir)/dev", withDestinationPath: "/tmp/checkout/bin/agweb")
    #expect(LinkInstall.state(at: "\(dir)/dev") == .foreign("a link to /tmp/checkout/bin/agweb"))
    try Data().write(to: URL(fileURLWithPath: "\(dir)/file"))
    #expect(LinkInstall.state(at: "\(dir)/file") == .foreign("a file"))
    try fm.createDirectory(atPath: "\(dir)/folder", withIntermediateDirectories: false)
    #expect(LinkInstall.state(at: "\(dir)/folder") == .foreign("a folder"))
}

@Test func transientBundlesAreRefused() {
    #expect(LinkInstall.isTransient(bundle: "/private/var/folders/x/T/AppTranslocation/ABC/d/Agweb.app"))
    #expect(LinkInstall.isTransient(bundle: "/Volumes/Agweb/Agweb.app"))
    #expect(!LinkInstall.isTransient(bundle: "/Applications/Agweb.app"))
    #expect(CLILink.install(helper: "/Volumes/Agweb/Agweb.app/Contents/Helpers/agweb", bundle: "/Volumes/Agweb/Agweb.app") == .transient)
}

@Test func cliLinkReplacesOnlyItsOwn() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(atPath: dir); unsetenv("AGWEB_CLI_LINK") }
    setenv("AGWEB_CLI_LINK", "\(dir)/bin/agweb", 1)
    let old = "/old/Agweb.app/Contents/Helpers/agweb", new = "/Applications/Agweb.app/Contents/Helpers/agweb"
    #expect(CLILink.install(helper: old, bundle: "/old/Agweb.app") == .linked)
    #expect(CLILink.install(helper: new, bundle: "/Applications/Agweb.app") == .linked)
    #expect(LinkInstall.state(at: "\(dir)/bin/agweb") == .ours(target: new))
    #expect(CLILink.status(helper: new) == "installed at \(dir)/bin/agweb")

    try FileManager.default.removeItem(atPath: "\(dir)/bin/agweb")
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/bin/agweb", withDestinationPath: "/tmp/checkout/bin/agweb")
    #expect(CLILink.install(helper: new, bundle: "/Applications/Agweb.app") == .foreign("a link to /tmp/checkout/bin/agweb"))
    #expect(CLILink.install(helper: new, bundle: "/Applications/Agweb.app", replacingForeign: true) == .linked)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: "\(dir)/bin")
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(dir)/bin") }
    #expect(CLILink.install(helper: old, bundle: "/old/Agweb.app") == .noPermission)
    #expect(CLILink.shellCommand(helper: "/It's/Agweb.app/Contents/Helpers/agweb")
        == "mkdir -p '\(dir)/bin' && ln -sfn '/It'\\''s/Agweb.app/Contents/Helpers/agweb' '\(dir)/bin/agweb'")
}
