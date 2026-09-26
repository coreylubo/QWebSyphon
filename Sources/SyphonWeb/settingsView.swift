import SwiftUI

// One documented OSC address for the "OSC Commands" reference list.
private struct OSCCommandInfo: Identifiable {
  let id: String
  let args: String
  let description: String
}

private let oscCommands: [OSCCommandInfo] = [
  OSCCommandInfo(id: "/syphon/url", args: "string", description: "Load a URL (https:// added if no scheme is given)."),
  OSCCommandInfo(
    id: "/syphon/bookmark", args: "string or int",
    description: "Load a bookmark by OSC label or name (string), or by 1-based sidebar position (int/float)."
  ),
  OSCCommandInfo(id: "/syphon/bookmark/<label>", args: "none", description: "Load the bookmark with this OSC label."),
  OSCCommandInfo(id: "/syphon/refresh", args: "none", description: "Reload the current page."),
]

@available(macOS 14, *)
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var oscController: OSCController

  @State private var portText: String = ""
  @State private var portError: String?
  @State private var bookmarks: [Bookmark] = []

  var body: some View {
    Form {
      OutputSettingsSections(model: model, output: model.selectedOutput)
        .id(model.selectedOutputID)

      Section("Instances") {
        Text("Profile: \(profileName ?? "default")")
        Text(
          "Run more instances with `open -n SyphonWeb.app --args --profile NAME`. Each profile has its own settings; set a different OSC port per profile. Bookmarks are shared."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("OSC") {
        HStack {
          TextField("Port", text: $portText)
            .frame(width: 100)
            .onSubmit(applyPort)
          Button("Apply", action: applyPort)
          Spacer()
          Text(oscController.status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let portError {
          Text(portError).font(.caption).foregroundStyle(.red)
        }
      }

      Section("OSC Commands") {
        ForEach(oscCommands) { command in
          VStack(alignment: .leading, spacing: 1) {
            Text("\(command.id) \(command.args)").font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            Text(command.description).font(.caption).foregroundStyle(.secondary)
          }
        }
        ForEach(bookmarks.filter { $0.label != nil }) { bookmark in
          VStack(alignment: .leading, spacing: 1) {
            Text("/syphon/bookmark/\(bookmark.label!)").font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            Text("Load \"\(bookmark.name)\"").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 420, minHeight: 480)
    .onAppear {
      portText = String(model.oscPort)
      bookmarks = Bookmark.getAll()
    }
    // The window is retained, so onAppear runs once; keep the command list current
    .onReceive(bookmarksDidChangePublisher) { _ in
      bookmarks = Bookmark.getAll()
    }
  }

  private func applyPort() {
    portError = nil
    guard let value = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
      validOSCPortRange.contains(value)
    else {
      portError = "Port must be a number between \(validOSCPortRange.lowerBound) and \(validOSCPortRange.upperBound)"
      return
    }
    let port = UInt16(value)
    // Persist only once the port is actually bound, so a failed Apply doesn't disable the
    // free-port fallback on the next launch
    if oscController.start(port: port, explicit: true) {
      model.oscPort = port
    }
  }
}

// Which resolution choice the picker shows. `.custom` maps to `output.customSize != nil`; the two
// presets map to `output.resolution` when there's no custom size.
private enum ResolutionChoice: Hashable {
  case preset(OutputResolution)
  case custom
}

// Output/Syphon/Appearance settings for one output. Re-created (via `.id(model.selectedOutputID)`
// in SettingsView) whenever the selection changes, so every `@State` draft here (name text, W/H
// text, errors) starts fresh for the newly selected output rather than leaking the old one's.
@available(macOS 14, *)
private struct OutputSettingsSections: View {
  let model: AppModel
  @ObservedObject var output: Output

  @State private var resolutionChoice: ResolutionChoice
  @State private var widthText: String
  @State private var heightText: String
  @State private var sizeError: String?
  @State private var syphonNameText: String
  @State private var syphonNameError: String?

  init(model: AppModel, output: Output) {
    self.model = model
    self.output = output
    _resolutionChoice = State(
      initialValue: output.customSize == nil ? .preset(output.resolution) : .custom)
    let size = output.pixelSize
    _widthText = State(initialValue: String(Int(size.width)))
    _heightText = State(initialValue: String(Int(size.height)))
    _syphonNameText = State(initialValue: output.name)
  }

  var body: some View {
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
