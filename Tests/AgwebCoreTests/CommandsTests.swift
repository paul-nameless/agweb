import Testing
@testable import AgwebCore

@Test(arguments: [("tabs", "tab-list"), ("switch-tab", "tab-select"), ("snapshto", "snapshot"), ("network", "requests"), ("sleep", "wait")])
func unknownCommandsSuggestTheRealOne(guess: String, real: String) {
    #expect(Commands.unknown(guess).hasSuffix("did you mean \(real)?"))
}

@Test func farOffNamesGetHelp() {
    #expect(Commands.unknown("frobnicate") == "unknown command 'frobnicate'; run agweb help")
    #expect(Commands.unknown("run-code").contains("no Playwright engine"))
}
