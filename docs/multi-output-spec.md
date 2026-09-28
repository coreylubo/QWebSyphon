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

## Decisions (user, 2026-09-25)

1. Preview: **tiles of all outputs**, click to select. No separate large preview.
2. Count: **cap of 4, typically 2**. Resolution mix not fixed; the spike's table decides what's
   supported at 60 fps.
3. **Keep `--profile`** instances alongside multi-output.
4. Idle capture: **per-output toggle** "Capture without clients" (default on), in that output's
   settings.
5. (After the spike) **Outputs must keep running when the SyphonWeb window is fully covered.**
   Design: all output web views live stacked in one invisible (alpha 0) window; the main window's
   tiles show the captured frames (refresh ~15 Hz to keep it cheap). Needs its own checks:
   full-screen apps on other Spaces, several displays, screen lock/sleep (still freezes — show
   machines should disable both).
6. (After the spike) **CPU capture is fine for now**; 2×1080p at ~54 fps is acceptable. The real
   show setup is a main output plus a narrow "toast" column, so resolution must be **per-output
   and custom (W×H)**, not only 720p/1080p. Capture cost is ~85% `layer.render` and scales with
   pixel count, so a 960×1080 column should cost about half of 1080p (~4 ms, estimate — measure
   in phase 2); 1080p + 960×1080 ≈ 12 ms fits the 12 ms deadline.

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

## Phase 0 findings (2026-09-25)

Spike source: `/tmp/syphonweb-spike/main.swift` (standalone AppKit app, `key=value` args, e.g.
`./spike case=tiles dsf=1 n=2 res=1080,720 driver=dl`; `./spike client secs=5` counts frames per
`Spike N` server). Capture path copied from the product: RGBA premultipliedLast DeviceRGB
`CGContext`, CTM scaled, `layer.render(in:)`, `texture.replace`, `publishFrameTexture`, one shared
`MTLCommandQueue`, one server per output, `_layoutMode = 2` + `_viewScale`. Driver: one 60 Hz
tick on the main run loop in `.common`, all outputs captured serially.

Machine: M1 Max, macOS 15.7.9, main window on a 2x screen (4K at 1920x1080 pt). Test page: rAF
counter encoded as 24 bit cells + large text + moving block. **Fresh fps** = captures whose decoded
counter differs from the previous capture. **Sharp** = adjacent-pixel contrast on a 1 px stripe
pattern (1.00 = 1:1 with output pixels, 0.50 = upscaled from half resolution). `ms` = per-output
`getFrame` (render + replace); publish was 0.03–0.08 ms everywhere and is omitted.

### Cases (2 outputs, 720p each; per output unless noted)

| Case | rAF | Fresh fps | Published | ms p50 / p95 | Sharp | Tick p95 | Verdict |
|---|---|---|---|---|---|---|---|
| 1. Tiles 480x270 pt, `_viewScale` only | 60 | 60 | 60 | 3.4 / 3.5 | **0.50** | 7.2 | paints, but half-res |
| 1. Tiles 480x270 pt + `_overrideDeviceScaleFactor` = out px / tile pt | 60 | 59.7–60 | 60 | 3.6 / 3.9 | 1.00 | 7.7 | **works** |
| 2. Stacked, non-selected occluded by sibling | 60 | 59.8–60 | 60 | 3.6 / 3.8 | 1.00 | 7.7 | works |
| 3a. Non-selected `alphaValue = 0.01` | 60 | 45–57 | 60 | **10.9 / 11.3** | 0.67 | 15.3 | no: 3x cost, alpha baked into capture |
| 3b. Non-selected `isHidden = true` | **0** | 0 | 60 | 0.7 / 0.8 | – | 4.7 | no: blank frames |
| 4a. Non-selected in borderless window at (-20000, -20000) | **0** | 0 | 60 | 3.5 / 3.6 | 1.00 | 7.4 | no: frozen |
| 4b. Non-selected in borderless window, `alphaValue = 0`, on screen | 60 | 54–60 | 60 | 3.6 / 3.8 | 1.00 | 7.6 | works |

