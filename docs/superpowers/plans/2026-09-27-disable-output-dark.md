# Disable output + dark app — plan (user, 2026-09-27)

Base: `t3code/disable-dark`, stacked on `t3code/rename-qwebsyphon` (PR #6).

## Decisions (user)

- Disabling an output: stop capture and stop its Syphon server (the source disappears from
  clients), and unload the page to free CPU. Re-enabling recreates the server under the same name
  and reloads the output's URL. Persisted.
- OSC: `/syphon/<output>/enable 0|1` (and legacy unscoped `/syphon/enable 0|1` for the legacy
  output, matching the other commands).
- App is always dark.

## Cluster 1 — model + persistence + OSC (core + app)

- `OutputConfig.enabled: Bool`, decoded as `true` when absent and encoded only when `false`, so
  existing JSON stays byte-identical and older builds ignore it. Core tests: round-trip,
  absent = true, `false` present.
- `Output.enabled` `@Published`, `didSet` saves config. Off: `frameServer?.stop()`, set it nil,
  skip in the capture driver (`captureOutputs` / `captureFrame`), controller loads
  `about:blank` without touching `output.url` or `bookmarkID` (so reconcile/live matching and the
  saved URL are unaffected; the navigation delegate must not overwrite `output.url` from
  about:blank). On: recreate `SyphonMetalServer(name:)`, reload `output.url`. Launch with
  `enabled == false` creates no server and loads nothing.
- Rename while disabled: just update the name; the server is created with it on enable.
- OSC: `OSCRoute.enable(OSCOutputScope, Bool)` in core `parseOSCRoute`; argument int/float/bool/
  string "0"/"1" handling like the existing handlers; add to `oscCommandReference`; README +
  docs/OSC.md. Core parser tests.
- Status: disabled outputs never make the status level orange/red (core `statusLevel` ignores
  them; `OutputHealth` gains `enabled`); status menu row shows "Disabled".
- Live bookmark labels: a disabled output is not "playing" anything (exclude from
  `liveBookmarkIDs` input).

## Cluster 2 — UI

- Tile context menu: "Disable Output" / "Enable Output". Gear popover: "Enabled" toggle at the
  top.
- Disabled tile: dimmed placeholder with "Disabled" text instead of the preview; FPS/client
  badges hidden.

## Cluster 3 — dark

- `NSApp.appearance = NSAppearance(named: .darkAqua)` at launch (main.swift), before windows are
  created. Covers main window, Settings, popovers, menus, About.

## Verification

`swift build`, `swift test`, launch a throwaway profile: disable/enable from tile, popover and
OSC; Syphon server list (client dump) loses and regains the source; CPU drops when disabled;
relaunch keeps the state; dark appearance everywhere.

## Codex review (folded in)

1. `OutputConfig` uses synthesized Codable: add custom `init(from:)` defaulting `enabled` to
   `true` and custom encoding that writes `enabled` only when `false`. Update JSON-shape tests.
2. The navigation delegate never writes `output.url`; the controller's current-URL guard would
   skip reloading on enable after `about:blank`. Reset the guard when blanking; gate the initial
   `$url` subscription on `enabled` so a disabled output loads nothing at launch.
3. `Output.init` and rename always create a Syphon server: guard both on `enabled`.
4. Navigating a disabled output (URL, bookmark, drop, OSC, reload) stays disabled: the URL and
   `bookmarkID` are updated and persisted (pre-staging, e.g. a QLab cue sets the page before
   enabling) but nothing loads until enabled. `reload()` no-ops while disabled. Enforce this in
   the controller's single load path, not per caller.
5. Add `$enabled` to `outputChangePublisher` in mainView and filter disabled outputs in
   `updateLiveMap`.
6. New enable-value parser (int, integral float, bool, "0"/"1", reject anything else) as a pure
   core function with tests.
7. Status menu: both the overall health inputs and the row rendering ("Disabled") change.
