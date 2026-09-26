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
  @ObservedObject var state: WebViewState
  @ObservedObject var oscController: OSCController

  @State private var portText: String = ""
  @State private var portError: String?
  @State private var bookmarks: [Bookmark] = []
  @State private var syphonNameText: String = ""
  @State private var syphonNameError: String?

  var body: some View {
    Form {
      Section("Output") {
        Picker("Resolution", selection: $state.resolution) {
          ForEach(OutputResolution.allCases, id: \.self) { resolution in
            Text(resolution.label).tag(resolution)
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

      Section("Appearance") {
        Toggle("Transparent background", isOn: $state.transparentBackground)
        Text(
          "The page must set a transparent background (e.g. body { background: transparent }). Output alpha is premultiplied."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
      portText = String(state.oscPort)
      syphonNameText = state.syphonName
      bookmarks = Bookmark.getAll()
    }
    // The window is retained, so onAppear runs once; keep the command list current
    .onReceive(bookmarksDidChangePublisher) { _ in
      bookmarks = Bookmark.getAll()
    }
  }

  private func applySyphonName() {
    syphonNameError = nil
    let trimmed = syphonNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      syphonNameError = "Syphon name can't be empty"
      return
    }
    syphonNameText = trimmed
    state.syphonName = trimmed
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
      state.oscPort = port
    }
  }
}
