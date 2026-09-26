import SwiftUI

// One tile in the output grid: preview image (or a placeholder while loading/failed), name, fps
// and client dot (styled like StatusBar's). `stats` is observed separately from `output` because
// `OutputStats` is its own `ObservableObject` (see statusBar.swift) — `Output.stats` itself isn't
// `@Published`, so fps/client updates wouldn't otherwise trigger a re-render.
@available(macOS 14, *)
struct OutputTile: View {
  @ObservedObject var output: Output
  @ObservedObject var stats: OutputStats
  let isSelected: Bool
  let canDuplicate: Bool
  let canRemove: Bool
  let onSelect: () -> Void
  let onRename: () -> Void
  let onDuplicate: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      preview
        .aspectRatio(output.pixelSize.width / output.pixelSize.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))

      HStack(spacing: 6) {
        Circle()
          .fill(OutputStatusStyle.clientColor(hasClients: stats.hasClients))
          .frame(width: 6, height: 6)
        Text(output.name)
          .font(.caption)
          .fontWeight(isSelected ? .bold : .regular)
          .lineLimit(1)
        Spacer()
        Text(output.loading ? "— fps" : "\(stats.fps) fps")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(OutputStatusStyle.fpsColor(fps: stats.fps, loading: output.loading))
      }
    }
    .padding(6)
    .background(Color(nsColor: .underPageBackgroundColor))
    .cornerRadius(8)
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .contextMenu {
      Button("Rename…", action: onRename)
      Button("Duplicate", action: onDuplicate).disabled(!canDuplicate)
      Divider()
      Button("Remove…", action: onRemove).disabled(!canRemove)
    }
  }

  @ViewBuilder private var preview: some View {
    if let cgImage = output.previewImage {
      Image(decorative: cgImage, scale: 1)
        .resizable()
        .aspectRatio(contentMode: .fit)
    } else {
      ZStack {
        Rectangle().fill(Color.black)
        Text(output.loadError != nil ? "Failed" : "Loading…")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.6))
      }
    }
  }
}

// Rename popover for an output tile: prefilled name, Save/Cancel, inline error from
// `AppModel.renameOutput` — same pattern as BookmarkEditor.
@available(macOS 14, *)
struct RenameOutputPopover: View {
  let output: Output
  let model: AppModel
  let onDone: () -> Void

  @State private var name: String
  @State private var error: String?

  init(output: Output, model: AppModel, onDone: @escaping () -> Void) {
    self.output = output
    self.model = model
    self.onDone = onDone
    _name = State(initialValue: output.name)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Name") {
        TextField("Name", text: $name).onSubmit(save)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
        Button("Save", action: save).keyboardShortcut(.defaultAction)
      }
    }
    .frame(minWidth: 240, alignment: .leading)
    .padding(20)
    .onChange(of: name) { error = nil }
  }

  private func save() {
    if let err = model.renameOutput(output.id, to: name) {
      error = err
    } else {
      onDone()
    }
  }
}

// Thin wrapper so MainView can force a fresh `StatusBar` (and its `@ObservedObject` subscriptions)
// whenever the selected output changes, via `.id(model.selectedOutputID)`.
@available(macOS 14, *)
struct SelectedOutputStatusBar: View {
  @ObservedObject var output: Output
  @ObservedObject var oscController: OSCController

  var body: some View {
    StatusBar(state: output, stats: output.stats, oscController: oscController)
      .frame(maxWidth: .infinity)
  }
}
