import Testing

@testable import SyphonWebCore

// New coverage for `normalizedURL` (no prior DEBUG self-check existed for it; moved from
// `Output.normalizedURL` in the app's `webView.swift`, which now forwards here).
@Suite struct URLTests {

  @Test func emptyOrWhitespaceIsNil() {
    #expect(normalizedURL("") == nil)
    #expect(normalizedURL("   ") == nil)
  }

  @Test func trimsSurroundingWhitespace() {
    #expect(normalizedURL("  https://example.com  ")?.absoluteString == "https://example.com")
  }

  @Test func keepsExplicitScheme() {
    #expect(normalizedURL("https://example.com")?.absoluteString == "https://example.com")
    #expect(normalizedURL("http://example.com")?.absoluteString == "http://example.com")
    #expect(normalizedURL("ftp://example.com")?.scheme == "ftp")
  }

  @Test func keepsSchemeOnlyForms() {
    #expect(normalizedURL("about:blank")?.absoluteString == "about:blank")
    #expect(normalizedURL("data:text/plain,hi")?.scheme == "data")
    #expect(normalizedURL("javascript:void(0)")?.scheme == "javascript")
    #expect(normalizedURL("blob:abc")?.scheme == "blob")
  }

  @Test func protocolRelativeBorrowsHTTPS() {
    #expect(normalizedURL("//example.com/path")?.absoluteString == "https://example.com/path")
  }

  @Test func localHostsGetHTTP() {
    #expect(normalizedURL("localhost:3000")?.scheme == "http")
    #expect(normalizedURL("127.0.0.1:3000")?.scheme == "http")
    #expect(normalizedURL("mymachine.local")?.scheme == "http")
  }

  @Test func remoteHostsGetHTTPS() {
    #expect(normalizedURL("example.com")?.scheme == "https")
    #expect(normalizedURL("example.com/path")?.scheme == "https")
  }

  @Test func hostWithoutSchemeDoesNotMisreadItsOwnQueryString() {
    // "example.com/?next=https://x" has no scheme of its own — the embedded "https://" in the
    // query string must not be mistaken for the host's scheme.
    #expect(normalizedURL("example.com/?next=https://x")?.scheme == "https")
  }
}
