# Core library + tests + CI, menu bar status — plan (2026-09-27)

Base: `t3code/multi-output-phase2` (PR #3, not merged yet). New branch
`t3code/core-tests-menubar`, stacked PR against PR #3's branch until PR #3 merges, then retargeted
to `main`.

## Decisions (user, 2026-09-27)

- Tests/CI: pure logic in a `SyphonWebCore` library, real `swift test` tests, GitHub Actions on
  every PR.
- Menu bar: status item always on; a global Settings toggle "Show in Dock" (default on). Off =
  accessory app (menu bar only).

## Cluster A — SyphonWebCore + tests + CI (sonnet, first)

Why a library: the app target needs `unsafeFlags` for the Syphon headers and top-level `main.swift`
code, so a test target can't sensibly `@testable import` it. A library with no Syphon/Metal/AppKit
dependency can be tested directly.

- `Package.swift`: add `.target(name: "SyphonWebCore")` (Foundation + CoreGraphics only; no
  unsafeFlags), make `SyphonWeb` depend on it, add
  `.testTarget(name: "SyphonWebCoreTests", dependencies: ["SyphonWebCore"])` using Swift Testing
  (`import Testing`, ships with the Swift 6 toolchain). Tools version stays 6.0.
- Move into `Sources/SyphonWebCore/` (public API, one file per area):
  - Outputs config: `OutputResolution`, `PixelSize`, `OutputConfig`, `encodeOutputs`,
    `decodeOutputs`, `OutputsLoad`, `migrateOutputs`, `loadOutputs`, `sanitizeOutputConfigs`,
    keys constants they need, `maxOutputs`, `reservedOutputNames`, `defaultOutputURL`.
    Functions that today default a parameter to `defaultSyphonName()` (app-only: reads the
    profile) take it explicitly; the app passes it.
  - Names: `validateOutputName`, `uniqueOutputName`, `slugForOutputName`,
    `isOSCAddressableName`. (`defaultOutputBaseName()` stays in the app: it reads the profile.)
  - `captureOrder`, `liveBookmarkIDs`, `makeTileImage` + `tileImageMaxWidth`.
  - URL normalization: `normalizedURL(_:)` as a free function; `Output.normalizedURL` forwards.
  - OSC: `OSCOutputScope`, `OSCRoute`, `parseOSCRoute`, `resolveOutput`, and the pure argument
    helpers (`integralOSCValue`, bookmark resolution helpers that take plain data).
  - Bookmark label validation (the pure function `checkBookmarkLabelValidation` exercises).
  - Logging: core never calls `appLog` directly; `loadOutputs`/`migrateOutputs` take a
    `log: (String) -> Void = { _ in }` parameter; the app passes `appLog`.
- Tests: every current DEBUG self-check case becomes a `@Test` (migration, model, capture order,
  tile orientation/size, OSC routes, bookmark labels) plus `normalizedURL` cases. UserDefaults
  cases use a temp-path suite as the self-checks do. Then delete the DEBUG self-check functions
  and their calls in `main.swift` (tests replace them).
- CI `.github/workflows/ci.yml`: on `pull_request` and `push` to `main`; `runs-on: macos-15`;
  steps: checkout, `swift --version`, `swift build -c release`, `swift test`. Cache `.build`
  keyed on `Package.resolved`. No signing, no app bundle.
- Verify: `swift build`, `swift build -c release`, `swift test` locally, all green; app still
  launches (throwaway profile) and behaves identically.

## Cluster B — menu bar status (sonnet, after A)

- Pure, in core, tested: `enum StatusLevel { ok, warning, error, idle }` and
  `statusLevel(outputs: [OutputHealth], oscListening: Bool) -> StatusLevel` where
  `OutputHealth { loading, failed, fps, hasClients }`:
  - error: any output `failed` or OSC not listening;
  - warning: any output loading, or loaded with fps < 55;
  - ok otherwise. (`idle` unused unless no outputs.)
  Per-output level uses the same rules for one output.
- `statusMenu.swift` (app): `StatusMenuController` owned by `AppDelegate`.
  - `NSStatusItem` with an SF Symbol (`rectangle.on.rectangle`) tinted to the menu bar
    foreground plus a coloured dot, composed like the Prompter's `statusImage`
    (`tcb-gross-prophets-osc-monitor/mac/Prompter/main.swift` ~lines 594–700: non-template
    composed image so the dot keeps its colour).
  - Menu: disabled status line `N outputs · M with clients · OSC <port>` (profile name prefixed
    when running under a profile); one line per output `● <name> — <fps> fps · <clients|no
    clients> · <bookmark name or host>` with only the bullet coloured (Prompter pattern); clicking
    selects that output and shows the main window; separator; Show Window; Settings…; separator;
    Quit SyphonWeb.
  - Refreshed on a 1 s `.common` timer (same cadence as `OutputStats`) and on `model.$outputs`;
    menu rebuilt in `menuWillOpen` too.
- "Show in Dock" toggle: global Settings section "App", persisted per profile in `appDefaults`
  key `showDockIcon` (default true). Applies live: `NSApp.setActivationPolicy(.regular /
  .accessory)`; when switching to accessory, re-activate and keep the main window front.
- Main window close: today `windowWillClose` terminates the app. With the Dock icon hidden,
  closing hides the window (`windowShouldClose` → `orderOut`, return false) so outputs keep
  running and the menu bar reopens it; with the Dock icon shown, behavior unchanged (close quits).
  Quit from the status menu always quits.
- Verify: build + tests; launch on a throwaway profile, screenshot the status item and open menu
  (menu may not be capturable headless: list as unverified); toggle via `defaults write` +
  relaunch to confirm accessory mode starts without a Dock icon.

## Commits / PR

A and B as separate commits; one stacked PR "Core library, tests + CI, menu bar status".
Codex CLI review + Codex bot review; CI must be green.

## Codex plan review (folded in; these override the sections above)

1. `integralOSCValue` uses `SwiftOSC.OSCValue`: it stays in `oscServer.swift`. Core gets only
   OSC logic on plain types (`parseOSCRoute`, `resolveOutput`, routes/scopes).
2. Core API must be explicitly `public`, including initializers (synthesized memberwise inits are
   internal), properties, enum cases and Codable conformances.
3. Dock policy at launch: read `showDockIcon` (absent = true:
   `object(forKey:) == nil ? true : bool(forKey:)`) and set the activation policy from it instead
   of the unconditional `.regular` in `main.swift`.
4. Accessory mode has no app main menu, so ⌘, / ⌘Q vanish: the status menu's Settings… and Quit
   are explicit targeted actions and must work on their own.
5. The toggle is per profile (it lives in `appDefaults`), labelled as such in Settings. Each
   `--profile` process has its own status item; its tooltip and status line include the profile
   name.
6. CI cache: cache only `.build/checkouts` + `.build/repositories` (dependency sources), keyed on
   runner OS, arch and `Package.resolved`; never the compiled artifacts.
7. Drop `StatusLevel.idle` and `OutputHealth.hasClients` (unused by the level rules).
8. Icon refreshes on the 1 s timer; the per-output menu rows are rebuilt only in `menuWillOpen`
   (and while open, on the same timer if cheap; not required).
