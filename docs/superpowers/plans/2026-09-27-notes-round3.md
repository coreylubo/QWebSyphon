# Notes round 3 — plan (user notes, 2026-09-27)

Base: `t3code/notes-round3`, stacked on `t3code/core-tests-menubar` (PR #4, itself on PR #3).
Clusters A–D ship as one PR; the rename (E) is its own PR on top.

## Notes → clusters

| Note | Cluster |
|---|---|
| "SyphonWeb-Menubar" input in QLab | none: the Syphon server from the agent's `--profile menubar` test run. Not in the code. |
| Checkerboard behind transparent content in the tile preview | B |
| New link loads black until the resolution changes; wrong page size after custom → preset | A |
| Rename app/project to QWebSyphon | E |
| Default URL google instead of puppy.surf | D |
| About: The Great Experience Company + credit the original dev | D |
| Sidebar: icon/bold only for the selected output's bookmark | C |
| Gear popover danger zone "Delete Output"; Remove → Delete everywhere | B |
| Questions (capture without clients; navigate a page; bookmarks vs favorites; custom URL) | answered in chat, filed as issues |

## Cluster A — black after navigation / stale size (Opus)

Root cause from the diagnosis agent (pending). Fix in `outputHost.swift` / `webView.swift` at the
shared path (every navigation and every size change), not per caller. Verify: throwaway profile,
open bookmark, drag, OSC `/url`; custom W×H then back to 720p/1080p; check both the tile and a
Syphon client dump. Also retest the earlier "1080p blank" report.

## Cluster B — tiles (sonnet; owns `outputTiles.swift`, remove/delete call sites)

- Checkerboard under the tile image when `output.transparentBackground` is on. SwiftUI only:
  a small tiled pattern (e.g. `Canvas` or an `ImagePaint` of a 2×2 checker `Image`) in the tile's
  background, clipped to the tile image's aspect-fit rect. Off when transparency is off (black stays).
- Gear popover: bottom "Danger Zone" section with a destructive "Delete Output…" button that
  closes the popover and triggers the existing confirmation. Disabled when it is the last output
  (same rule as the current Remove).
- Rename every user-visible "Remove Output" / "Remove" (tile context menu, confirmation title and
  button) to "Delete". Model method name `removeOutput` stays.

## Cluster C — sidebar (sonnet; owns `mainView.swift` `BookmarkRow` / `SidebarContent`)

- Globe icon + bold only when the bookmark is live in the **selected** output (via
  `liveBookmarkIDs`, `live[bookmark.id]?.contains(selectedOutputID)`).
- Muted "(Overlay)" text stays for every output playing it, so other outputs' bookmarks remain
  identifiable without the icon. (Decision needed.)

## Cluster D — defaults + About (sonnet; owns `OutputsConfig.swift`, `main.swift`, Credits.rtf)

- `defaultOutputURL = "https://www.google.com"`. Existing persisted outputs keep their URL.
  Core tests that use the constant keep passing.
- About panel: pass `.credits` (NSAttributedString, link attributes) and
  `.applicationName` through `orderFrontStandardAboutPanel(options:)` so `swift run` (no bundle)
  shows them too. Text: "The Great Experience Company", then "Based on SyphonWeb by Digit
  (@doawoo)" linking https://github.com/doawoo/SyphonWeb and https://puppy.surf (Digit's site
  — the only place puppy.surf stays), "Thanks to the Syphon project." Credits.rtf updated to match.
- README Credits section updated to match.

## Cluster E — rename to QWebSyphon (separate PR, after decisions)

Recommended scope:
- Display: menus ("About/Quit QWebSyphon"), window titles, About, README, docs, status item.
- Build: SwiftPM product/target `QWebSyphon`, `build_app.sh`, app skeleton dir, Info.plist
  `CFBundleName`/`CFBundleExecutable`. Core module renamed `QWebSyphonCore`.
- Data continuity (must not lose settings/bookmarks): keep the defaults domain (`SyphonWeb`,
  `SyphonWeb.profile.*`) and DB file name as-is, or migrate by copy-on-first-launch (never delete
  the old). Bundle id stays `surf.puppy.SyphonWeb` unless the user wants a new one (new id =
  new defaults domain + TCC prompts again).
- Default Syphon name for new outputs: "QWebSyphon" (existing outputs keep their names, so QLab
  cues keep working). OSC prefix `/syphon/` unchanged.
- GitHub repo rename: only if the user asks.

## Verification

`swift build`, `swift test`, CI green on the PR, Codex review of the PR, user's hand test.

## Diagnosis (cluster A, Opus agent, reproduced)

Cross-site navigation swaps the WebContent process; the new process starts with the layout-mode-2
viewport unset, so `vw`/`vh` resolve to 0 until the next resize. The nudge only runs in
`applySize`. Fix: extract the nudge into `nudgeViewport(size:)` and also call it from
`webView(_:didCommit:)`. Custom → preset and "1080p blank" were not separately reproduced; most
likely the same cause.

## Codex review (folded in)

1. The delete confirmation (`mainView.swift` ~98–107) and popover state (~68–76) live in
   `mainView.swift`, so B and C both touch it: run B and C as one agent.
2. `OutputSettingsSections` needs `canDelete` + `onDelete` plumbing from `MainView` (clear
   `settingsOutputID`, then set `outputPendingRemoval`).
3. `SidebarContent` has `output` + `liveMap`; pass `isLiveInSelectedOutput` to `BookmarkRow`,
   keep `liveOutputNames` for the muted text.
4. About: the menu item targets `orderFrontStandardAboutPanel(_:)` directly; add an AppDelegate
   action calling `orderFrontStandardAboutPanel(options:)`. Credits.rtf then duplicates the
   programmatic credits; delete it.
5. The bundled app's standard defaults domain is the bundle id (`surf.puppy.SyphonWeb`); `swift
   run` uses `SyphonWeb`; profiles use `SyphonWeb.profile.*` suites. The DB is
   `syphon_web.sqlite` in Application Support.
6. Rename touches source directory moves, imports, test target, Info.plist
   (`CFBundleGetInfoString`, icon), `statusMenu.swift`, settings text, docs. CI needs no change.

## Decisions (user, 2026-09-27)

- Rename: full, with a new bundle id and a one-time copy of old settings (never delete old).
- Repo: rename to QWebSyphon after the rename PR merges.
- New outputs default to Syphon name "QWebSyphon"; existing names kept.
- Sidebar: icon + bold for the selected output's bookmark only; muted "(Output)" labels stay.
