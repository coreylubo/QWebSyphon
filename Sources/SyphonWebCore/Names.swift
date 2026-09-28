import Foundation

// The OSC slug rule (spec "OSC" section, reused here since output names ARE the slugs): only
// letters, numbers, `-` and `_`, non-empty, at most 64 characters, and not all-digits (an
// all-digit name would collide with the 1-based OSC index). Doesn't check reserved words or
// uniqueness — those are separate concerns (`validateOutputName`). Used by the UI to show a
// "rename to address by name over OSC" hint on grandfathered pre-slug names, and by the OSC route
// resolver for the same rule.
public func isOSCAddressableName(_ name: String) -> Bool {
  guard !name.isEmpty, name.count <= 64, !name.allSatisfy(\.isNumber) else { return false }
  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
  return name.allSatisfy(allowed.contains)
}

// Pure check for a rename/add/duplicate: trimmed, matches the OSC slug rule, not one of the
// reserved command words, and unique case-insensitively among `existing` (the OTHER outputs'
// names — the caller excludes the output being renamed). Returns an error message, or nil if
// `name` is valid as-is. Pre-slug names loaded from disk (e.g. "SyphonWeb left") are grandfathered
// in `sanitizeOutputConfigs`/migration, which never call this — it only gates NEW names.
public func validateOutputName(_ name: String, existing: [String]) -> String? {
  let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "Name can't be empty" }
  if !isOSCAddressableName(trimmed) {
    return "Names may only contain letters, numbers, - and _, up to 64 characters, and can't be only numbers"
  }
  if reservedOutputNames.contains(trimmed.lowercased()) {
    return "\"\(trimmed)\" is a reserved name"
  }
  if existing.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
    return "An output named \"\(trimmed)\" already exists"
  }
  return nil
}

// `base` if it doesn't collide (case-insensitively) with anything in `existing`, else
// "<base>-2", "<base>-3", ... until one doesn't. Hyphenated (not space-separated) so a unique
// default/duplicate name is always OSC-addressable when `base` already is.
public func uniqueOutputName(base: String, existing: [String]) -> String {
  let existingLower = Set(existing.map { $0.lowercased() })
  guard existingLower.contains(base.lowercased()) else { return base }
  var suffix = 2
  while existingLower.contains("\(base)-\(suffix)".lowercased()) { suffix += 1 }
  return "\(base)-\(suffix)"
}

// Replaces every character outside the OSC slug alphabet with "-". Used by the app's
// `defaultOutputBaseName()` so newly generated output names are always OSC-addressable, regardless
// of profile name.
public func slugForOutputName(_ name: String) -> String {
  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
  return String(name.map { allowed.contains($0) ? $0 : "-" })
}
