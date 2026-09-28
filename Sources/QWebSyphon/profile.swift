import Foundation

// Parses `--profile <name>` from the command line (falling back to the SYPHONWEB_PROFILE env var)
// so `open -n SyphonWeb.app --args --profile NAME` can run multiple isolated instances. A valid
// name is used to pick a separate UserDefaults suite and Syphon server name; an invalid one is
// logged and treated as no profile (default/`.standard`).
private let profileNameAllowedChars = Set(
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

private func parseProfileName() -> String? {
  let arguments = CommandLine.arguments
  if let flagIndex = arguments.firstIndex(of: "--profile"), arguments.indices.contains(flagIndex + 1) {
    return arguments[flagIndex + 1]
  }
  return ProcessInfo.processInfo.environment["SYPHONWEB_PROFILE"]
}

let profileName: String? = {
  guard let candidate = parseProfileName() else { return nil }
  guard !candidate.isEmpty, candidate.allSatisfy(profileNameAllowedChars.contains) else {
    appLog("Ignoring invalid --profile \"\(candidate)\" (must match ^[A-Za-z0-9_-]+$)")
    return nil
  }
  return candidate
}()

// Settings storage for this launch: a per-profile suite when `--profile` is valid, else `.standard`.
// Bookmarks (in the shared SQLite DB) are not affected by this and stay shared across profiles.
nonisolated(unsafe) let appDefaults: UserDefaults = {
  guard let profileName else { return .standard }
  guard let suite = UserDefaults(suiteName: "SyphonWeb.profile.\(profileName)") else {
    appLog("Could not open UserDefaults suite for profile \"\(profileName)\", using standard")
    return .standard
  }
  return suite
}()

// NSLog treats its first argument as a format string, so interpolated URLs or OSC addresses
// containing "%" would be read as format specifiers (garbled output or a crash). Always log
// through "%@".
func appLog(_ message: String) {
  NSLog("%@", message)
}
