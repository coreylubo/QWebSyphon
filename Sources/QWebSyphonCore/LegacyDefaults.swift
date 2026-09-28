import Foundation

// One-time copy of settings from the pre-rename SyphonWeb defaults domains. Old domains are only
// ever read, never modified or deleted, so the old app keeps working and rollback is free.

// Set in the new domain once the copy has run (value: the source domain, or "" if none had data).
public let legacyDefaultsMarkerKey = "migratedFromSyphonWeb"

// Old domains to copy from, in preference order; the first with any data wins. The bundled app's
// standard domain was its bundle id, `swift run`'s was the executable name.
public func legacyDefaultsDomains(profile: String?, isBundled: Bool) -> [String] {
  if let profile { return ["SyphonWeb.profile.\(profile)"] }
  return isBundled ? ["surf.puppy.SyphonWeb", "SyphonWeb"] : ["SyphonWeb", "surf.puppy.SyphonWeb"]
}

// Keys of `old` absent from `new` (never overwrites; never copies a stale marker).
public func legacyDefaultsToCopy(old: [String: Any], new: [String: Any]) -> [String: Any] {
  old.filter { key, _ in new[key] == nil && key != legacyDefaultsMarkerKey }
}

// Runs the copy into `defaults` unless its marker is already set. `read` returns an old domain's
// persistent dictionary (`UserDefaults.standard.persistentDomain(forName:)` in the app). "Already
// present" is judged against `defaults.dictionaryRepresentation()`, which also includes the global
// domain: a key set there is never copied, so nothing visible to the new app is ever overwritten.
// ponytail: an old per-app override of a global key (e.g. AppleLanguages) is not carried over.
// Returns the source domain copied from ("" if no old domain had data), nil if the marker was set.
@discardableResult
public func migrateLegacyDefaults(
  into defaults: UserDefaults, legacyDomains: [String],
  read: (String) -> [String: Any]?, log: (String) -> Void = { _ in }
) -> String? {
  guard defaults.object(forKey: legacyDefaultsMarkerKey) == nil else { return nil }
  let source = legacyDomains.first { !(read($0) ?? [:]).isEmpty }
  if let source {
    let toCopy = legacyDefaultsToCopy(
      old: read(source) ?? [:], new: defaults.dictionaryRepresentation())
    for (key, value) in toCopy { defaults.set(value, forKey: key) }
    log("Copied \(toCopy.count) settings from \(source) (source left untouched)")
  }
  defaults.set(source ?? "", forKey: legacyDefaultsMarkerKey)
  return source ?? ""
}
