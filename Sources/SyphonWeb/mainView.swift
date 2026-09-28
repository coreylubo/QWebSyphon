import Combine
import SwiftUI
import SyphonWebCore

@available(macOS 14, *)
struct MainView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var oscController: OSCController

  @State private var bookmarks: [Bookmark] = Bookmark.getAll()
  @State private var selectedId: Int64?
  @State private var showAddBookmark: Bool = false
  @State private var editingId: Int64?

  @State private var showDeleteConfirm: Bool = false
  @State private var bookmarkToDelete: Bookmark?

  @State private var settingsOutputID: UUID?
  @State private var outputPendingRemoval: Output?

  // bookmarkID -> outputIDs it's live in (`liveBookmarkIDs`, appModel.swift). Recomputed whenever
  // any output's url/bookmarkID/name changes, or the bookmark list changes (see
  // `outputChangePublisher` and `refreshBookmarks`), so the sidebar's globe/names and each tile's
  // "now playing" caption never go stale.
  @State private var liveMap: [Int64: [UUID]] = [:]

  var body: some View {
    HSplitView {
      SidebarContent(
        output: model.selectedOutput, outputs: model.outputs, bookmarks: bookmarks,
        liveMap: liveMap, selectedId: $selectedId,
        showAddBookmark: $showAddBookmark, editingId: $editingId,
        showDeleteConfirm: $showDeleteConfirm, bookmarkToDelete: $bookmarkToDelete,
        refreshBookmarks: refreshBookmarks,
        onSelectOutput: { model.selectedOutputID = $0 }
      )
      .id(model.selectedOutputID)
      .frame(width: 200, alignment: .top)

      VStack(spacing: 0) {
        HStack {
          Text("Outputs").font(.headline)
          Spacer()
          Button(action: { model.addOutput() }) {
            Label("Add Output", systemImage: "plus.rectangle.on.rectangle")
          }
          .disabled(model.outputs.count >= maxOutputs)
        }
        .padding([.horizontal, .top], 12)

        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(model.outputs) { output in
              OutputTile(
                output: output, stats: output.stats, isSelected: output.id == model.selectedOutputID,
                canDuplicate: model.outputs.count < maxOutputs, canRemove: model.outputs.count > 1,
                playingName: playingName(for: output),
                onSelect: { model.selectedOutputID = output.id },
                onSettings: { settingsOutputID = output.id },
                onDuplicate: { model.duplicateOutput(output.id) },
                onRemove: { outputPendingRemoval = output },
                onDropBookmark: { bookmarkID in
                  guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }) else { return }
                  output.open(bookmark: bookmark)
                  model.selectedOutputID = output.id
                }
              )
              .popover(
                isPresented: Binding(
                  get: { settingsOutputID == output.id },
                  set: { if !$0 { settingsOutputID = nil } })
              ) {
                OutputSettingsPopover(
                  model: model, output: output,
                  outputIndex: (model.outputs.firstIndex(where: { $0.id == output.id }) ?? 0) + 1,
                  canDelete: model.outputs.count > 1,
                  onDelete: {
                    settingsOutputID = nil
                    // Popover dismissal and this confirmation both drive presentation state in
                    // the same run loop; deferring avoids the two fighting over SwiftUI's
                    // presentation machinery.
                    DispatchQueue.main.async { outputPendingRemoval = output }
                  })
              }
            }
          }
          .padding(12)
        }

        SelectedOutputStatusBar(output: model.selectedOutput, oscController: oscController)
          .id(model.selectedOutputID)
      }
    }
    // Other --profile instances share the bookmark database
    .onReceive(bookmarksDidChangePublisher) { _ in refreshBookmarks() }
    .onReceive(outputChangePublisher) { updateLiveMap() }
    // Outputs restored with a persisted bookmarkID are live before anything changes
    .onAppear { updateLiveMap() }
    .confirmationDialog("Really delete this bookmark?", isPresented: $showDeleteConfirm) {
      Button("Yes") {
        Bookmark.deleteBookmark(toDelete: bookmarkToDelete!)
        if selectedId == bookmarkToDelete?.id { selectedId = nil }
        refreshBookmarks()
      }
    }
    .confirmationDialog(
      "Delete \u{201c}\(outputPendingRemoval?.name ?? "")\u{201d}?",
      isPresented: Binding(
        get: { outputPendingRemoval != nil }, set: { if !$0 { outputPendingRemoval = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let output = outputPendingRemoval { model.removeOutput(output.id) }
        outputPendingRemoval = nil
      }
    }
  }

  func refreshBookmarks() {
    bookmarks = []
    bookmarks = Bookmark.getAll()
    updateLiveMap()
  }

  // Sidebar display order: favorites section, then the rest, each preserving `bookmarks`' own
  // order — matches `liveBookmarkIDs`' "first match wins" rule to what's actually shown first.
  private var orderedBookmarksForLive: [Bookmark] {
    bookmarks.filter(\.favorite) + bookmarks.filter { !$0.favorite }
  }

  // Fires whenever any output's url/bookmarkID/name changes. `.receive(on:)` defers past
  // `@Published`'s willSet-time emission (see main.swift's oscPort comment) so `updateLiveMap`
  // reads the NEW value, not the one about to be overwritten.
  private var outputChangePublisher: AnyPublisher<Void, Never> {
    Publishers.MergeMany(
      model.outputs.flatMap { output in
        [
          output.$url.map { _ in () }.eraseToAnyPublisher(),
          output.$bookmarkID.map { _ in () }.eraseToAnyPublisher(),
          output.$name.map { _ in () }.eraseToAnyPublisher(),
        ]
      }
    )
    .receive(on: DispatchQueue.main)
    .eraseToAnyPublisher()
  }

  private func updateLiveMap() {
    let outputs = model.outputs.map { (id: $0.id, url: $0.url, bookmarkID: $0.bookmarkID) }
    let liveBookmarks = orderedBookmarksForLive.map { (id: $0.id, url: $0.url) }
    liveMap = liveBookmarkIDs(outputs: outputs, bookmarks: liveBookmarks)
  }

  // Which bookmark (if any) is live specifically in `output`, for the tile's "now playing" caption.
  private func playingName(for output: Output) -> String? {
    guard let bookmarkID = liveMap.first(where: { $0.value.contains(output.id) })?.key else {
      return nil
    }
    return bookmarks.first { $0.id == bookmarkID }?.name
  }
}

