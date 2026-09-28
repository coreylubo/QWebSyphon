import Combine
import SwiftUI
import QWebSyphonCore

// Global settings only (phase 3, cluster 3): instances, OSC port, and the full OSC command
// reference (from `oscCommandReference(outputs:)`, cluster 2/oscServer.swift) plus per-bookmark
// label entries. Per-output settings (name, resolution, appearance) live in each tile's
// `OutputSettingsPopover` (outputTiles.swift) instead.
@available(macOS 14, *)
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var oscController: OSCController
  // Applies the toggle live (activation policy) and persists it; see AppDelegate.setDockIconVisible.
  let onDockIconChange: (Bool) -> Void

  @State private var portText: String = ""
  @State private var portError: String?
  @State private var bookmarks: [Bookmark] = []
  @State private var oscReference = OSCReference(generic: [], groups: [], footnote: nil)
  @State private var showDockIcon: Bool = true

  var body: some View {
    Form {
      Section("App") {
        Toggle("Show in Dock", isOn: $showDockIcon)
          .onChange(of: showDockIcon) { _, newValue in onDockIconChange(newValue) }
        Text(
          "Per profile. Off: QWebSyphon lives in the menu bar only, and closing the window hides it instead of quitting."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Instances") {
        Text("Profile: \(profileName ?? "default")")
        Text(
          "Run more instances with `open -n QWebSyphon.app --args --profile NAME`. Each profile has its own settings; set a different OSC port per profile. Bookmarks are shared."
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
        ForEach(oscReference.generic) { command in
          commandRow(command)
        }
        if let footnote = oscReference.footnote {
          commandRow(footnote)
        }
      }

      ForEach(oscReference.groups) { group in
        Section(group.outputName) {
          ForEach(group.rows) { row in
            commandRow(row)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 420, minHeight: 480)
    .onAppear {
      portText = String(model.oscPort)
      bookmarks = Bookmark.getAll()
      refreshOSCReference()
      showDockIcon = showDockIconEnabled()
    }
    // The window is retained, so onAppear runs once; keep the command list current
    .onReceive(bookmarksDidChangePublisher) { _ in
      bookmarks = Bookmark.getAll()
      refreshOSCReference()
    }
    // Outputs added/removed/renamed while Settings is open (name feeds each output's group
    // heading and the grandfathered-name index fallback): re-render via `model` (add/remove) and
    // resubscribe to each current output's `$name`. `.receive(on:)` defers past `@Published`'s
    // willSet-time emission so the read below sees the NEW name, not the old one.
    .onReceive(
      Publishers.MergeMany(model.outputs.map { $0.$name.map { _ in () }.eraseToAnyPublisher() })
        .receive(on: DispatchQueue.main)
    ) { _ in
      refreshOSCReference()
    }
  }

  @ViewBuilder
  private func commandRow(_ command: OSCCommandRow) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(command.args.isEmpty ? command.id : "\(command.id) \(command.args)")
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
      Text(command.description).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func refreshOSCReference() {
    let labelled = bookmarks.compactMap { bookmark in
      bookmark.label.map { (label: $0, name: bookmark.name) }
    }
    oscReference = oscCommandReference(
      outputs: model.outputs, legacyOutput: model.legacyOutput, labelledBookmarks: labelled)
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
