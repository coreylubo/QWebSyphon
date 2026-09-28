import Foundation

// One row of the Settings "OSC Commands" reference: an address + its argument type + a one-line
// description. Pure display data — parsing/dispatch lives in `OSC.swift`/`oscServer.swift`.
public struct OSCCommandRow: Identifiable, Equatable, Sendable {
  public let id: String
  public let args: String
  public let description: String

  public init(id: String, args: String, description: String) {
    self.id = id
    self.args = args
    self.description = description
  }
}

// The concrete commands for one output, headed by its OSC ref (name if OSC-addressable, else
// 1-based index) alongside the output's display name.
public struct OSCOutputGroup: Identifiable, Equatable, Sendable {
  public let id: String
  public let outputName: String
  public let rows: [OSCCommandRow]

  public init(id: String, outputName: String, rows: [OSCCommandRow]) {
    self.id = id
    self.outputName = outputName
    self.rows = rows
  }
}

// The full "OSC Commands" reference: generic scoped-command forms, one group of concrete commands
// per output, and an optional footnote for the still-live unscoped ("legacy") forms.
public struct OSCReference: Equatable, Sendable {
  public let generic: [OSCCommandRow]
  public let groups: [OSCOutputGroup]
  public let footnote: OSCCommandRow?

  public init(generic: [OSCCommandRow], groups: [OSCOutputGroup], footnote: OSCCommandRow?) {
    self.generic = generic
    self.groups = groups
    self.footnote = footnote
  }
}

// Builds the reference from pure inputs: each output as its display name plus 1-based sidebar
// index, each labelled bookmark as its OSC label plus display name, and the legacy output's name
// (nil when there is no legacy output). Every output's group repeats the same labelled-bookmark
// rows under that output's own ref, since bookmarks aren't per-output.
public func buildOSCReference(
  outputs: [(name: String, index: Int)],
  labelledBookmarks: [(label: String, name: String)],
  legacyOutputName: String?
) -> OSCReference {
  let generic: [OSCCommandRow] = [
    OSCCommandRow(
      id: "/syphon/<output>/url", args: "string",
      description:
        "Load a URL in <output> (https:// added if no scheme is given). <output> = name (case-insensitive, if OSC-addressable) or 1-based index."
    ),
    OSCCommandRow(
      id: "/syphon/<output>/bookmark", args: "string or int",
      description:
        "Load a bookmark by OSC label or name (string), or by 1-based sidebar position (int/float), in <output>."
    ),
    OSCCommandRow(
      id: "/syphon/<output>/bookmark/<label>", args: "none",
      description: "Load the bookmark with this OSC label, in <output>."),
    OSCCommandRow(
      id: "/syphon/<output>/refresh", args: "none",
      description: "Reload the current page in <output>."),
    OSCCommandRow(
      id: "/syphon/<output>/enable", args: "0/1, true/false, or int/float",
      description: "Enable (1) or disable (0) <output>."),
  ]

  let groups = outputs.map { output -> OSCOutputGroup in
    let ref = isOSCAddressableName(output.name) ? output.name : String(output.index)
    var rows: [OSCCommandRow] = [
      OSCCommandRow(
        id: "/syphon/\(ref)/url", args: "string",
        description: "Load a URL in \"\(output.name)\"."),
      OSCCommandRow(
        id: "/syphon/\(ref)/bookmark", args: "string or int",
        description: "Load a bookmark by label, name, or 1-based sidebar position, in \"\(output.name)\"."),
      OSCCommandRow(
        id: "/syphon/\(ref)/refresh", args: "none",
        description: "Reload the current page in \"\(output.name)\"."),
      OSCCommandRow(
        id: "/syphon/\(ref)/enable", args: "0/1, true/false, or int/float",
        description: "Enable (1) or disable (0) \"\(output.name)\"."),
    ]
    for bookmark in labelledBookmarks {
      rows.append(
        OSCCommandRow(
          id: "/syphon/\(ref)/bookmark/\(bookmark.label)", args: "none",
          description: "Load \"\(bookmark.name)\"."))
    }
    return OSCOutputGroup(id: ref, outputName: output.name, rows: rows)
  }

  let footnote = legacyOutputName.map {
    OSCCommandRow(
      id: "/syphon/<command>", args: "url|bookmark|bookmark/<label>|refresh|enable",
      description: "Unscoped addresses still work (back-compat for existing QLab cues) and target \"\($0)\".")
  }

  return OSCReference(generic: generic, groups: groups, footnote: footnote)
}