Case 5 (inactive = Finder frontmost; partial = another app's window over the right 75 % of the
main window, incl. one whole tile; full = main window fully covered):

| Case | rAF | Fresh fps | Tick p95 | Verdict |
|---|---|---|---|---|
| Tiles, inactive | 60 | 58.4–60 | 7.9–8.2 | works |
| Tiles, partially covered (tile 2 fully hidden) | 60 | 60 | 7.7 | works (throttling is per window, not per view) |
| Tiles, fully covered (active or inactive) | **0** | 0 | 7.8 | frozen |
| Stacked, inactive | 60 | 49–51 | 7.8 | works, one noisy run |
| Stacked, fully covered | **0** | 0 | 7.7 | frozen |
| **Today's product shape** (1 output, fully covered) | **0** | 0 | 3.9 | frozen — pre-existing |
| 4b alpha-0 window, main window fully covered | 60 (alpha-0 window) / 0 (main) | 60 / 0 | 7.8 | the alpha-0 window keeps painting |
| All outputs in an alpha-0 window at `.screenSaver` level, whole screen covered, inactive | 60 | 60 | 9.6 | works; tiles show captured `CGImage`s |
| Anything with the screen locked / display asleep | **0** | 0 | – | frozen (lock shield occludes everything) |

### Budget (winning case: tiles + device-scale override, display-link driver)

| Outputs | Tick p50 / p95 ms | Ticks/s | rAF | Fresh fps per output | Main-process CPU |
|---|---|---|---|---|---|
| 1 × 720p | 3.7 / 3.8 | 60 | 60 | 59.9 | 25 % |
| 2 × 720p | 7.3 / 7.7 | 60 | 60 | 60 | 50 % |
| 3 × 720p | 10.9 / 11.7 | 60 | 60 | 58.8 | 74 % |
| 4 × 720p | 14.6 / 15.2 | 60 | 60 | **46.7** | 97 % |
| 1 × 1080p | 8.1 / 8.4 | 60 | 60 | 60 | 52 % |
| 2 × 1080p | 17.8 / 18.9 | **54** | 54 | **54** | 102 % |
| 3 × 1080p * | 23.7 / 26.1 | 40 | – | ≤ 40 | 99 % |
| 4 × 1080p * | 31.3 / 32.8 | 32 | – | ≤ 32 | 102 % |
| 1080p + 720p * | 11.4 / 12.2 | 60 | – | – | 71 % |
| 1080p + 2 × 720p * | 14.8 / 15.6 | 60 | – | – | 92 % |
| 2 × 1080p + 2 × 720p * | 23.1 / 24.4 | 42 | – | ≤ 42 | 100 % |

\* Measured after the screen locked (the user was away): capture cost is valid (unlocked vs locked
agreed within 0.1 ms on 2 × 720p and 1 × 1080p), but rAF/freshness could not be measured. Treat
fresh fps as ≤ ticks/s.

Per-output cost is linear: ~3.65 ms at 720p, ~8.1 ms at 1080p (~8.9 ms once the main thread is
saturated). About 85 % of it is `layer.render(in:)` (720p render p50 3.1 ms of 3.65 ms); the
`texture.replace` upload is ~0.55 ms and publish < 0.1 ms.

Syphon client check (2 × 720p tiles, `SyphonMetalClient` per server, 5 s): `Spike 1` 301 frames
(60.2 fps), `Spike 2` 301 frames (60.2 fps), both `bgra8Unorm` 1280x720, frame counter decoded from
every received texture. Each server delivers independently. (Run while locked, so the decoded
counter was constant; freshness was proven by the unlocked runs above.)

### Recommendation

- **Tiles (case 1) with a per-view `_overrideDeviceScaleFactor` = output px / tile pt** (KVC key
  `overrideDeviceScaleFactor`, guard `_setOverrideDeviceScaleFactor:`), `_viewScale` = tile pt /
  output px, capture CTM scale = output px / tile pt. Without the override, a 480 pt tile on a 2x
  screen is rasterized at 960 px and the 720p output is upscaled (sharp 0.50). Pages then see
  `devicePixelRatio` = 2.67 (720p) / 4 (1080p) at 480 pt tiles.
