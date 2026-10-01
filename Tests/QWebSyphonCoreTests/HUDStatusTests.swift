import Testing
@testable import QWebSyphonCore

@Suite struct HUDStatusTests {
  private func out(_ name: String, enabled: Bool = true, loading: Bool = false, failed: Bool = false, fps: Int = 60, clients: Bool = true) -> HUDOutput {
    HUDOutput(
      name: name, health: OutputHealth(loading: loading, failed: failed, fps: fps, enabled: enabled),
      hasClients: clients)
  }

  private func pay(_ inL: StatusLevel = .ok, _ outL: StatusLevel? = .ok, port: UInt16? = 9000, _ outs: [HUDOutput]) -> [String: Any] {
    HUDStatus.payload(inLevel: inL, inText: "in txt", outLevel: outL, outText: "out txt", oscPort: port, outputs: outs)
  }

  @Test func listeningOk() {
    let p = pay(.ok, .warning, [out("A"), out("B", loading: true, clients: false)])
    #expect(p["dots"] as? [[String: String]] == [["color": "green", "text": "in txt"], ["color": "amber", "text": "out txt"]])
    #expect(p["summary"] as? String == "OSC :9000")
    let rows = p["rows"] as? [[String: Any]]
    #expect(rows?.count == 2)
    #expect(rows?[0]["label"] as? String == "A")
    #expect(rows?[0]["value"] as? String == "60fps · client · Loaded")
    #expect(rows?[0]["wide"] as? Bool == true)
    #expect(rows?[1]["value"] as? String == "60fps · no client · Loading")
    #expect(p["lines"] == nil)
  }

  @Test func notListeningFailedDisabledAndCap() {
    let p = pay(.error, nil, port: nil, [out("X", failed: true), out("Off", enabled: false)])
    #expect((p["dots"] as? [[String: String]])?.map { $0["color"] } == ["red", "gray"])
    #expect(p["summary"] as? String == "OSC not listening")
    let rows = p["rows"] as? [[String: Any]]
    #expect(rows?.count == 1)
    #expect(rows?[0]["value"] as? String == "60fps · client · Failed")
    #expect((pay(.ok, .ok, (0..<9).map { out("O\($0)") })["rows"] as? [[String: Any]])?.count == 8)
    #expect((pay(.warning, .ok, [])["dots"] as? [[String: String]])?[0]["color"] == "amber")
  }

  @Test func sourceNamesProfile() {
    #expect(HUDStatus.source(profile: nil) == "QWebSyphon")
    #expect(HUDStatus.source(profile: "  ") == "QWebSyphon")
    #expect(HUDStatus.source(profile: " stage ") == "QWebSyphon stage")
  }
}
