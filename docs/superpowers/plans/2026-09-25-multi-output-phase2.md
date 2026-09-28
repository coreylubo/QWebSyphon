# Multi-output phase 2 — implementation plan (Codex-reviewed, 8 findings folded in)

Spec: `docs/multi-output-spec.md` (phase 2 + decisions 4–6 + phase 0 findings). Base: `main` at
`63cd9d0` (phase 1 merged). Branch: `t3code/multi-output-phase2`.

## Scope

Multiple outputs, complete model, cover-proof rendering, minimal tile UI. Not in scope (phase 3/4):
"Open in" menu, per-output live indicators, status-bar summary, OSC scoped addresses.

## Design

### A. Model (`appModel.swift`)

- `AppModel.outputs` becomes mutable through methods only:
  - `addOutput() -> Output?` — nil at cap (`maxOutputs = 4`). Name = first free
    "`defaultSyphonName()` N" (N = 2, 3…). Config default (720p, default URL).
  - `duplicateOutput(_ id:)` — copies url/resolution/transparent/captureWithoutClients, new id,
    unique name "<name> copy" / "<name> copy 2". Nil at cap.
  - `removeOutput(_ id:)` — refuses to remove the last output. Stops that output's Syphon server,
    detaches its web view from the host window, drops it from `outputs`, moves selection to the
    neighbour. Removing the legacy output is allowed; `legacyOutputID` stays set (so legacy OSC
    logs "no legacy output", never retargets).
  - `renameOutput(_ id:, to:) -> String?` (error message or nil) via pure `validateOutputName`.
- Pure `validateOutputName(_ name:, existing: [String]) -> String?`: trimmed, non-empty, unique
  case-insensitively among the other outputs, not a reserved word (`url`, `bookmark`, `refresh`,
  case-insensitive). No slug restriction in phase 2 (Syphon display names keep spaces); phase 4
  derives the OSC slug.
- Load: drop phase 1's "more than one output → keep one, don't persist" branch. Load all stored
  outputs, truncated to `maxOutputs`. Pure `sanitizeOutputConfigs(_:) -> (configs, repaired: Bool)`
  runs before any `Output` is constructed: blank/invalid/duplicate names (made unique by appending
  " 2"…), unparseable URLs (default URL), duplicate UUIDs (fresh id), out-of-bounds custom size
  (dropped). Any repair or truncation → `persist = false` + log, so stored JSON is never
  overwritten by a repaired copy. `Output.init` stops normalizing (trusts sanitized config).
- Every mutation calls `saveOutputs()` (whole-array JSON, as today). `@Published outputs` so the
  UI updates.
- `legacyOutputID` stays `let`.
- Custom resolution (decision 6), rollback-safe: `OutputConfig.resolution` stays the
  `OutputResolution` enum string (`"hd720"`/`"hd1080"`), plus a new optional
  `customSize: PixelSize?` (`{width, height}` ints). Effective size = `customSize ?? preset`.
  Phase 1 builds ignore the unknown key and fall back to the preset, so rollback keeps every
  output (at its preset size). When setting a custom size, `resolution` is set to the nearest
  preset for that fallback. `PixelSize.init?(width:height:)` validates 16…3840 × 16…2160; the only
  way to build one. Encoding keeps `customSize` absent when nil (phase 1 JSON byte-identical for
  preset-only outputs).

### B. Rendering host (new `outputHost.swift`)

Per decision 5: all output web views live in one host window that never takes part in the UI.

