import Foundation
import Testing
import AgwebCore

let evalReply = "### Result\n\"a\\nb\"\n### Page\n- URL: https://example.com/\n- Title: Example"

@Test func rawIsTheAnswerWithStringsUnquoted() {
    #expect(Output.raw(evalReply) == "a\nb")
    #expect(Output.raw("### Result\n{\"n\":1}\n### Page\n- URL: x") == "{\"n\":1}")
    #expect(Output.raw("### Page\n- URL: x\n### Tabs\n- 0: a") == "")
    #expect(Output.raw("no workspaces") == "no workspaces")
}

@Test func headingsInAnAnswerAreContent() {
    let article = "### Result\n# Title\n\nIntro\n\n### Overview\nMore\n### Page\n- URL: x"
    #expect(Output.raw(article) == "# Title\n\nIntro\n\n### Overview\nMore")
}

@Test func jsonParsesSections() throws {
    let object = try #require(JSONSerialization.jsonObject(with: Data(Output.json(evalReply, ok: true).utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    #expect(object["result"] as? String == "a\nb")
    #expect(object["page"] as? [String: String] == ["url": "https://example.com/", "title": "Example"])
}

@Test func jsonPassesObjectsThroughAndReportsErrors() throws {
    #expect(Output.json("{\"workspaces\":[]}", ok: true) == "{\"workspaces\":[]}")
    let error = try #require(JSONSerialization.jsonObject(with: Data(Output.json("Error: boom", ok: false).utf8)) as? [String: Any])
    #expect(error["ok"] as? Bool == false && error["error"] as? String == "boom")
}
