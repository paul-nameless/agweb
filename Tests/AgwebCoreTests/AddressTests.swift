import Foundation
import Testing
import AgwebCore

@Test(arguments: [
    ("example.com", "https://example.com"),
    ("example.com/a?b=1", "https://example.com/a?b=1"),
    ("https://example.com", "https://example.com"),
    ("about:blank", "about:blank"),
    ("localhost:3000/x", "http://localhost:3000/x"),
    ("app.localhost:5173", "http://app.localhost:5173"),
    ("192.168.1.5:8080", "http://192.168.1.5:8080"),
    ("printer.local", "http://printer.local"),
    ("[::1]:8080", "http://[::1]:8080"),
    ("  example.com  ", "https://example.com"),
])
func typedAddresses(text: String, expected: String) throws {
    #expect(try Address.url(text).absoluteString == expected)
}

@Test func absolutePathIsAFile() throws {
    let url = try Address.url("/tmp/page.html")
    #expect(url.isFileURL && url.path == "/tmp/page.html")
}

@Test(arguments: ["", "   "])
func emptyIsRejected(text: String) {
    #expect(throws: Failure.self) { try Address.url(text) }
}