// The bookmark sidebar, re-created (via `.id(model.selectedOutputID)` in MainView) whenever the
// selected output changes, so `output` and the isLive/navigate/reload actions below always target
// the current selection. `outputs` and `liveMap` are used for "open in <output>" (drag, double-
// click, context menu) and don't depend on the current selection.
@available(macOS 14, *)
private struct SidebarContent: View {
  @ObservedObject var output: Output
  let outputs: [Output]
  let bookmarks: [Bookmark]
  let liveMap: [Int64: [UUID]]
  @Binding var selectedId: Int64?
  @Binding var showAddBookmark: Bool
  @Binding var editingId: Int64?
  @Binding var showDeleteConfirm: Bool
  @Binding var bookmarkToDelete: Bookmark?
  let refreshBookmarks: () -> Void
  let onSelectOutput: (UUID) -> Void

  var body: some View {
    List(selection: $selectedId) {
      // Filter favs and non-faves
      let nonFavorites = bookmarks.filter { mrk in
        !mrk.favorite
      }

      let favorites = bookmarks.filter { mrk in
        mrk.favorite
      }

      Section("Favorites") {
        ForEach(
          favorites
        ) { bookmark in
          makeBookmark(bookmark: bookmark)
        }
      }
      Section("Bookmarks") {
        ForEach(
          nonFavorites
        ) { bookmark in
          makeBookmark(bookmark: bookmark)
        }
      }
    }.listStyle(.sidebar)
      .contextMenu(forSelectionType: Int64.self) { ids in
        if let bookmark = singleBookmark(ids) {
          Button("Open") { output.open(bookmark: bookmark) }
          if outputs.count >= 2 {
            Menu("Open in") {
              ForEach(outputs) { out in
                Button(out.name) { out.open(bookmark: bookmark) }
              }
            }
          }
          Button("Edit…") { editingId = bookmark.id }
          Button(bookmark.favorite ? "Unfavorite" : "Favorite") {
            bookmark.toggleFavorite()
            refreshBookmarks()
          }
          Divider()
          Button("Delete…") {
            bookmarkToDelete = bookmark
            showDeleteConfirm = true
          }
        }
      } primaryAction: { ids in
        guard let bookmark = singleBookmark(ids) else { return }
        // One output: open directly in it. Several: ask which one via an NSMenu at the mouse
        // location (screen coordinates, no view/event plumbing needed from `primaryAction`).
        guard outputs.count > 1 else {
          output.open(bookmark: bookmark)
          return
        }
        let liveIDs = Set(liveMap[bookmark.id] ?? [])
        let menu = OpenInOutputMenu(outputs: outputs, selected: output, liveOutputIDs: liveIDs) {
          picked in
          picked.open(bookmark: bookmark)
          onSelectOutput(picked.id)
        }
        menu.popUp()
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button(action: {
            showAddBookmark = true
          }) {
            Label("Add", systemImage: "plus")
          }
          .popover(isPresented: $showAddBookmark) {
            BookmarkEditor(saveTitle: "Create", existing: bookmarks) { name, url, label in
              if let error = Bookmark.addNewBookmark(name: name, url: url, label: label) {
                return error
              }
              refreshBookmarks()
              showAddBookmark = false
              return nil
            } onCancel: {
              showAddBookmark = false
            }
          }
          Button(action: {
            output.reload()
          }) {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }.padding()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
  }

  // Context menu actions only apply to a single bookmark
  func singleBookmark(_ ids: Set<Int64>) -> Bookmark? {
    guard ids.count == 1, let id = ids.first else { return nil }
    return bookmarks.first { $0.id == id }
  }

  // Names of the outputs this bookmark is currently live in (any output, via `liveMap`), in
  // `outputs` order. Empty means not live anywhere.
  func liveOutputNames(_ bookmark: Bookmark) -> [String] {
    guard let ids = liveMap[bookmark.id] else { return [] }
    return outputs.compactMap { ids.contains($0.id) ? $0.name : nil }
  }

  @ViewBuilder func makeBookmark(bookmark: Bookmark) -> some View {
    BookmarkRow(
      bookmark: bookmark, liveOutputNames: liveOutputNames(bookmark),
      isLiveInSelectedOutput: liveMap[bookmark.id]?.contains(output.id) == true
    )
    .tag(bookmark.id)
      // `.onDrag`/`.onDrop` (not `.draggable`/`.dropDestination`): rows here live inside a
      // `List(selection:)`, and `.draggable` on such a row is known to fight the List's own
      // click-to-select/double-click gesture recognizers on macOS 14. `.onDrag` is the older,
      // AppKit-backed mechanism `List` was already built to coexist with, so it doesn't have that
      // conflict — at the cost of a plain-text payload instead of a typed `Transferable`.
      .onDrag { NSItemProvider(object: bookmarkDragPayload(bookmark.id) as NSString) }
      .popover(
        isPresented: Binding(
          get: { editingId == bookmark.id },
          set: { if !$0 { editingId = nil } })
      ) {
        BookmarkEditor(saveTitle: "Save", existing: bookmarks, editing: bookmark) { name, url, label in
          if let error = bookmark.update(name: name, url: url, label: label) {
            return error
          }
          editingId = nil
          refreshBookmarks()
          return nil
        } onCancel: {
          editingId = nil
        }
      }
  }
}

// One sidebar row. A bookmark live in the currently selected output is bolded with a globe icon;
// the icon/bold don't fire for a bookmark live only in some other output. Either way, if it's live
// in any output, muted text after the name names which output(s) — e.g. "(Overlay)" or
// "(Main, Overlay)". The icon is white instead of blue when the row is selected (background
// prominence increased), so it stays visible against the selection highlight.
@available(macOS 14, *)
private struct BookmarkRow: View {
  let bookmark: Bookmark
  let liveOutputNames: [String]
  let isLiveInSelectedOutput: Bool

  @Environment(\.backgroundProminence) private var prominence

  private var isLiveAnywhere: Bool { !liveOutputNames.isEmpty }

  var body: some View {
    HStack(spacing: 6) {
      Group {
        if isLiveInSelectedOutput {
          Image(systemName: "globe")
            .foregroundStyle(prominence == .increased ? Color.white : Color.blue)
        }
      }.frame(width: 16)
      Text(bookmark.name).lineLimit(1).fontWeight(isLiveInSelectedOutput ? .bold : .regular)
      if isLiveAnywhere {
        Text("(\(liveOutputNames.joined(separator: ", ")))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let label = bookmark.label {
        Spacer(minLength: 4)
        Text("/\(label)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}