- Stacked (case 2) also works and is the fallback if the tile layout has to change; hidden,
  low-alpha and offscreen-window hosting do not.
- **Supported at 60 fps with fresh frames:** 1–3 × 720p, 1 × 1080p, 1080p + 720p.
  1080p + 2 × 720p fits the tick (15.6 ms p95) but leaves no headroom — expect drops like
  4 × 720p. **Not supported:** 2 × 1080p (54 fps), 4 × 720p (47 fresh fps), 3+ × 1080p.
- Budget rule for the capture driver: the sum of per-output costs should stay ≤ ~12 ms; beyond
  that the page's own rAF and WebKit's main-thread commits starve even while ticks stay at 60/s
  (4 × 720p: 60 ticks/s, 47 fresh fps). Use the deadline/round-robin with a ~12 ms deadline and
  keep the cap at 4, surfacing per-output fps so an overloaded mix is visible.
- More headroom needs a different capture path, not upload tweaks: IOSurface-backed zero-copy
  saves at most ~0.55 ms per 720p output. GPU capture (ScreenCaptureKit) or rendering off the main
  thread is the follow-up if 2 × 1080p is required.

### Surprises

1. **A fully covered window freezes output — already true of today's single-output app.** WebKit
   throttles per window occlusion, so the tile approach (like the current app) needs the
   SyphonWeb window at least partly visible. Partial cover, a fully hidden tile and an inactive
   app are all fine. Screen lock / display sleep freezes everything. Show machines should disable
   display sleep and screen lock.
2. **An alpha-0 borderless window keeps painting when everything else is covered** (window server
   still reports it `.visible`), including at `.screenSaver` level under a full-screen cover with
   the app inactive. That enables a cover-proof design: host all web views stacked in an alpha-0,
   mouse-transparent, all-Spaces window and show tiles from the captured frames. Cost: a
   `CGImage` tile update at 60 Hz adds ~1 ms per 720p output (copy-on-write of the context) —
   2 × 720p 8.8 ms p50 vs 7.3 ms; at 15 Hz tile refresh it's ~free. Untested: full-screen apps on
   other Spaces, Mission Control, multiple displays. Decide whether "survives full cover" is a
   requirement before Phase 2.
3. **Viewport units are 0 after `_layoutMode`/`_viewScale` unless the view is resized
   afterwards.** With a fixed frame, `vw`/`vh` resolved to 0 and the initial containing block
   stayed at the view's point width, while `innerWidth` was already correct. Resizing the frame by
   1 pt and back fixes it. The product probably avoids this through `resizeWindow` in
   `updateNSView` (not verified); tiles with fixed frames must nudge the size after setting the
   scale.
4. Main-thread saturation throttles the page too: at 2 × 1080p the page's own rAF drops to 54,
   matching the tick rate.
5. `alphaValue = 0.01` views are captured with that alpha applied and cost 3x (10.9 ms at 720p).
6. `NSView.displayLink` (macOS 14) and a `.common` `Timer` performed the same; the display link
   had slightly steadier per-second rAF (min 60 vs 59). Either is fine.

## Phase 1 notes (2026-09-25)

Deviations and interpretations in the phase 1 refactor:

- `outputs` is stored as a JSON **string** (readable in `defaults read`), keys sorted.
- OSC activity (last address/time, lock-free) moved from `OutputStats` to `OSCController`: it is
  app-wide, recorded before routing. `OutputStats` is per output (fps, hasClients).
- `captureWithoutClients` is honored by capture (default true, no UI).
- In-memory fallbacks never persist: corrupt `outputs`, `outputs` missing while the marker is
  set, an empty array, or more than one output (phase 1 keeps the legacy-or-first one). Settings
  changes in those sessions are not saved, so stored data is never overwritten.
- Behavior changes: capture runs in `.common` mode (continues during menu tracking/drags); the
  current URL is persisted, so the app reopens the last page instead of the default.
- Pre-existing, not fixed: `NSLog("Loading URL: \(url)")` etc. pass the URL as the format string,
  so `%` escapes in a URL are read as format specifiers (log shows `data:text/html,` for a
  percent-encoded data: URL).

