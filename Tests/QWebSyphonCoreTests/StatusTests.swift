import Testing

@testable import QWebSyphonCore

@Suite struct StatusTests {

  @Test func outputStatusLevelRules() {
    #expect(outputStatusLevel(OutputHealth(loading: false, failed: false, fps: 60)) == .ok)
    #expect(outputStatusLevel(OutputHealth(loading: true, failed: false, fps: 0)) == .warning)
    #expect(outputStatusLevel(OutputHealth(loading: false, failed: false, fps: 54)) == .warning)
    #expect(outputStatusLevel(OutputHealth(loading: false, failed: false, fps: 55)) == .ok)
    #expect(outputStatusLevel(OutputHealth(loading: false, failed: true, fps: 60)) == .error)
    // failed takes precedence over loading
    #expect(outputStatusLevel(OutputHealth(loading: true, failed: true, fps: 0)) == .error)
  }

  @Test func statusLevelOkWhenAllHealthyAndOSCListening() {
    let outputs = [
      OutputHealth(loading: false, failed: false, fps: 60),
      OutputHealth(loading: false, failed: false, fps: 55),
    ]
    #expect(statusLevel(outputs: outputs, oscListening: true) == .ok)
  }

  @Test func statusLevelWarningWhenAnyLoadingOrSlow() {
    let loading = [OutputHealth(loading: true, failed: false, fps: 0)]
    #expect(statusLevel(outputs: loading, oscListening: true) == .warning)

    let slow = [OutputHealth(loading: false, failed: false, fps: 40)]
    #expect(statusLevel(outputs: slow, oscListening: true) == .warning)
  }

  @Test func statusLevelErrorWhenAnyFailed() {
    let outputs = [
      OutputHealth(loading: false, failed: false, fps: 60),
      OutputHealth(loading: false, failed: true, fps: 0),
    ]
    #expect(statusLevel(outputs: outputs, oscListening: true) == .error)
  }

  @Test func statusLevelErrorWhenOSCNotListening() {
    let outputs = [OutputHealth(loading: false, failed: false, fps: 60)]
    #expect(statusLevel(outputs: outputs, oscListening: false) == .error)
  }

  @Test func statusLevelErrorTakesPrecedenceOverWarning() {
    let outputs = [
      OutputHealth(loading: true, failed: false, fps: 0),
      OutputHealth(loading: false, failed: true, fps: 0),
    ]
    #expect(statusLevel(outputs: outputs, oscListening: true) == .error)
  }

  @Test func statusLevelOkWithNoOutputs() {
    #expect(statusLevel(outputs: [], oscListening: true) == .ok)
  }

  @Test func inStatusTextRules() {
    func h(_ loading: Bool = false, _ failed: Bool = false, _ fps: Int = 60, _ enabled: Bool = true)
      -> OutputHealth
    { OutputHealth(loading: loading, failed: failed, fps: fps, enabled: enabled) }

    // Singular when only one output is enabled
    #expect(inStatusText(outputs: [h(false, true)], oscListening: true) == "1 of 1 page failed to load")
    #expect(inStatusText(outputs: [h(true)], oscListening: true) == "1 of 1 page loading")
    #expect(inStatusText(outputs: [h(false, false, 40)], oscListening: true) == "1 of 1 output under 55 fps")

    // OSC down beats everything
    #expect(inStatusText(outputs: [h(false, true)], oscListening: false) == "OSC not listening")
    #expect(
      inStatusText(outputs: [h(), h(false, true), h(false, true)], oscListening: true)
        == "2 of 3 pages failed to load")
    // failed beats loading, even on different outputs
    #expect(
      inStatusText(outputs: [h(true, false, 0), h(false, true, 0)], oscListening: true)
        == "1 of 2 pages failed to load")
    // failed + loading on the same output counts once, as failed
    #expect(
      inStatusText(outputs: [h(true, true, 0), h()], oscListening: true)
        == "1 of 2 pages failed to load")
    // disabled failed output ignored
    #expect(
      inStatusText(outputs: [h(false, true, 0, false), h()], oscListening: true)
        == "OSC listening, pages loaded")
    #expect(
      inStatusText(outputs: [h(true, false, 0), h(true, false, 0), h()], oscListening: true)
        == "2 of 3 pages loading")
    // loading beats slow; a loading output isn't also counted as slow
    #expect(
      inStatusText(outputs: [h(true, false, 0), h(false, false, 30)], oscListening: true)
        == "1 of 2 pages loading")
    #expect(
      inStatusText(outputs: [h(false, false, 54), h(false, false, 55)], oscListening: true)
        == "1 of 2 outputs under 55 fps")
    #expect(inStatusText(outputs: [], oscListening: true) == "OSC listening, no outputs enabled")
    #expect(
      inStatusText(outputs: [h(false, false, 60, false)], oscListening: true)
        == "OSC listening, no outputs enabled")
    #expect(inStatusText(outputs: [h()], oscListening: true) == "OSC listening, pages loaded")
  }

  @Test func outStatusTextRules() {
    #expect(outStatusText(enabledOutputsWithClients: []) == "No outputs enabled")
    #expect(outStatusText(enabledOutputsWithClients: [false]) == "No Syphon clients")
    #expect(outStatusText(enabledOutputsWithClients: [false, false]) == "No Syphon clients")
    #expect(outStatusText(enabledOutputsWithClients: [true]) == "Output has Syphon clients")
    #expect(
      outStatusText(enabledOutputsWithClients: [true, true, true])
        == "All 3 outputs have Syphon clients")
    #expect(
      outStatusText(enabledOutputsWithClients: [true, false, true])
        == "2 of 3 outputs have Syphon clients")
  }

  @Test func clientsLevelRules() {
    #expect(clientsLevel(enabledOutputsWithClients: []) == nil)
    #expect(clientsLevel(enabledOutputsWithClients: [false, false]) == nil)
    #expect(clientsLevel(enabledOutputsWithClients: [true, false]) == .warning)
    #expect(clientsLevel(enabledOutputsWithClients: [true, true]) == .ok)
    #expect(clientsLevel(enabledOutputsWithClients: [true]) == .ok)
  }

  @Test func versionTextCases() {
    #expect(
      versionText(version: "1.0.42", commit: "abc1234", date: "2026-09-29 10:00")
        == "Version 1.0.42 (abc1234 · 2026-09-29 10:00)")
    #expect(versionText(version: "1.0.42", commit: nil, date: nil) == "Version 1.0.42")
    #expect(versionText(version: nil, commit: "abc1234", date: "x") == "Version unknown")
  }
}
