import Combine
import SQLite
import SwiftUI

@available(macOS 14, *)
@Observable
class Bookmark: Identifiable, Hashable {

  public var id: Int64
  public var url: String
  public var name: String
  public var order: Int64
  public var favorite: Bool
  public var label: String?

  internal init(
    id: Int64, url: String, name: String, order: Int64, favorite: Bool, label: String? = nil
  ) {
    self.id = id
    self.url = url
    self.name = name
    self.order = order
    self.favorite = favorite
    self.label = label
  }

  internal init(fromRowElement: RowIterator.Element) {
    let id = SQLite.Expression<Int64>("id")
    let order = SQLite.Expression<Int64>("order")
    let name = SQLite.Expression<String>("name")
    let url = SQLite.Expression<String>("url")
    let favorite = SQLite.Expression<Bool>("favorite")

    do {
      try self.id = fromRowElement.get(id)
      try self.url = fromRowElement.get(url)
      try self.name = fromRowElement.get(name)
      try self.order = fromRowElement.get(order)
      try self.favorite = fromRowElement.get(favorite)
    } catch {
      appLog("Error create bookmark object from DB!")
      self.id = -1
      self.url = "about:blank"
      self.name = "<Invalid>"
      self.order = -1
      self.favorite = false
    }

    // Read separately: the column is absent if the label migration couldn't run
    self.label = (try? fromRowElement.get(SQLite.Expression<String?>("label"))) ?? nil
  }

  // Hashable
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(self.id)
    hasher.combine(self.url)
    hasher.combine(self.name)
    hasher.combine(self.order)
    hasher.combine(self.favorite)
    hasher.combine(self.label)
  }

  // Equality and sorting
  static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
    lhs.id == rhs.id
  }

  static func > (lhs: Bookmark, rhs: Bookmark) -> Bool {
    lhs.order > rhs.order
  }

  static func < (lhs: Bookmark, rhs: Bookmark) -> Bool {
    lhs.order < rhs.order
  }

  public func toggleFavorite() {
    let bookmarks = Table("bookmarks")
    let id = SQLite.Expression<Int64>("id")
    let favorite = SQLite.Expression<Bool>("favorite")
    let mrk = bookmarks.filter(id == self.id)

    self.favorite = !self.favorite
    let query = mrk.update(favorite <- self.favorite)

    do {
      try databaseConn!.run(query)
      postBookmarksDidChange()
    } catch {
      appLog("Error updating bookmark favorite: \(error)")
    }
  }

  // Writes name/url/label to the DB, then mirrors them in memory. Returns an error message on
  // failure (nothing is changed in memory).
  public func update(name newName: String, url newUrl: String, label newLabel: String?) -> String? {
    if let error = Bookmark.labelUnavailableError(newLabel) { return error }

    let bookmarks = Table("bookmarks")
    let id = SQLite.Expression<Int64>("id")
    let name = SQLite.Expression<String>("name")
    let url = SQLite.Expression<String>("url")
    let label = SQLite.Expression<String?>("label")
    let mrk = bookmarks.filter(id == self.id)

    var setters = [name <- newName, url <- newUrl]
    if bookmarkLabelsEnabled { setters.append(label <- newLabel) }

    do {
      try databaseConn!.run(mrk.update(setters))
      postBookmarksDidChange()
    } catch {
      appLog("Error updating bookmark: \(error)")
      return Bookmark.describe(error)
    }

    self.name = newName
    self.url = newUrl
    self.label = newLabel
    return nil
  }

  // Static utility functions

  public static func getAll() -> [Bookmark] {
    do {
      let id = SQLite.Expression<Int64>("id")
      let order = SQLite.Expression<Int64>("order")
      let bookmarks = SQLite.Table("bookmarks").order(order.asc, id.asc)
      let itr: RowIterator? = try databaseConn?.prepareRowIterator(bookmarks)
      let bookmarksFound = try itr?.map { row in
        Bookmark.init(fromRowElement: row)
      }

      return bookmarksFound!
    } catch {
      appLog("Error fetching bookmarks from database: \(error)")
      return []
    }
  }

  public static func getById(bookmarkId: Int64) -> Bookmark? {
    do {
      let bookmarks = SQLite.Table("bookmarks")

      let id = SQLite.Expression<Int64>("id")
      let query: SQLite.Table = bookmarks.filter(id == bookmarkId).limit(1)
      let itr: RowIterator? = try databaseConn?.prepareRowIterator(query)

      let found = itr?.next()

      if found != nil {
        return Bookmark(fromRowElement: found!)
      }

      return nil

    } catch {
      appLog("Error fetching bookmark from database: \(error)")
      return nil
    }
  }

  // Case-insensitive lookup by OSC label
  public static func find(label target: String) -> Bookmark? {
    getAll().first { $0.label?.caseInsensitiveCompare(target) == .orderedSame }
  }

  // Returns an error message on failure
  public static func addNewBookmark(name newName: String, url newUrl: String, label newLabel: String?)
    -> String?
  {
    if let error = labelUnavailableError(newLabel) { return error }

    let bookmarks = SQLite.Table("bookmarks")
    let order = SQLite.Expression<Int64>("order")
    let name = SQLite.Expression<String>("name")
    let url = SQLite.Expression<String>("url")
    let favorite = SQLite.Expression<Bool>("favorite")
    let label = SQLite.Expression<String?>("label")

    var setters = [order <- 0, name <- newName, url <- newUrl, favorite <- false]
    if bookmarkLabelsEnabled { setters.append(label <- newLabel) }

    do {
      try databaseConn!.run(bookmarks.insert(setters))
      postBookmarksDidChange()
      return nil
    } catch {
      appLog("Error creating bookmark: \(error)")
      return describe(error)
    }
  }

  private static func labelUnavailableError(_ label: String?) -> String? {
    label != nil && !bookmarkLabelsEnabled ? "Labels unavailable (database migration failed)" : nil
  }

  private static func describe(_ error: Error) -> String {
    "\(error)".contains("UNIQUE constraint failed") ? "Label already used" : "Database error: \(error)"
  }

  public static func deleteBookmark(toDelete: Bookmark) {
    let bookmarks = SQLite.Table("bookmarks")
    let id = SQLite.Expression<Int64>("id")
    let query = bookmarks.filter(id == toDelete.id).delete()

    do {
      try databaseConn!.run(query)
      postBookmarksDidChange()
    } catch {
      appLog("Error deleting bookmark: \(error)")
    }
  }
}

