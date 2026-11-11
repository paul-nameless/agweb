import Foundation
import Testing
import AgwebCore

private func entry(_ command: String, _ args: [String], _ options: [String: String] = [:], ok: Bool = true, output: String = "") throws -> [String: Any] {
    let line = CommandLog.line(Request(workspace: "w", command: command, args: args, options: options), ok: ok, output: output,
                               at: Date(timeIntervalSince1970: 0), seconds: 1.5)
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

@Test func commandLogKeepsTypedTextOut() throws {
    #expect(try entry("fill", ["e7", "hunter2"], ["secret": ""])["args"] as? [String] == ["e7", "<hidden>"])
    #expect(try entry("eval", ["document.cookie"])["args"] as? [String] == ["<hidden>"])
    #expect(try entry("route", ["**/api"], ["header": "Authorization: Bearer x", "status": "500"])["options"] as? [String: String]
        == ["header": "<hidden>", "status": "500"])
    #expect(try entry("goto", ["https://a.test/login?token=abc#x"])["args"] as? [String] == ["https://a.test/login?…"])
}

@Test func commandLogRecordsTheOutcome() throws {
    let failed = try entry("click", ["e3"], ok: false, output: "Error: ref e3 not found\nmore")
    #expect(failed["error"] as? String == "Error: ref e3 not found")
    #expect(failed["ms"] as? Int == 1500)
    #expect(try entry("snapshot", [])["error"] == nil)
}
