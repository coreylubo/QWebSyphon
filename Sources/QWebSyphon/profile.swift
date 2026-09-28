import Foundation
import QWebSyphonCore

// Reads `QWEBSYPHON_<suffix>`, falling back to the pre-rename `SYPHONWEB_<suffix>`. Empty = unset.
func appEnvironment(_ suffix: String) -> String? {
  let environment = ProcessInfo.processInfo.environment
  return ["QWEBSYPHON_\(suffix)", "SYPHONWEB_\(suffix)"].lazy.compactMap { environment[$0] }
    .first { !$0.isEmpty }
}

// Parses `--profile <name>` from the command line (falling back to the QWEBSYPHON_PROFILE, then
// SYPHONWEB_PROFILE, env var) so `open -n QWebSyphon.app --args --profile NAME` can run multiple
// isolated instances. A valid name is used to pick a separate UserDefaults suite and Syphon server
// name; an invalid one is logged and treated as no profile (default/`.standard`).
private let profileNameAllowedChars = Set(
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

private func parseProfileName() -> String? {
  let arguments = CommandLine.arguments
  if let flagIndex = arguments.firstIndex(of: "--profile"), arguments.indices.contains(flagIndex + 1) {
    return arguments[flagIndex + 1]
  }
  return appEnvironment("PROFILE")
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
// Before first use, copies the pre-rename SyphonWeb settings in once (see `migrateLegacyDefaults`);
// main.swift touches this first thing so nothing reads settings before the copy.
nonisolated(unsafe) let appDefaults: UserDefaults = {
  var defaults = UserDefaults.standard
  var suiteProfile: String?
  if let profileName {
    if let suite = UserDefaults(suiteName: "QWebSyphon.profile.\(profileName)") {
      (defaults, suiteProfile) = (suite, profileName)
    } else {
      appLog("Could not open UserDefaults suite for profile \"\(profileName)\", using standard")
    }
  }
  migrateLegacyDefaults(
    into: defaults,
    legacyDomains: legacyDefaultsDomains(
      profile: suiteProfile, isBundled: Bundle.main.bundleIdentifier != nil),
    read: UserDefaults.standard.persistentDomain(forName:), log: appLog)
  return defaults
}()

// NSLog treats its first argument as a format string, so interpolated URLs or OSC addresses
// containing "%" would be read as format specifiers (garbled output or a crash). Always log
// through "%@".
func appLog(_ message: String) {
  NSLog("%@", message)
}
