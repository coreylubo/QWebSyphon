import Testing
@testable import QWebSyphonCore

@Suite struct HUDStatusTests {
  private func out(_ name: String, enabled: Bool = true, loading: Bool = false, failed: Bool = false, fps: Int = 60, clients: Bool = true) -> HUDOutput {
    HUDOutput(
      name: name, health: OutputHealth(loading: loading, failed: failed, fps: fps, enabled: enabled),
      hasClients: clients)
  }

  @Test func listeningOk() {
    let p = HUDStatus.payload(level: .ok, oscPort: 9000, outputs: [out("A"), out("B", loading: true, clients: false)])
    #expect(p["dots"] as? [String] == ["green"])
    #expect(p["summary"] as? String == "OSC :9000")
    #expect(p["lines"] as? [String] == ["A  60fps  client  Loaded", "B  60fps  no client  Loading"])
  }

  @Test func notListeningFailedDisabledAndCap() {
    let p = HUDStatus.payload(level: .error, oscPort: nil, outputs: [out("X", failed: true), out("Off", enabled: false)])
    #expect(p["dots"] as? [String] == ["red"])
    #expect(p["summary"] as? String == "OSC not listening")
    #expect(p["lines"] as? [String] == ["X  60fps  client  Failed"])
    let many = (0..<9).map { out("O\($0)") }
    #expect((HUDStatus.payload(level: .warning, oscPort: 1, outputs: many)["lines"] as? [String])?.count == 6)
    #expect(HUDStatus.payload(level: .warning, oscPort: 1, outputs: [])["dots"] as? [String] == ["amber"])
  }
}
