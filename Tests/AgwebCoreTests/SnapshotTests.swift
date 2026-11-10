import Testing
import AgwebCore

private let page = """
- navigation "Main" [ref=e1]
  - link "Home" [ref=e2]
- main [ref=e3]
  - form [ref=e4]
    - textbox "Email" [ref=e5]
    - button "Save" [ref=e6]
"""

@Test func diffShowsChangesUnderTheirParents() throws {
    let after = page.replacingOccurrences(of: "    - button \"Save\" [ref=e6]", with: "    - button \"Saving\" [ref=e6] [disabled]\n    - text: \"Saved\"")
    let diff = try #require(Snapshot.diff(from: page, to: after))
    #expect(diff == """
          - main [ref=e3]
            - form [ref=e4]
        -     - button "Save" [ref=e6]
        +     - button "Saving" [ref=e6] [disabled]
        +     - text: "Saved"
        """)
}

@Test func diffOfTheSameTreeIsNil() {
    #expect(Snapshot.diff(from: page, to: page) == nil)
}

@Test func findKeepsTheEnclosingLines() throws {
    let found = try #require(Snapshot.find("save", in: page, max: 20))
    #expect(found.matches == 1)
    #expect(found.tree == """
        - main [ref=e3]
          - form [ref=e4]
            - button "Save" [ref=e6]
        """)
}

@Test func findCapsItsMatches() throws {
    let found = try #require(Snapshot.find("ref=e", in: page, max: 2))
    #expect(found.matches == 6)
    #expect(found.tree.hasSuffix("- (4 more; --max-results to see them)"))
    #expect(Snapshot.find("nothing", in: page, max: 2) == nil)
}
