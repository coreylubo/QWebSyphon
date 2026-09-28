# Notes round 4 — plan (user notes, 2026-09-27)

Base: `t3code/notes-round4`, stacked on `t3code/gpu-capture` (PR #8).

## Notes → clusters

| Note | Cluster |
|---|---|
| Preview tile stutters (Syphon smooth); high CPU in Activity Monitor | E |
| Banner enter/exit: corner masking artifacts + a flash (not in a browser) | D (diagnosis agent, own branch `t3code/banner-artifacts`) |
| Put notifications on the checkpoint screen (file for later) | F (backlog; GitHub issues are disabled — user chose the backlog doc) |
| Menu bar icon: `macwindow`; status dot is cut off | A |
| Settings: OSC command list looks stale | B |
| Under each output preview: URL / bookmark name; pick a bookmark or type a URL | C |
| Is there an OSC refresh? | answered: `/syphon/<output>/refresh` exists |

## Measurements (sonnet agent, throwaway profile, 2 outputs, GPU path)

- App ~17–19% CPU, WebKit GPU ~11–13%, each WebContent ~4.5%. CPU fallback path: app ~65%.
- `captureWithoutClients` off + no client: app ~5% (WebKit cost unchanged; it is the page).
- Hotspot 1 (~15–20% of a core): AppKit commit copying the SwiftUI tile `Image(CGImage)`
  (`CA::Render::copy_image` → `CGContextDrawImage`) on every tile update.
- Hotspot 2 (~8–9%): `refreshTile` CGContext/CGImage creation from the readback buffer.
- Tile timer is 15 Hz (`AppModel.startCapture`): the stutter. 30 Hz with the current path costs
  +7–10 points, so raising the rate alone is the wrong fix.

## Cluster A — menu bar icon (sonnet; `statusMenu.swift` only)

`statusImage(color:)`: symbol `macwindow`; the dot must sit fully inside the image rect (today
`x = width - d*0.8`, `y = -d*0.1` puts it partly outside and it is clipped). Size the image so the
glyph plus dot fit (e.g. draw the glyph inset, or widen the canvas by the overhang). Keep the
template-tint technique. Update the comment.

## Cluster B — OSC command reference (sonnet; `oscServer.swift` `oscCommandReference`, `settingsView.swift`)

All listed routes still parse, but the unscoped `/syphon/<command>` forms ("legacy output") read as
dead. New reference:
- Generic scoped commands: `/syphon/<output>/url|bookmark|bookmark/<label>|refresh|enable`.
- Per output, its concrete prefix (`/syphon/<name or index>/…`) once, with its commands.
- Per labelled bookmark: `/syphon/<output>/bookmark/<label>` (not the unscoped form).
- One footnote: unscoped `/syphon/<command>` still works and targets `<legacy output name>`
  (omit when `legacyOutput` is nil). Parsing unchanged (back-compat for existing QLab cues).
- Test: `oscCommandReference` is app-target; if the generation logic moves into Core (pure over
  `(name, isAddressable, index)`), add a Swift Testing case.

## Cluster C — URL row under each tile (sonnet; `outputTiles.swift`, `mainView.swift` call site)

Replace the footer `Text(playingName ?? host)` with:
- A `TextField` (caption, `.lineLimit(1)`, truncating middle) that shows `playingName` when the
  output is on a bookmark, else the URL; on focus it shows the full URL for editing; Return calls
  `output.navigate(to:)` (normalizes, clears `bookmarkID`); Escape / focus loss restores.
- A trailing `Menu` (bookmark icon, borderless) listing bookmarks (same order/source as the
  sidebar); choosing one calls the existing `onDropBookmark(id)` path (`open(bookmark:)`).
- Disabled outputs: field and menu disabled? No — loading a URL into a disabled output only
  stores it (existing `load(_:enabled:)` guard), so leave them enabled.
- Tile tap-to-select must not steal clicks from the field/menu.

## Cluster D — banner artifacts (Opus diagnosis agent, running)

Reproduce with a local page (border-radius, overflow hidden, backdrop-filter, animated
width/radius/opacity), compare GPU (CARenderer) vs CPU path vs browser, find the property and fix
in `renderLayer` if sound. Merged into this stack after review.

## Cluster E — cheap, smooth tile previews (Opus agent; `webView.swift` tile path, `outputTiles.swift` preview view; after C and D land)

Show the tile without a CPU image copy: downscale into an IOSurface-backed `MTLTexture` per
output and display it through a layer (`NSViewRepresentable` whose layer `contents` is the
IOSurface, re-set per update / `contentsChanged`), replacing `previewImage: CGImage` + readback.
Then drive tiles at 30 Hz (or the capture rate) only for visible tiles; skip entirely when the main
window is hidden/occluded. Keep the CPU-capture fallback working (it can keep the CGImage route).
Keep checkerboard/transparency, the disabled-state and stale-frame rules from PR #8's fixes.
Measure before/after with the same method (throwaway profile, `top`, `sample`).

## Cluster F — backlog (orchestrator)

`docs/backlog.md`: "Render the purchase notifications inside the checkpoint page, so QLab doesn't
composite a second 60 fps output."

## Order

A, B, C in parallel (one worktree, `git commit --only -- <paths>`). D is already running on its own
branch. E after C and D (same files). F inline. Then build, `swift test`, push, PR, Codex review.

## Codex review (folded in)

1. B: `oscCommandReference` gets the legacy output passed in (`model.legacyOutput`); the settings
   view's per-bookmark rows move into the generated reference as scoped routes per output (name if
   addressable, else 1-based index). Document `/bookmark` args exactly: string (label, then name)
   or integral int/float sidebar position; `/bookmark/<label>` takes none, label only.
2. C: the tile's parent `.onTapGesture` must not swallow field/menu clicks (move selection to the
   preview + name row, or use `.simultaneousGesture` only there). Menu uses sidebar order
   (favorites, then the rest).
3. E: double-buffer IOSurfaces; only swap `layer.contents` after the command buffer completes;
   never write the surface currently displayed. Tile textures are `.rgba8Unorm` today; use BGRA
   (`.bgra8Unorm`) for the IOSurface tile, verify premultiplied alpha and orientation. Allocation:
   `IOSurface` with aligned bytes-per-row, `makeTexture(descriptor:iosurface:plane:)`, usage
   includes shaderWrite. A generation counter invalidates late completions after `initMetal`,
   resize or disable. E also touches `appModel.swift` (tile timer, visibility/occlusion).
