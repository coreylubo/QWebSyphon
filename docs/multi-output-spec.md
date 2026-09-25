# Multiple Syphon outputs in one app — spec

Status: draft, reviewed once by Codex (findings folded in), not started. Branch base:
`t3code/osc-multiple-syphon-websites` (PR #1 on coreylubo/SyphonWebOSC).

## Goal

One SyphonWeb process publishes N independent Syphon sources. Each source ("output") shows its own
web page and can be switched independently from the UI and from OSC. This covers the common case
that `--profile` instances cover today (profiles keep working).

## Current architecture (what changes)

Everything assumes exactly one output:

| Piece | Where | Single-output assumption |
|---|---|---|
| `WebViewState` | `webView.swift` | URL, loading, loadError, resolution, backing scale, transparency, Syphon name, Metal texture/context/region, `frameServer`, weak `webView`. One instance, created in `AppDelegate`. Also creates an unused `CAMetalLayer` in `initMetal` — drop it. |
| `WebView` (NSViewRepresentable) | `webView.swift` | Creates the WKWebView in `makeNSView`; starts a 60 Hz `Timer.scheduledTimer` (default run-loop mode) calling `captureFrame(webView:)`. |
| Capture | `webkitFrameCaptureExtention.swift` | CPU `layer.render(in: CGContext)` scaled by backing scale, then `texture.replace`, then `publishFrameTexture` — all serial on the main thread. |
| Layout scale | `WKWebView.setLayoutScale` in `webView.swift` | Per-view private SPI `_viewScale` + `_layoutMode = 2` so the CSS viewport = output pixels while the view is output/backingScale points. Falls back to `pageZoom`, which renders `vw` font sizes at the wrong size. |
| Settings | `webView.swift` (`@Published` + per-key `didSet` into `appDefaults`), `settingsView.swift` | Keys `outputResolution`, `transparentBackground`, `syphonName`, `oscPort` are per profile suite, not per output. Current URL is not persisted. |
| OSC | `oscServer.swift` | `/syphon/url`, `/syphon/bookmark <int|string>`, `/syphon/bookmark/<label>` (prefix match, accepts arbitrary suffixes), `/syphon/refresh` all target the one state. Pure resolver helpers at the top of the file. |
| UI | `mainView.swift` | Sidebar (bookmarks) + one preview + `StatusBar`. Double-click navigates the one output. Live globe compares against the one `state.url`. |
| Stats | `statusBar.swift` | `OutputStats` counts frames for one output; 1 s tick; OSC activity recorded lock-free. |
| Lifecycle | `main.swift` | Backing scale read from the main window; `applicationWillTerminate` stops the one server. |

Bookmarks (SQLite, `bookmark.swift`, `database.swift`) are already output-agnostic.

## Proposed design

### Model

- `Output` (split out of `WebViewState`): stable `id: UUID`, `name` (display + Syphon server name,
  unique across outputs), `url`, `loading`, `loadError`, `resolution`, `transparentBackground`,
  `frameServer`, per-output texture / `CGContext` / region, weak `webView`, the host view's own
  `backingScale`, per-output stats (fps, capture ms p95, hasClients).
- App-wide `AppModel`: `outputs: [Output]`, `selectedOutputID`, shared `MTLCommandQueue`, OSC.
- **Backing scale is per output**, read from the window hosting that output's web view (a view in
  a different window / screen can have a different scale). `_viewScale` and the capture scale are
  applied and verified per web view.
- Persistence: one `outputs` JSON value in `appDefaults` (per profile suite): id, name, url,
  resolution, transparent. Settings mutate the model and write the whole JSON atomically — no
  per-key `didSet` writes left fighting the model.
