import AppKit

// Popped from a bookmark row's double-click when there's more than one output (mainView.swift),
// to ask which output to open the bookmark in. `NSMenuItem` actions need an Objective-C target,
// hence the small `NSObject` subclass; `popUp(positioning:at:in:)` is synchronous, so a plain
// local variable at the call site keeps this alive for the menu's lifetime without extra storage.
@available(macOS 14, *)
@MainActor
final class OpenInOutputMenu: NSObject {
  // Selected output first, then the rest in `outputs` order.
  private let outputs: [Output]
  private let liveOutputIDs: Set<UUID>
  private let onPick: (Output) -> Void

  init(outputs: [Output], selected: Output, liveOutputIDs: Set<UUID>, onPick: @escaping (Output) -> Void) {
    self.outputs = [selected] + outputs.filter { $0.id != selected.id }
    self.liveOutputIDs = liveOutputIDs
    self.onPick = onPick
  }

  func popUp() {
    let menu = NSMenu()
    for output in outputs {
      let item = NSMenuItem(title: output.name, action: #selector(pick(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = output.id
      item.state = liveOutputIDs.contains(output.id) ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  @objc private func pick(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID,
      let output = outputs.first(where: { $0.id == id })
    else { return }
    onPick(output)
  }
}
