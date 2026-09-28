import Foundation

// Trims and adds http(s):// when there is no scheme. Shared so bookmark URLs compare equal to an
// output's `url`. `Output.normalizedURL` (the app's `webView.swift`) forwards to this.
public func normalizedURL(_ string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  // Protocol-relative ("//example.com/path"): borrow https
  if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
  // Only strings starting with "<scheme>://" or a known scheme-only form keep their scheme. "localhost:3000"
  // would otherwise parse with scheme "localhost", and "127.0.0.1:3000" not at all.
  let lower = trimmed.lowercased()
  // Anchored at the start: "example.com/?next=https://x" has no scheme of its own
  let keepsScheme =
    trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
    || ["about:", "data:", "javascript:", "blob:"].contains { lower.hasPrefix($0) }
  if keepsScheme { return URL(string: trimmed) }
  // Local dev servers rarely have TLS: localhost and IPv4 literals get http, the rest https.
  let host = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
  let hostname = host.split(separator: ":").first.map(String.init) ?? host
  let isLocal =
    hostname == "localhost" || hostname.hasSuffix(".local")
    || hostname.split(separator: ".").count == 4
      && hostname.split(separator: ".").allSatisfy { UInt8($0) != nil }
  return URL(string: (isLocal ? "http://" : "https://") + trimmed)
}
