import SwiftUI
import QWebSyphonCore
import UniformTypeIdentifiers

// Drag payload for a bookmark row -> an output tile's drop target (mainView.swift is the drag
// source, this file the drop destination). Plain text, prefixed so an arbitrary text drag from
// elsewhere is ignored rather than parsed as a bogus bookmark id.
let bookmarkDragPrefix = "qwebsyphon-bookmark:"
func bookmarkDragPayload(_ id: Int64) -> String { "\(bookmarkDragPrefix)\(id)" }
func parseBookmarkDragPayload(_ string: String) -> Int64? {
  guard string.hasPrefix(bookmarkDragPrefix) else { return nil }
  return Int64(string.dropFirst(bookmarkDragPrefix.count))
}

// One tile in the output grid: preview image (or a placeholder while loading/failed), name, fps
// and client dot (styled like StatusBar's), plus an editable URL/bookmark row: shows the playing
// bookmark's name (or the full URL) and a menu to jump to another bookmark or type a URL directly.
// `stats` is observed separately from `output` because `OutputStats` is its own `ObservableObject`
// (see statusBar.swift) — `Output.stats` itself isn't `@Published`, so fps/client updates wouldn't
// otherwise trigger a re-render.
//
// Drop target for "open in this output": uses `.onDrop`/`NSItemProvider` (not `.draggable`/
// `.dropDestination`) to match the drag source in mainView.swift's `List(selection:)` rows — see
// that file's comment for why.
@available(macOS 14, *)
struct OutputTile: View {
  @ObservedObject var output: Output
  @ObservedObject var stats: OutputStats
  let isSelected: Bool
  let canDuplicate: Bool
  let canRemove: Bool
  // Name of the bookmark currently live in this output (from the sidebar's live map), or nil if
  // none matched — the URL row falls back to the full URL.
  let playingName: String?
  // Sidebar order (favorites, then the rest) for the URL row's "load a bookmark" menu.
  let bookmarks: [Bookmark]
  let onSelect: () -> Void
  let onSettings: () -> Void
  let onDuplicate: () -> Void
  let onRemove: () -> Void
  let onDropBookmark: (Int64) -> Void

  @State private var isDropTargeted = false
  // Text shown/edited in the URL row. Starts as the display text (bookmark name or URL); on focus
  // it switches to the full URL for editing, and reverts on blur/Escape unless Return was pressed.
  @State private var urlFieldText: String
  @FocusState private var isURLFieldFocused: Bool

  init(
    output: Output, stats: OutputStats, isSelected: Bool, canDuplicate: Bool, canRemove: Bool,
    playingName: String?, bookmarks: [Bookmark], onSelect: @escaping () -> Void,
    onSettings: @escaping () -> Void, onDuplicate: @escaping () -> Void,
    onRemove: @escaping () -> Void, onDropBookmark: @escaping (Int64) -> Void
  ) {
    self.output = output
    self.stats = stats
    self.isSelected = isSelected
    self.canDuplicate = canDuplicate
    self.canRemove = canRemove
    self.playingName = playingName
    self.bookmarks = bookmarks
    self.onSelect = onSelect
    self.onSettings = onSettings
    self.onDuplicate = onDuplicate
    self.onRemove = onRemove
    self.onDropBookmark = onDropBookmark
    _urlFieldText = State(initialValue: playingName ?? output.url.absoluteString)
  }

  // Bookmark name if playing one, else the full URL — what the field shows while not focused.
  private var displayText: String { playingName ?? output.url.absoluteString }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Tap-to-select only lives on the preview + name row — the URL row below has its own
      // clickable field/menu, and a tap gesture spanning the whole card would swallow their clicks.
      Group {
        preview
          .aspectRatio(output.pixelSize.width / output.pixelSize.height, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))

        HStack(spacing: 6) {
          if output.enabled {
            Circle()
              .fill(OutputStatusStyle.clientColor(hasClients: stats.hasClients))
              .frame(width: 6, height: 6)
          }
          Text(output.name)
            .font(.caption)
            .fontWeight(isSelected ? .bold : .regular)
            .lineLimit(1)
          Spacer()
          if output.enabled {
            Text(output.loading ? "— fps" : "\(stats.fps) fps")
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(OutputStatusStyle.fpsColor(fps: stats.fps, loading: output.loading))
          }
          Button(action: onSettings) {
            Image(systemName: "gearshape")
          }
          .buttonStyle(.plain)
          .help("Output settings")
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: onSelect)

