import SwiftUI
import SyphonWebCore

// Name/URL/OSC label form shared by the Add and Edit popovers. `onSave` receives trimmed values
// and returns an error message to show, or nil on success (the caller dismisses the popover).
@available(macOS 14, *)
struct BookmarkEditor: View {
  let saveTitle: String
  let existing: [Bookmark]
  let editingId: Int64?
  let onSave: (_ name: String, _ url: String, _ label: String?) -> String?
  let onCancel: () -> Void

  @State private var name: String
  @State private var url: String
  @State private var label: String
  @State private var saveError: String?

  init(
    saveTitle: String, existing: [Bookmark], editing: Bookmark? = nil,
    onSave: @escaping (_ name: String, _ url: String, _ label: String?) -> String?,
    onCancel: @escaping () -> Void
  ) {
    self.saveTitle = saveTitle
    self.existing = existing
    self.editingId = editing?.id
    self.onSave = onSave
    self.onCancel = onCancel
    _name = State(initialValue: editing?.name ?? "")
    _url = State(initialValue: editing?.url ?? "")
    _label = State(initialValue: editing?.label ?? "")
  }

  private var validation: (label: String?, error: String?) {
    validateBookmarkFields(
      name: name, url: url, label: label, existing: existing.map { ($0.id, $0.label) },
      excludingId: editingId)
  }

  var body: some View {
    let validation = validation
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

    VStack(alignment: .leading, spacing: 8) {
      LabeledContent {
        TextField("Name", text: $name)
      } label: {
        Text("Name")
      }
      LabeledContent {
        TextField("http://...", text: $url)
      } label: {
        Text("URL")
      }
      LabeledContent {
        VStack(alignment: .leading, spacing: 2) {
          TextField("optional", text: $label)
          Text("/syphon/bookmark/\(trimmedLabel.isEmpty ? "<label>" : trimmedLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } label: {
        Text("OSC label")
      }
      if let error = validation.error ?? saveError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button(saveTitle) {
          saveError = onSave(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            url.trimmingCharacters(in: .whitespacesAndNewlines),
            validation.label)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(validation.error != nil)
      }
    }
    .frame(minWidth: 280, alignment: .leading)
    .padding(20)
    .onChange(of: [name, url, label]) { saveError = nil }
  }
}
