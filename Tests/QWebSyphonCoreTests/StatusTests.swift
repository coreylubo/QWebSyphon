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
}
