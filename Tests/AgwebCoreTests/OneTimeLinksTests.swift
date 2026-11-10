import Foundation
import Testing
@testable import AgwebCore

@Test(arguments: ["https://app.example/deploy?autoload=1&token=abc", "https://app.example/cb?code=x&state=y",
                  "https://app.example/#access_token=t", "https://app.example/?authToken=1"])
func oneTimeLinksAreRecognised(url: String) {
    #expect(OneTimeLinks.contains(URL(string: url)!))
}

@Test(arguments: ["https://en.wikipedia.org/wiki/WebKit", "https://github.com/x/y/issues?q=is%3Aopen", "https://app.example/#section", "https://github.com/x/y/issues?state=closed", "https://docs.example/?code=swift"])
func ordinaryLinksAreNot(url: String) {
    #expect(!OneTimeLinks.contains(URL(string: url)!))
}