## Phase 2 notes (2026-09-26)

Rendering host + capture driver (cluster 2):

- `OutputHost` (`outputHost.swift`, retained by `AppDelegate`) owns one borderless alpha-0,
  mouse-transparent, never-key `.screenSaver` window that follows the main window's screen. Every
  output's `WKWebView` sits in it at (0,0), stacked; window size = largest view.
  `OutputWebViewController` (one per output, retained by the host by id) owns the web view, is its
  navigation delegate and owns its Combine subscriptions. The host diffs `model.$outputs` by id.
- **The viewport-unit nudge (surprise 3) must run on a later runloop turn than
  `setLayoutScale`.** Measured with a `100vw × 100vh` probe: nudging +1 pt and back synchronously
  right after setting the SPI left vw/vh at 0; nudging on the next `DispatchQueue.main.async`
  turn gives 1280×720 / 960×1080, and it holds across later navigations (OSC `/syphon/url`).
- Pages report `devicePixelRatio` = 2 on a 2x screen (view = output px / 2 pt, `_viewScale` 0.5),
  as in phase 1.
- Host window origin: the screen's `visibleFrame` origin, pulled down/left only as far as needed to
  stay on that screen. On a 1x screen a 1080p view (1920×1080 pt) covers the whole screen,
  menu bar included; a custom size larger than the screen extends past it (partially offscreen:
  untested).
- Size/scale changes read the incoming values via `CombineLatest3(resolution, customSize,
  backingScale)`, not the output's properties, because `@Published` emits on willSet.
- Tile refresh uses a per-output `tileDirty` flag set by `captureFrame`, not `stats.frameCount`
  (which the 1 s stats tick resets).
- Main window gets `.miniaturizable` as well as `.resizable`, so the cover-proof check can minimise
  it.
- Smoke test (2 outputs, 1280×720 + custom 960×1080, M1 Max, 2x screen): both servers listed,
  each delivered 301–302 frames in 5 s (60.2–60.4 fps) at its own size.

### Phase 2 measurements (2026-09-26)

Machine: MacBook Pro, M1 Max, macOS 15.7.9 (build 24G830). Branch `t3code/multi-output-phase2` at
the tip present in the worktree (uncommitted `appModel.swift`/`outputHost.swift`/etc.), built with
`swift build -c release` and `swift build` (debug). No product code was changed by this pass.

