import FileProvider
import SQLite

@available(macOS 13.0, *)
func getDbPath() -> String {
  if let override = ProcessInfo.processInfo.environment["SYPHONWEB_DB_PATH"], !override.isEmpty {
    return override
  }
  var appSupportUrl = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
  ).first
  if appSupportUrl != nil {
    appSupportUrl!.append(component: "syphon_web.sqlite")
    return appSupportUrl!.path(percentEncoded: false)
  } else {
    NSLog("Oops! Could not determine the application support directly, using temporary storage!!!")
    return "/tmp/syphon_web.sqlite"
  }
}

func createBookmarkTable(db: Connection) {
  // Table name
  let bookmarkTable = Table("bookmarks")

  // Unique ID for bookmark
  let id = SQLite.Expression<Int64>("id")

  // Order in which it's displayed on the sidebar
  let order = SQLite.Expression<Int64>("order")

  // Friendly name for the bookmark
  let name = SQLite.Expression<String>("name")

  // The actual URL of the bookmark
  let url = SQLite.Expression<String>("url")

  // Should we show this in the "favs" sub-section on the sidebar?
  let favorite = SQLite.Expression<Bool>("favorite")

  // Optional OSC address label (/syphon/bookmark/<label>), unique case-insensitively
  let label = SQLite.Expression<String?>("label")

  do {
    NSLog("Creating `bookmarks` table if not already present...")
    try db.run(
      bookmarkTable.create(ifNotExists: true) { table in
        table.column(id, primaryKey: .autoincrement)
        table.column(order)
        table.column(name)
        table.column(url)
        table.column(favorite)
        table.column(label)
      })
  } catch {
    NSLog("createBookmarkTable() Error: \(error)")
  }
}

@available(macOS 13.0, *)
func initDatabase() -> Connection? {
  do {
    let dbPath = getDbPath()

    NSLog("Opening SQLite DB at path \(dbPath)")

    let db: Connection = try Connection(dbPath)
    db.busyTimeout = 5
    createBookmarkTable(db: db)
    migrateBookmarkLabels(db: db, dbPath: dbPath)

    return db
  } catch {
    NSLog("initDatabase() Error: \(error)")
    return nil
  }
}

// False until the `label` column + unique index are confirmed present. Written once at startup.
nonisolated(unsafe) var bookmarkLabelsEnabled = false

// Adds the `label` column to pre-label databases (after backing the file up) and ensures the
// case-insensitive unique index exists. On any failure labels stay disabled; the app keeps running.
func migrateBookmarkLabels(db: Connection, dbPath: String) {
  let bookmarkTable = Table("bookmarks")
  let label = SQLite.Expression<String?>("label")

  func hasLabelColumn() throws -> Bool {
    try db.prepare("PRAGMA table_info(bookmarks)").contains { row in
      row[1] as? String == "label"
    }
  }

  do {
    if try !hasLabelColumn() {
      NSLog("`bookmarks` has no `label` column, backing up before migrating...")
      guard backupDatabase(dbPath: dbPath) else {
        NSLog("Backup failed, skipping `label` migration. Bookmark labels are disabled.")
        return
      }
      // Two instances can both reach here on first launch; the transaction serializes them, and
      // the column check is repeated inside so the second instance skips the ALTER.
      try db.transaction(.immediate) {
        if try !hasLabelColumn() {
          try db.run(bookmarkTable.addColumn(label))
          NSLog("Added `label` column to `bookmarks`")
        } else {
          NSLog("`label` column already present (added by another instance), skipping ALTER")
        }
      }
    }

    try db.run(
      "CREATE UNIQUE INDEX IF NOT EXISTS bookmarks_label_unique ON bookmarks(label COLLATE NOCASE) WHERE label IS NOT NULL"
    )
    NSLog("Ensured unique index `bookmarks_label_unique`")
    bookmarkLabelsEnabled = true
  } catch {
    NSLog("migrateBookmarkLabels() Error: \(error). Bookmark labels are disabled.")
  }
}

// Copies the DB file (and -wal/-shm siblings if present) to
// `<dbPath>.bak-<timestamp>-<pid>[-wal|-shm]`. The pid keeps concurrent instances' backups from
// colliding when they race to migrate the same fresh DB.
func backupDatabase(dbPath: String) -> Bool {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  let backupPath = "\(dbPath).bak-\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
  let fileManager = FileManager.default

  do {
    try fileManager.copyItem(atPath: dbPath, toPath: backupPath)
    for sibling in ["-wal", "-shm"] where fileManager.fileExists(atPath: dbPath + sibling) {
      try fileManager.copyItem(atPath: dbPath + sibling, toPath: backupPath + sibling)
    }
    NSLog("Backed up SQLite DB to \(backupPath)")
    return true
  } catch {
    NSLog("backupDatabase() Error: \(error)")
    return false
  }
}