- Migration (per profile suite): if `outputsMigrationVersion` is absent, build output #1 from the
  legacy keys (`syphonName`, `outputResolution`, `transparentBackground`; URL = the current default,
  since URL isn't persisted today), write and read back `outputs`, then set
  `outputsMigrationVersion = 1`. Never overwrite a valid (even empty) `outputs` array; on corrupt
  JSON, log and fall back to a single default output without writing. Keep the legacy keys for
  rollback.
- Output #1 created by migration is the **legacy output**: its UUID is stored as
  `legacyOutputID`. Removing it is allowed; legacy OSC addresses then log "no legacy output" and do
  nothing (never silently retarget).
- Max output count: set from measurement, not assumed (see Performance). Start with a hard cap of 4.

### Rendering — needs a spike first

Every output's WKWebView must keep painting at 60 fps. `layer.render(in:)` only snapshots the
layer tree WebKit last committed; it does not make WebKit paint. WebKit throttles or stops painting
(and throttles rAF / timers) for views that are hidden, zero-sized, detached, in an ordered-out or
minimized window, occluded, or in an inactive app, so captures go stale or blank. Even a visible
view can yield a stale frame, so the spike must check content freshness, not just non-blank pixels.

**Phase 0 spike** (no product code; results appended here). Test page: a `requestAnimationFrame`
counter drawn as large text plus a moving block. Per case, record rAF rate (from JS), whether
captured pixels change every frame (compare consecutive frames), capture ms p50/p95:

1. Tiles: every output's web view visible in the main window as a tile (`_viewScale` keeps layout
   at output size while the view is small). **Likely winner** — every view is genuinely on screen.
2. Non-selected views stacked behind the selected one (occluded by a sibling).
3. Non-selected views at `alphaValue = 0.01` / `isHidden = true`.
4. Non-selected views in a separate borderless window positioned offscreen, or at alpha 0.
5. Each of the above with the app inactive (another app frontmost) and with the main window
   partially covered — show control runs this way.

Private anti-throttling preferences are not a reliable fallback; only note them if found.

### Capture loop and performance

- One capture driver on the main thread (run-loop `.common`, so menus/drags don't pause output —
  this is a deliberate behavior change from today's default-mode timer, note it in the commit).
- Per tick, capture outputs in order with a deadline: if the tick's elapsed time passes ~14 ms,
  the remaining outputs are skipped this tick and captured first next tick (round-robin), so one
  heavy output can't starve the rest and the UI stays responsive.
- Policy: optionally skip capture for outputs with no Syphon clients (`hasClients == false`), with
  a setting to keep capturing (some clients connect late and expect a warm frame). Default: keep
  capturing.
- Measured today on this Mac (single output): ~4 ms at 720p, ~8–13 ms at 1080p for `getFrame`
  alone. The end-to-end per-output cost also includes the 3.7 MB (720p) / 8.3 MB (1080p)
  `texture.replace` upload, Syphon publish, and WebKit/UI work. **Two 1080p outputs may not fit in
  16.7 ms.** The spike measures end-to-end p95 with 1, 2, 3, 4 outputs at 720p and 1080p; the
  supported mix and the cap come from that table.
- If CPU capture can't sustain the needed mix, the follow-up is GPU capture via ScreenCaptureKit
  (capture the window once, GPU-crop each output tile) — out of scope here, but the tile layout
  keeps that option open.

### Syphon servers

One `SyphonMetalServer` per output (supported; Syphon requires one server per video output).
Names must be unique for clients to tell them apart. Renaming recreates that output's server (as
today). Stop **every** server in `applicationWillTerminate` and when an output is removed.

### UI

- If the spike picks tiles: the preview area becomes a tile strip/grid of all outputs, each tile
  labeled with the output name, fps and client dot; clicking a tile selects it. No second large
  preview. Selected output's controls/settings sit beside the tiles.
- `+` adds an output; tile context menu: rename, duplicate, remove (confirm).
- Sidebar double-click / "Open" loads the bookmark into the **selected** output; context menu adds
  "Open in ▸ <output>".
- Live indicator: bookmarks live in any output show the output name/initial; bold when live in the
  selected output.
- Status bar: selected output's stats plus "N outputs · M with clients".
- Settings: global section (OSC port, profile) + selected-output section (name, resolution,
  transparency).

### OSC

Legacy addresses keep working and always target the legacy output (by `legacyOutputID`, never by
array index or selection):

```
/syphon/url <string>
/syphon/bookmark <int|string>
/syphon/bookmark/<label>
/syphon/refresh
```

