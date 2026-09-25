import SwiftUI

@available(macOS 14, *)
struct MainView: View {
  @ObservedObject var state: WebViewState
  @State private var bookmarks: [Bookmark] = Bookmark.getAll()
  @State private var selectedId: Int64?
  @State private var showAddBookmark: Bool = false
  @State private var editingId: Int64?

  @State private var showDeleteConfirm: Bool = false
  @State private var bookmarkToDelete: Bookmark?

  var body: some View {
    HSplitView {
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
            Button("Open") { state.navigate(to: bookmark.url) }
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
          if let bookmark = singleBookmark(ids) {
            state.navigate(to: bookmark.url)
          }
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
              state.reload()
            }) {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }.padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 200, alignment: .top)
      WebView(state: state).frame(
        width: state.previewSize.width, height: state.previewSize.height
      )
    }
    .confirmationDialog("Really delete this bookmark?", isPresented: $showDeleteConfirm) {
      Button("Yes") {
        Bookmark.deleteBookmark(toDelete: bookmarkToDelete!)
        if selectedId == bookmarkToDelete?.id { selectedId = nil }
        refreshBookmarks()
      }
    }
  }

  func refreshBookmarks() {
    bookmarks = []
    bookmarks = Bookmark.getAll()
  }

  // Context menu actions only apply to a single bookmark
  func singleBookmark(_ ids: Set<Int64>) -> Bookmark? {
    guard ids.count == 1, let id = ids.first else { return nil }
    return bookmarks.first { $0.id == id }
  }

  // Live = the bookmark's URL is what the web view was last told to load
  func isLive(_ bookmark: Bookmark) -> Bool {
    WebViewState.normalizedURL(bookmark.url) == state.url
  }

  @ViewBuilder func makeBookmark(bookmark: Bookmark) -> some View {
    HStack(spacing: 6) {
      Group {
        if isLive(bookmark) {
          Image(systemName: "globe").foregroundStyle(.blue)
        }
      }.frame(width: 16)
      Text(bookmark.name).lineLimit(1)
      if let label = bookmark.label {
        Spacer(minLength: 4)
        Text("/\(label)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .tag(bookmark.id)
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
