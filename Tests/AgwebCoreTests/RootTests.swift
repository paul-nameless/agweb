import Foundation
import Testing
import AgwebCore

private let home = URL(fileURLWithPath: "/Users/someone")
private let personal = "/Users/someone/Library/Application Support/agweb"

@Test(arguments: [nil, "", personal, personal + "/", personal + "/.", "/Users/someone/Library/../Library/Application Support/agweb"])
func theDefaultRootIsThePersons(_ value: String?) {
    let resolved = Agweb.resolveRoot(value, home: home)
    #expect(resolved.isDefault)
    #expect(resolved.root.path == personal)
}

@Test func anotherRootIsKeptAsGiven() throws {
    let resolved = Agweb.resolveRoot("/tmp/agw-fix/", home: home)
    #expect(!resolved.isDefault)
    #expect(resolved.root.path == "/tmp/agw-fix")
    #expect(Agweb.settingsSuite(root: resolved.root) == "agweb.root_tmp_agw-fix")
}

@Test func aLinkToThePersonsRootIsThePersons() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agweb-root-\(UUID().uuidString)")
    let real = dir.appendingPathComponent("Library/Application Support/agweb")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(Agweb.resolveRoot(link.path, home: dir).isDefault)
}

@Test func onlyTestBuildsAreTestBuilds() {
    #expect(Agweb.isTestBuild("com.reacsdas.agweb.test"))
    #expect(!Agweb.isTestBuild("com.reacsdas.agweb"))
}