Output-scoped addresses:

```
/syphon/<output>/url <string>
/syphon/<output>/bookmark <int|string>
/syphon/<output>/bookmark/<label>
/syphon/<output>/refresh
```

- `<output>` = 1-based position or the output's name slug. Slug rules = bookmark label rules
  (`[A-Za-z0-9_-]`, not all digits), unique across outputs; `url`, `bookmark`, `refresh` are
  reserved and rejected as output names.
- Parse by splitting on `/` and matching exact segment counts: legacy `["syphon", cmd]` or
  `["syphon", "bookmark", label]`; scoped `["syphon", out, cmd]` or
  `["syphon", out, "bookmark", label]`. Anything else (extra segments, empty segments, unknown
  output, out-of-range index) logs and is ignored. This also tightens today's prefix-matched
  `/syphon/bookmark/<label>`.
- Parsing and resolution are pure functions (like the existing helpers in `oscServer.swift`) so
  they can be tested.

## Phases (each a commit, each shippable)

0. **Spike** — findings + measurement table appended to this doc. No product code.
1. **Refactor to `Output` + `AppModel` with exactly one output.** JSON persistence + migration
   (with marker), legacy output ID, shared command queue, capture driver in `.common` mode (the
   only intended behavior change), drop the unused `CAMetalLayer`. Verify OSC, capture,
   transparency, resolution, Syphon name, profiles unchanged.
2. **Multiple outputs, complete model.** Add/remove/rename/duplicate with all invariants (unique
   names, reserved words, cap, server lifecycle, legacy output removal), per-output backing scale,
   deadline/round-robin capture, the spike's rendering approach, minimal UI to add/select/remove
   (tiles). Verify each source updates independently with a Syphon client and record fps per
   output count.
3. **UI polish.** "Open in" menu, per-output live indicators, status-bar summary, per-output
   Settings section.
4. **OSC output-scoped addresses** + strict parser + Settings command reference + README.

## Tests

The package can't host a test target (the Syphon header path is an `unsafeFlags` hack on the
executable target), so keep pure logic in functions and verify with a `#if DEBUG` startup
self-check (pattern: `checkBookmarkLabelValidation()` in `bookmark.swift`) covering:
- JSON migration: legacy keys → one output; existing valid array untouched; empty array
  untouched; corrupt JSON → fallback without write; marker set only after a successful write.
- OSC route parsing: every legacy and scoped form, extra/empty segments, reserved names, index
  0 / negative / out of range, unknown slug.

## Open questions (ask the user before phase 1)

1. Preview: tiles of all outputs (likely required by the spike) vs one large selected preview?
2. Is a cap of 4 outputs enough, and what mix of 720p / 1080p is expected in a show?
3. Keep `--profile` instances once multi-output works, or remove them?
4. Skip capturing outputs that have no Syphon clients (saves CPU), or always capture?

## Verification rules (carry over)

- Launch tests with `SYPHONWEB_DB_PATH=/tmp/...` and a throwaway `--profile NAME`
  (`defaults write SyphonWeb.profile.NAME oscPort -int 9xxx` first); delete only the suites you
  create. Never `defaults delete SyphonWeb` wholesale.
- Never kill SyphonWeb processes you didn't start (the user runs instances from `SyphonWeb.app`).
- In zsh, `rm -f /tmp/x*` with no matches aborts the command chain — use `setopt nullglob`.
- Syphon lister/client programs: `FW=third_party/Syphon.xcframework/macos-arm64_x86_64;
  swiftc main.swift -F $FW -I $FW/Syphon.framework/Headers -framework Syphon -Xlinker -rpath -Xlinker $FW`.
  `SyphonServerDirectory.shared().servers` (wait ~2 s on the run loop) lists servers;
  `SyphonMetalClient(serverDescription:device:options:newFrameHandler:)` counts frames.
- OSC tests: raw UDP via python3 (address, type tags `,s` `,i` `,f` `,h`, NUL-padded to 4 bytes).
- Agents can't click the UI; list unverified interactions for the user.