**Environment caveat (discovered, not induced):** for this entire session both attached displays
reported `Display Asleep: Yes` (`system_profiler SPDisplaysDataType`), and macOS reported the
screen saver/lock state active throughout, despite `caffeinate -u`/`-d`. This was verified to be a
pre-existing environmental condition, not a regression: running the untouched phase-0 spike binary
(`/tmp/syphonweb-spike/spike case=alpha0all n=1 res=720`) in the same session reproduces
`raf=0.0 fresh=0.0` while `pub=60.1` — i.e. the exact "screen locked" row already in the phase 0
table above. Per that table, this is a documented, known-unsupported condition ("screen locked /
display asleep... freezes... not tested"), not something phase 2 introduced. Consequence: every
measurement below that depends on the page's own `requestAnimationFrame` loop (fresh fps) could
not be captured live; **published fps (Syphon delivery) and CPU are unaffected** — the phase 0
table shows these hold within 0.1 ms locked vs unlocked, and that held again here.

**Method:** throwaway profile `--profile p2v`, `SYPHONWEB_DB_PATH=/tmp/sw-p2v.db`,
`defaults write SyphonWeb.profile.p2v oscPort -int 9473`. Outputs seeded directly via
`defaults write SyphonWeb.profile.p2v outputs -string '<json>'` (`captureWithoutClients: true`),
each output's `url` a `data:text/html;base64,...` page reusing the phase 0 spike's rAF-counter
page (25 bit cells + big text + moving block) or a flat-color static page for the OSC checks.
Syphon client: a copy of the phase 0 spike (`/tmp/syphonweb-spike/client.swift`) with its server
filter changed from `hasPrefix("Spike")` to `hasPrefix("P2VTest")` (this session's output names),
compiled with the spec's `swiftc` recipe, plus two additions for this pass: a full-frame GPU-blit
+ `CGImage` PNG dump (`dumpfull=1`) and a full-frame alpha min/max scan (`alphastats=1`). CPU via
`ps -o %cpu= -p <pid>`, sampled once per second during the client's measurement window.

**Budget table** (published fps per output = Syphon client's `fps=`; CPU = `ps %cpu` samples,
main SyphonWeb process only; fresh fps not measurable this session, see caveat above):

| Outputs | Published fps (each) | Main-process CPU |
|---|---|---|
| 1 × 720p | 60.0 | ~31–35 % |
| 2 × 720p | 60.2 / 60.2 | ~51–54 % |
| 3 × 720p | 60.2 / 60.2 / 60.2 | ~73–76 % |
| 1080p + 720p | 59.2 / 59.0 | ~79–82 % |
| 1080p + custom 960×1080 | 55.3 / 55.3 | ~79–84 % |
| 2 × 1080p | 33.3 / 33.3 | ~65–76 % |

All rows: both/all servers listed by `SyphonServerDirectory`, each delivering independently, sizes
confirmed via the client's reported texture dimensions (e.g. `960x1080` for the custom column).
**Round robin fairness (2 × 1080p, over budget as expected):** both outputs delivered the same
frame count (200/200 over 6 s) — the round-robin deadline is starving neither output, matching the
design intent, though the absolute rate (33.3 fps) is well below phase 0's unlocked 54 fps figure
for the same mix; the gap is consistent with this session's displays being asleep throughout
(main-thread work under full occlusion competes differently) rather than a phase 2 regression —
not re-verified with the display awake.

**Cover-proof (decision 5):** not run as a discrete "before/after" test — the automated attempt to
open and position a TextEdit window over the main window via `osascript`/System Events hung
(likely gated on an Accessibility permission prompt with no one present to approve it); the
process was killed and TextEdit quit without saving. Listed as unverified for the user. That said,
every budget-table row above ran with both physical displays already asleep (full occlusion, the
most extreme case in the phase 0 matrix) for its entire duration, and every server kept
publishing at its expected rate throughout — so the "publish continues under full occlusion" half
of decision 5 was exercised, incidentally, in every run; only the tile-freshness half needs the
user to re-check with the screen awake.

**Transparency:** one output, `transparentBackground: true`, a transparent-body test page.
`alphastats` (full-frame min/max over the received `bgra8Unorm` texture): `minAlpha=0 maxAlpha=255`
— the received texture has both fully transparent and fully opaque pixels. **Pass.**

**OSC — legacy targeting by id, not position/index:**
- Two outputs, `P2VTest1` (red, position 1) and `P2VTest2` (green, position 2), with
  `legacyOutputID` set to `P2VTest2`'s id. `/syphon/url` (raw UDP, `,s` type tag) with a blue
  page: `P2VTest2` (the legacy-by-id output, at position 2) turned blue; `P2VTest1` (position 1)
  stayed red. Confirms targeting is by stored id, not array position. **Pass.**
- `legacyOutputID` set to a UUID not present in `outputs`: `/syphon/url` logged
  `"OSC: no legacy output, ignoring /syphon/url"` and neither output's content changed (no new
  `Loading URL` log line). **Pass.**

**Debug build self-checks:** `swift build` (debug) + launch logged, in order, `Bookmark label
validation self-check passed`, `Outputs migration self-check passed`, `Outputs model self-check
passed`. **Pass.**

**Persistence (no rewrite of a clean or already-repaired config):**
- Fresh profile's first launch migrated legacy keys to one output; relaunching with that same
  `outputs` value unchanged (`defaults read ... outputs` byte-identical before/after, no "needed
  repair" log line). **Pass.**
- Seeded 5 outputs with 2 duplicate names (over `maxOutputs` and with a name collision);
  relaunching logged `"Loaded \`outputs\` needed repair (cap/name/url/size/id); not saved this
  session"`, and `defaults read ... outputs` was still byte-identical to what was seeded (the
  repaired/truncated/deduped copy was never written back). **Pass.**

**Unverified for the user (needs UI clicks, a second display, or an awake/unlocked screen this
session couldn't provide):**
- Tile grid: select, context menu (rename/duplicate/remove), `+` add, cap-at-4 disabling.
- Settings: resolution preset/custom W×H apply flow, "capture without clients" toggle, per-output
  section re-binding on selection change.
- Cover-proof tile *freshness* specifically (vs. the publish-continues result above, which this
  session did exercise) — re-run with the screen awake and unlocked.
- Minimizing the main window (needs either a UI click or Accessibility-permission-gated
  automation; not attempted after the TextEdit automation hung on what looks like the same gate).
- A genuine full-screen app on another Space, and a second physical display — this Mac's second
  reported display was also asleep/inaccessible for the same reason as the primary.
- Screen lock / display sleep is already known-unsupported (freezes) per phase 0; not re-tested,
  and ironically the whole of phase 2's live session ran inside that exact condition.

**Cleanup:** `SyphonWeb.profile.p2v` defaults suite deleted, `/tmp/sw-p2v.db` removed, only the
`SyphonWeb`/`client-p2v`/TextEdit/`osascript`/`caffeinate` processes started by this session were
killed (no other `SyphonWeb` or Syphon-client processes were touched).

### Phase 2 debugging: "upside down" and "1080 doesn't work" (2026-09-26)

Displays awake, 4K HP Z27 at 1920×1080 pt (2x), Stage Manager on. Throwaway profile, test page with
red box top-left ("TOP LEFT"), green top-right, blue bottom-left, a rAF counter and
`innerWidth×innerHeight`. Syphon client dumps the received texture to PNG (memory row 0 first) and
probes its corners. Evidence in `/tmp/sw-dbg/`.

**Orientation: only the tiles were wrong, and only vertically (not mirrored).**
- Received Syphon texture, phase 1 (`63cd9d0`, web view in `NSHostingView`) and phase 2 (host
  window, plain contentView), 720p and 1080p: byte-identical corner probes — row 0 left = blue,
  last row left = red, last row right = green. Row 0 is the page's **bottom**, which is the
  bottom-up (GL) order Syphon clients expect; phase 1 was reported correct, so phase 2's Syphon
  output was already correct. The flipped/unflipped superview does not matter: `layer.render(in:)`
  draws the web view's layer in its own coordinate space.
- Tiles made `makeImage()` of the same buffer. A `CGImage` is top-down, so the tile showed the page
  upside down (text reads mirrored because it is vertically flipped; left/right were correct).
- Fix: `makeTileImage` (appModel.swift) draws the capture into a small context flipped. Syphon
  path untouched. DEBUG self-check asserts the orientation and the size cap.

**1080: no hard failure reproduced; one 1080-specific phase 2 regression found and fixed.**
- Works: launch at 1080 (60 fps, 1920×1080, `innerWidth` 1920×1080, fresh); 1080 + 720; runtime
  720 → 1080 → 720 → 1080 with a client connected throughout (texture size follows within one
  frame, no freeze); runtime-added and duplicated outputs; real pages. Host window resizes to
  960×540 pt at the bottom-left of the visible frame.
- Regression: the tile refresh kept a full-size `makeImage()` alive, so the next capture copied the
  whole buffer (copy-on-write) and SwiftUI uploaded a full-size image, 15×/s per output. 1080p +
  720p (orient page, release) fell to **45 fps** with tiles vs **60** with the tile refresh
  disabled. Downscaled tiles (≤ 640 px wide, `.none` interpolation, snapshot released before the
  next capture): **60/60** release and debug; `.low` interpolation gave 58.
- Page cost dominates at 1080: apple.com alone at 1080 publishes 30 fps in **phase 1 and phase 2
  alike** (heavy page, not a regression). 2 × 1080 + 720 = 30 fps each (over budget, as the spike
  table says).
- Unverified: whatever the user saw at 1080 if it was not low fps (Settings picker not clicked by
  an agent; the hook that drove the same `resolution`/`customSize` assignments worked).
