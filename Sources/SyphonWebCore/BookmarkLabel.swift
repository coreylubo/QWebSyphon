import Foundation

// Validates a raw OSC label. Empty (after trimming) means no label. Labels are [A-Za-z0-9_-],
// not all digits (numbers select by sidebar position), and unique case-insensitively.
public func validateBookmarkLabel(
  _ raw: String, existing: [(id: Int64, label: String?)], excludingId: Int64?
) -> (label: String?, error: String?) {
  let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if label.isEmpty { return (nil, nil) }

  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
  if !label.allSatisfy(allowed.contains) {
    return (nil, "Labels may only contain letters, numbers, - and _")
  }
  if label.allSatisfy(\.isNumber) {
    return (nil, "Labels can't be numbers (numbers select by sidebar position)")
  }
  let taken = existing.contains {
    $0.id != excludingId && $0.label?.caseInsensitiveCompare(label) == .orderedSame
  }
  if taken { return (nil, "Label already used") }

  return (label, nil)
}

// Validates the whole editor form: name and URL required, then the label.
public func validateBookmarkFields(
  name: String, url: String, label: String, existing: [(id: Int64, label: String?)],
  excludingId: Int64?
) -> (label: String?, error: String?) {
  if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, "Name is required") }
  if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, "URL is required") }
  return validateBookmarkLabel(label, existing: existing, excludingId: excludingId)
}