// Validates a raw OSC label. Empty (after trimming) means no label. Labels are [A-Za-z0-9_-],
// not all digits (numbers select by sidebar position), and unique case-insensitively.
func validateBookmarkLabel(
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
func validateBookmarkFields(
  name: String, url: String, label: String, existing: [(id: Int64, label: String?)],
  excludingId: Int64?
) -> (label: String?, error: String?) {
  if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, "Name is required") }
  if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, "URL is required") }
  return validateBookmarkLabel(label, existing: existing, excludingId: excludingId)
}

#if DEBUG
  // Runs at launch in debug builds; traps if label validation regresses.
  func checkBookmarkLabelValidation() {
    let existing: [(id: Int64, label: String?)] = [(1, "chuds"), (2, nil)]
    func check(_ raw: String, _ id: Int64?, _ label: String?, _ fails: Bool) {
      let result = validateBookmarkLabel(raw, existing: existing, excludingId: id)
      precondition(
        result.label == label && (result.error != nil) == fails,
        "label check failed for \"\(raw)\": \(result)")
    }
    check("", nil, nil, false)
    check("  chuds ", 1, "chuds", false)
    check("chuds", 1, "chuds", false)
    check("chuds", nil, nil, true)
    check("Chuds", 2, nil, true)
    check("123", nil, nil, true)
    check("a b", nil, nil, true)
    check("a/b", nil, nil, true)
    check("x-1_y", nil, "x-1_y", false)
    check("é", nil, nil, true)
    precondition(
      validateBookmarkFields(name: " ", url: "x", label: "", existing: [], excludingId: nil).error
        != nil)
    precondition(
      validateBookmarkFields(name: "n", url: "", label: "", existing: [], excludingId: nil).error
        != nil)
    appLog("Bookmark label validation self-check passed")
  }
#endif

extension Notification.Name {
  // Posted after any bookmark insert, update, favorite toggle or delete
  static let bookmarksDidChange = Notification.Name("SyphonWebBookmarksDidChange")
}

// Bookmarks live in one database shared by every --profile instance, so the change is announced
// both in-process and to other SyphonWeb processes.
func postBookmarksDidChange() {
  NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
  DistributedNotificationCenter.default().postNotificationName(
    .bookmarksDidChange, object: nil, userInfo: nil, deliverImmediately: true)
}

// Fires for bookmark changes made in this process or any other SyphonWeb instance
var bookmarksDidChangePublisher: some Publisher<Notification, Never> {
  NotificationCenter.default.publisher(for: .bookmarksDidChange)
    .merge(with: DistributedNotificationCenter.default().publisher(for: .bookmarksDidChange))
    .receive(on: DispatchQueue.main)
}
