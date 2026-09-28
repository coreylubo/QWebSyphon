import Combine
import SQLite
import SwiftUI
import QWebSyphonCore

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
