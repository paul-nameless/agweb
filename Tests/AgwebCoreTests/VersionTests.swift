import Testing
@testable import AgwebCore

@Test(arguments: [("0.10.0", "0.9.1", true), ("v0.3.1", "0.3.0", true), ("0.3.0", "v0.3.0", false), ("0.3", "0.3.0", false),
                  ("0.3.0.1", "0.3.0", true), ("0.2.9", "0.3.0", false), ("1.0.0", "0.99.99", true)])
func versionsCompareAsNumbers(a: String, b: String, newer: Bool) {
    #expect(Version.isNewer(a, than: b) == newer)
}