      urlRow
    }
    .padding(6)
    .background(Color(nsColor: .underPageBackgroundColor))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.accentColor, lineWidth: 3)
        .opacity(isDropTargeted ? 1 : 0)
    )
    .onDrop(of: [.text], isTargeted: $isDropTargeted) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
        guard let string = reading as? String, let id = parseBookmarkDragPayload(string) else {
          return
        }
        DispatchQueue.main.async { onDropBookmark(id) }
      }
      return true
    }
    .contextMenu {
      Button("Settings…", action: onSettings)
      Button(output.enabled ? "Disable Output" : "Enable Output") {
        output.enabled.toggle()
      }
      Button("Duplicate", action: onDuplicate).disabled(!canDuplicate)
      Divider()
      Button("Delete Output…", action: onRemove).disabled(!canRemove)
    }
  }

  // Editable URL/bookmark row: a text field (bookmark name or URL, truncating; full URL while
  // focused) plus a menu to jump to another bookmark. Loading a URL into a disabled output only
  // stores it (`Output.navigate`/`open(bookmark:)` don't check `enabled`), so both stay enabled.
  private var urlRow: some View {
    HStack(spacing: 4) {
      TextField("URL", text: $urlFieldText)
        .textFieldStyle(.plain)
        .font(.caption2)
        .foregroundStyle(isURLFieldFocused ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .focused($isURLFieldFocused)
        .onSubmit {
          output.navigate(to: urlFieldText)
          isURLFieldFocused = false
        }
        .onExitCommand {
          urlFieldText = displayText
          isURLFieldFocused = false
        }
        .onChange(of: isURLFieldFocused) { _, focused in
          if focused {
            urlFieldText = output.url.absoluteString
            onSelect()
          } else {
            urlFieldText = displayText
          }
        }
        .onChange(of: output.url) { _, _ in
          if !isURLFieldFocused { urlFieldText = displayText }
        }
        .onChange(of: playingName) { _, _ in
          if !isURLFieldFocused { urlFieldText = displayText }
        }

      Menu {
        if bookmarks.isEmpty {
          Button("No bookmarks") {}.disabled(true)
        } else {
          ForEach(bookmarks) { bookmark in
            Button {
              onDropBookmark(bookmark.id)
            } label: {
              if bookmark.id == output.bookmarkID {
                Label(bookmark.name, systemImage: "checkmark")
              } else {
                Text(bookmark.name)
              }
            }
          }
        }
      } label: {
        Image(systemName: "bookmark")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Load bookmark")
    }
  }

  @ViewBuilder private var preview: some View {
    if !output.enabled {
      ZStack {
        Rectangle().fill(Color.black.opacity(0.6))
        Text("Disabled")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.6))
      }
    } else if let cgImage = output.previewImage {
      Image(decorative: cgImage, scale: 1)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .background {
          if output.transparentBackground {
            CheckerboardBackground()
          }
        }
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

// Alpha-transparency indicator behind a transparent-background output's preview image — the
// standard "this is where the alpha shows" checkerboard. Placed via `.background` on the
// aspect-fit `Image` in `OutputTile.preview` so it inherits that view's exact frame (the
// aspect-fit rect), not the tile's own frame, which can be taller/wider when letterboxed.
private struct CheckerboardBackground: View {
  private let squareSize: CGFloat = 8

  var body: some View {
    Canvas { context, size in
      let columns = Int(ceil(size.width / squareSize))
      let rows = Int(ceil(size.height / squareSize))
      for row in 0..<rows {
        for column in 0..<columns {
          let rect = CGRect(
            x: CGFloat(column) * squareSize, y: CGFloat(row) * squareSize,
            width: squareSize, height: squareSize)
          let isLight = (row + column).isMultiple(of: 2)
          context.fill(
            Path(rect), with: .color(isLight ? Color(white: 0.85) : Color(white: 0.65)))
        }
      }
    }
  }
}

// Per-output settings popover, opened from a tile's gear button or "Settings…" context menu item
// (phase 3, cluster 3). Fixed width so it reads like a small panel rather than stretching to fit
// its content.
@available(macOS 14, *)
struct OutputSettingsPopover: View {
  let model: AppModel
  @ObservedObject var output: Output
  let outputIndex: Int
  let canDelete: Bool
  let onDelete: () -> Void

  var body: some View {
    Form {
      OutputSettingsSections(
        model: model, output: output, outputIndex: outputIndex, canDelete: canDelete,
        onDelete: onDelete)
    }
    .formStyle(.grouped)
    .frame(width: 360)
  }
}

// Which resolution choice the picker shows. `.custom` maps to `output.customSize != nil`; the two
// presets map to `output.resolution` when there's no custom size.
private enum ResolutionChoice: Hashable {
  case preset(OutputResolution)
  case custom
}

// Output/Syphon/Appearance settings for one output, shown in `OutputSettingsPopover`. Re-created
// (via `.id` at the call site, since SwiftUI reuses a popover's content view across output
// changes on macOS 14 when only its data changes) whenever the target output changes, so every
// `@State` draft here (name text, W/H text, errors) starts fresh for the newly selected output
// rather than leaking the old one's.
@available(macOS 14, *)
struct OutputSettingsSections: View {
  let model: AppModel
  @ObservedObject var output: Output
  let outputIndex: Int
  let canDelete: Bool
  let onDelete: () -> Void

  @State private var resolutionChoice: ResolutionChoice
  @State private var widthText: String
  @State private var heightText: String
  @State private var sizeError: String?
  @State private var syphonNameText: String
  @State private var syphonNameError: String?

  init(model: AppModel, output: Output, outputIndex: Int, canDelete: Bool, onDelete: @escaping () -> Void) {
    self.model = model
    self.output = output
    self.outputIndex = outputIndex
    self.canDelete = canDelete
    self.onDelete = onDelete
    _resolutionChoice = State(
      initialValue: output.customSize == nil ? .preset(output.resolution) : .custom)
    let size = output.pixelSize
    _widthText = State(initialValue: String(Int(size.width)))
    _heightText = State(initialValue: String(Int(size.height)))
    _syphonNameText = State(initialValue: output.name)
  }

  var body: some View {
    Section {
      Toggle("Enabled", isOn: $output.enabled)
    }

    Section("Output") {
      Text("Editing \u{201c}\(output.name)\u{201d}")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Resolution", selection: $resolutionChoice) {
        ForEach(OutputResolution.allCases, id: \.self) { resolution in
          Text(resolution.label).tag(ResolutionChoice.preset(resolution))
        }
        Text("Custom").tag(ResolutionChoice.custom)
      }
      .onChange(of: resolutionChoice) { _, choice in
        if case .preset(let resolution) = choice {
          sizeError = nil
          output.resolution = resolution
          output.customSize = nil
        }
      }

      if resolutionChoice == .custom {
        HStack {
          TextField("Width", text: $widthText).frame(width: 80)
          Text("×")
          TextField("Height", text: $heightText).frame(width: 80)
          Button("Apply", action: applyCustomSize)
        }
        if let sizeError {
          Text(sizeError).font(.caption).foregroundStyle(.red)
        }
      }
    }

    Section("Syphon") {
      HStack {
        TextField("Syphon name", text: $syphonNameText)
          .onSubmit(applySyphonName)
        Button("Apply", action: applySyphonName)
      }
      if let syphonNameError {
        Text(syphonNameError).font(.caption).foregroundStyle(.red)
      }
      if !isOSCAddressableName(output.name) {
        Text(
          "Rename using only letters, digits, - and _ to address this output by name over OSC (by number meanwhile: /syphon/\(outputIndex)/…)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }

    Section("Appearance") {
      Toggle("Transparent background", isOn: $output.transparentBackground)
      Text(
        "The page must set a transparent background (e.g. body { background: transparent }). Output alpha is premultiplied."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Toggle("Capture without clients", isOn: $output.captureWithoutClients)
      Text(
        "Keeps publishing frames while no Syphon client is connected. Turn off to save CPU."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }

    Section("Danger Zone") {
      Button("Delete Output…", role: .destructive, action: onDelete)
        .disabled(!canDelete)
    }
  }

  private func applyCustomSize() {
    sizeError = nil
    guard let width = Int(widthText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let height = Int(heightText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let size = PixelSize(width: width, height: height)
    else {
      sizeError =
        "Width must be \(PixelSize.widthRange.lowerBound)–\(PixelSize.widthRange.upperBound), "
        + "height \(PixelSize.heightRange.lowerBound)–\(PixelSize.heightRange.upperBound)"
      return
    }
    output.setCustomSize(size)
  }

  private func applySyphonName() {
    syphonNameError = nil
    let trimmed = syphonNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      syphonNameError = "Syphon name can't be empty"
      return
    }
    if let error = model.renameOutput(output.id, to: trimmed) {
      syphonNameError = error
      return
    }
    syphonNameText = trimmed
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