- `OutputHostWindow`: borderless `NSWindow`, `alphaValue = 0`, `ignoresMouseEvents = true`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`,
  `level = .screenSaver`, `isReleasedWhenClosed = false`, positioned on the main window's screen
  (origin = screen.visibleFrame.origin), `orderFrontRegardless()`. Never key/main
  (`canBecomeKey/Main = false` in a subclass).
- The window's content view holds one `WKWebView` per output, all at origin (0,0) stacked (case 2 +
  4b in the spike: stacked siblings keep painting; alpha-0 window keeps painting when covered).
  Window size = max of the views' point sizes.
- Each view is sized `output.previewSize` (px / host backing scale) with
  `setLayoutScale(1 / backingScale)`, then nudged (+1 pt and back) so `vw`/`vh` resolve (spike
  surprise 3).
- `backingScale` per output = the host window's `backingScaleFactor` (all outputs share the host
  window; still stored per output so a later per-screen host is a local change). The host
  follows the main window's screen: on the main window's `didChangeScreenNotification` and on
  `NSApplication.didChangeScreenParametersNotification`, move the host to the main window's
  screen, then synchronously re-apply scale/layout/Metal buffers for every controller. Host
  window `didChangeBackingPropertiesNotification` does the same.
- Web view lifecycle moves out of SwiftUI. Ownership: `AppDelegate` retains one `OutputHost`;
  the host retains `[UUID: OutputWebViewController]`; each controller retains its WKWebView, is
  its navigation delegate (WKWebView holds the delegate weakly, so the controller must be
  retained by the host), and owns its Combine subscriptions. The controller replaces the `WebView`
  NSViewRepresentable: same four navigation callbacks; observes `output.$url`,
  `$transparentBackground`, effective size, `$backingScale` and applies them (load URL,
  drawsBackground, initMetal + layout scale + resize + nudge). Same synchronous re-provisioning
  guarantee. AppModel tells the host on add/remove (host subscribes to `model.$outputs` and
  diffs by id). Remove order: cancel subscriptions, `stopLoading`, remove view from superview,
  drop controller, stop Syphon server, then drop the `Output`.
- Tile preview: `Output` keeps `@Published var previewImage: CGImage?`, set from
  `graphicsContext.makeImage()` by a 15 Hz tile timer in AppModel (only for outputs whose frame
  count changed since the last tile refresh). Only UI subscribes to it.

### C. Capture driver (`appModel.swift`)

- Budget-based round robin: per tick, start at `nextCaptureIndex`, capture outputs in order until
  all done or elapsed ≥ `captureDeadline` (12 ms, spike's budget rule). Outputs not reached are
  captured first next tick (`nextCaptureIndex` = first skipped). An output that alone exceeds the
  deadline is still captured (deadline checked before each capture, not after the first).
- Cursor is an output **id** (`nextCaptureID: UUID?`), not an index: after add/remove it is
  resolved against the current array; if the id is gone, start from index 0. No stale index.
- Pure helper `captureOrder(ids:, startID:) -> [UUID]` tested in the self-check, including
  removal of the cursor's output.
- Existing per-output `OutputStats` fps shows the effect; no extra metrics.

### D. UI (`mainView.swift`, `settingsView.swift`, `main.swift`)

- `MainView(model:, oscController:)` observes `AppModel`; selected output drives sidebar
  double-click / Open / Refresh and the status bar (as today).
- Right side: tile grid (`LazyVGrid`, adaptive, 2 columns) of `OutputTile`s — image
  (aspect-fit to the output's aspect ratio), name, fps, client dot; selected tile has an accent
  border; click selects. Context menu: Rename…, Duplicate, Remove… (confirm; disabled for the
  last output). Toolbar/footer `+` button (disabled at cap).
- Rename uses a popover with a text field + `validateOutputName` error, like BookmarkEditor.
- Main window becomes resizable with a fixed minimum; no more `resizeWindow` on resolution
  change (the preview is no longer a live web view sized in points).
- Settings: the Output/Syphon/Appearance sections edit `model.selectedOutput` (re-bound when the
  selection changes: `SettingsView` observes `model` and uses `.id(selectedOutputID)` on the
  output section). Resolution: preset picker (720p, 1080p, Custom) + W/H draft text fields when
  Custom, applied with an Apply button only when `PixelSize.init?` succeeds (error text
  otherwise); never a transient invalid size. "Capture without clients" toggle (decision 4) bound
  to the selected output. Minimal per spec; the proper per-output section is phase 3.
- `applicationWillTerminate` already stops every server.

### E. Self-checks (`#if DEBUG`, pattern `checkOutputsMigration`)

- `validateOutputName`: empty, whitespace, duplicate (case-insensitive), reserved, own name on
  rename allowed.
- Unique default naming for add/duplicate.
- `OutputResolution` decode: old strings, new object, invalid → decode failure (whole array
  corrupt → phase 1 fallback path), bounds.
- Load with 2 stored outputs: both kept, persist true; 5 stored: truncated to 4, persist false.
- Capture round robin: order/skip bookkeeping.

### F. Verification (spec's verification rules)

- `swift build` debug + release; debug launch runs the self-checks.
- Throwaway profile + `SYPHONWEB_DB_PATH=/tmp/...`, JSON with 2 outputs seeded via
  `defaults write`. Syphon lister shows both names; client counts frames per server (fps each).
- Measure fps per output for 1, 2, 3 × 720p, 1080p + 720p, 1080p + 960×1080 (decision 6's show
  setup); append table to spec.
- Cover-proof check: covering the main window fully (another app's window) and minimising it —
  client still counts fresh frames (use the spike's rAF counter page as a data: URL or local file).
- Decision 5 matrix: full-screen app on another Space frontmost; main window moved to a second
  display (if one is attached; otherwise list as unverified for the user). Screen lock / display
  sleep documented as known unsupported (freezes), not tested.
- Transparency: page with transparent body, check alpha in received texture.
- Legacy OSC after removing the legacy output logs and does nothing.
- Unverified UI interactions listed for the user (click select, context menu, add/remove, rename).

## Clusters / delegation

1. Model + resolution struct + naming + load changes + self-checks (A, E-model) — sonnet.
2. Host window + web view controller + capture driver + tile images (B, C) — opus subagent
   (WebKit painting/throttling mental model is the hard part).
3. UI (D) — sonnet, after 1 (depends on model API).
4. Verification + measurements (F) — sonnet, after 2+3.

Commits: one per cluster where each builds; otherwise one phase 2 commit.

## Risks

- Window-level `.screenSaver` alpha-0 window on top of everything: invisible and mouse-transparent,
  but may interfere with screen recording / Mission Control; spike only tested full cover +
  inactive. Fallback: `.normal` level stacked behind the main window loses cover-proofing.
- Live preview interactivity is lost: tiles are images, so the user can no longer click/scroll/
  type into the page in the preview. (Behavior change — confirm with user.)
- Host window on a 1x screen: a 1080p view is 1920×1080 pt, as big as the screen; the window may
  extend past the visible frame. Spike 4a: fully offscreen freezes; partially offscreen untested.

## Decisions (user, 2026-09-26)

- Preview: image tiles (non-interactive) from the alpha-0 host window. Accepted loss of page
  interaction in the preview.
- Custom W×H resolution: in phase 2.
