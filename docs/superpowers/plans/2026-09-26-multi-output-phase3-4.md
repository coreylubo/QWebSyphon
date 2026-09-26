# Multi-output phase 3 + 4 — plan (from user's phase 2 test notes, 2026-09-26; Codex-reviewed, 7 findings folded in)

Base: `t3code/multi-output-phase2` once the phase 2 bug fixes (orientation, 1080p) land and phase 2
is committed. Phases 3 (UI) and 4 (OSC) from the spec are pulled together here because the notes
span both.

## User notes → clusters

| Note | Cluster |
|---|---|
| Outputs upside down / mirrored; 1080p doesn't work | 0 (in progress, phase 2 fix) |
| Folder icon in the delete-output confirmation | none: macOS shows the app icon in dialogs; the `swift run` binary has no bundle, so it's the generic icon. `SyphonWeb.app` shows its own icon. |
| One OSC port, `/syphon/<output>/…` | 2 |
| Settings window = global only; per-output settings elsewhere | 3 |
| No GUI way to set each output's page: drag bookmark to output; double-click asks which output | 3 |
| Bookmark list: icon for whatever plays in any output, muted "(Overlay)" naming the output | 3 |
| Two bookmarks show as playing in one output | 1 + 3 |

## Decisions (user, 2026-09-26)

- Output name must be an OSC slug; the Syphon name is the same string.
- Per-output settings: popover anchored to the tile (gear button + "Settings…" in the tile menu).
- "Two playing": two globes with one output (two bookmarks matched one output's URL).

## Cluster 1 — model (sonnet)

- Name rule (`validateOutputName`): `[A-Za-z0-9_-]+`, not all digits (would collide with the
  1-based index), not reserved (`url`, `bookmark`, `refresh`), unique case-insensitively, max 64.
  Error text names the allowed characters.
- Existing names that break the new rule (e.g. profile default "SyphonWeb left", phase 1 names
  with spaces) are **grandfathered**: loaded as-is, not a sanitize repair (so no `persist = false`
  and no Syphon server rename that would break QLab). They are addressable over OSC by index only;
  the UI shows a "rename to address by name over OSC" hint on them. Sanitize still repairs
  blank/duplicate names in memory with `persist = false` (phase 2 behavior): the app never writes
  duplicates, so this only happens with hand-edited JSON, where a unique Syphon name matters more
  than QLab continuity. A grandfathered name is only kept when it is unique.
- New default names are slugs: `defaultOutputBaseName()` = slug of `defaultSyphonName()`
  (non-matching characters → `-`), unique-suffixed `-2`, `-3`. Duplicate → `<name>-copy`.
  `uniqueOutputName` suffix changes to `-N`.
- `Output.bookmarkID: Int64?` (persisted as optional `bookmarkID` in `OutputConfig`; older builds
  ignore it). Set only by `Output.open(bookmark:)`; `navigate(to:)` is reserved for non-bookmark
  URLs and clears it. Every bookmark-originated path uses `open(bookmark:)`: sidebar Open,
  double-click, "Open in", drag/drop, OSC `/bookmark` and `/bookmark/<label>` (current direct
  `navigate(to:)` calls in mainView.swift and oscServer.swift's bookmark handlers are replaced).
- Reconcile: `AppModel.reconcileBookmarkIDs(_ bookmarks: [Bookmark])`, called at launch and on
  every `bookmarksDidChangePublisher` event (covers delete, URL edit, and other profiles'
  changes): clear any `bookmarkID` whose bookmark is missing or whose normalized URL no longer
  equals `output.url`; save if anything changed. Live matching (cluster 3) uses it:
  a bookmark is live in an output iff `output.bookmarkID == bookmark.id`, falling back to URL
  equality only when `bookmarkID` is nil, and then only for the **first** bookmark with that URL.
  So at most one bookmark is ever live per output.
- Pure `liveBookmarkIDs(outputs: [(id, url, bookmarkID)], bookmarks: [(id, url)]) -> [bookmarkID: [outputID]]`
  in appModel.swift with a self-check (duplicate-URL bookmarks, nil bookmarkID fallback, deleted
  bookmark id). `bookmarks` must be in sidebar order (favorites first, then the rest, each as
  `Bookmark.getAll()` orders them); "first match" means first in that order. Output lists in the
  result are in `model.outputs` order.
- Self-check updates: name rule cases, grandfathered names don't set `repaired`.

## Cluster 2 — OSC (sonnet, after 1)

Spec "OSC" section, with the name rule above:

```
/syphon/url <string>                    legacy output (by legacyOutputID)
/syphon/bookmark <int|string>
/syphon/bookmark/<label>
/syphon/refresh
/syphon/<output>/url <string>           <output> = name (case-insensitive) or 1-based index
/syphon/<output>/bookmark <int|string>
/syphon/<output>/bookmark/<label>
/syphon/<output>/refresh
```

- Pure `parseOSCRoute(_ address: String) -> OSCRoute?` (split with
  `omittingEmptySubsequences: false`; first segment must be empty (leading `/`), every other
  segment non-empty, so `/syphon//url` and trailing `/` are rejected; exact segment counts; legacy `["syphon", cmd]`, `["syphon", "bookmark", label]`; scoped
  `["syphon", out, cmd]`, `["syphon", out, "bookmark", label]`). Replaces the prefix match.
  Ambiguity: `["syphon", "bookmark", x]` is always the legacy label form (reserved names make
  `bookmark` never an output name).
- Pure `resolveOutput(_ ref: String, outputs: [(id, name)]) -> UUID?`: all-digits → 1-based index
  (0, out of range → nil); else case-insensitive name match.
- Bookmark opens go through `Output.open(bookmark:)` so `bookmarkID` is set; `/url` clears it.
- One port for all outputs (already the case).
- Exported API in oscServer.swift only (cluster 2 does not touch settingsView.swift):
  `struct OSCCommandInfo: Identifiable { let id: String; let args: String; let description: String }`
  and `@MainActor func oscCommandReference(outputs: [Output]) -> [OSCCommandInfo]` (legacy forms +
  scoped forms + one concrete example per output: by name, or by index for grandfathered names).
  README OSC section + docs/OSC.md updated.
- Self-check: every legacy and scoped form, extra/empty/trailing segments, reserved words,
  index 0/negative/out of range, unknown name, case-insensitivity.

## Cluster 3 — UI (sonnet, after 2; owns mainView, settingsView, outputTiles, statusBar)

- **Settings window = global**: Instances, OSC port, OSC command reference rendered from
  `oscCommandReference(outputs:)` (remove settingsView's private `OSCCommandInfo` list). Output
  sections move out.
- **Output settings popover** on each tile: gear button on the tile + "Settings…" in the tile
  context menu. Contents = phase 2's `OutputSettingsSections` (name with slug rule + grandfather
  hint, resolution 720p/1080p/Custom W×H + Apply, transparent, capture without clients).
- **Open in output**:
  - Drag a bookmark row onto a tile → `output.open(bookmark:)` (`.draggable(bookmark id)` on rows,
    `.dropDestination` on tiles; drop highlight on the target tile).
  - Double-click a bookmark: one output → open directly; several → `NSMenu.popUp(positioning:
    nil, at: NSEvent.mouseLocation, in: nil)` (screen coordinates, no view/event needed; called
    from `primaryAction`) listing outputs (selected output first, checkmark on outputs already
    playing it). Items use a small target object retained for the menu's lifetime. If that
    proves unreliable at runtime, fall back to a popover anchored on the row.
  - Bookmark context menu: "Open in ▸ <output>" submenu (plus plain "Open" = selected output).
- **Bookmark rows**: globe when the bookmark is live in **any** output; muted text after the name
  listing the output names, e.g. `(Overlay)` or `(Main, Overlay)`; label `/label` stays at the
  trailing edge. Uses `liveBookmarkIDs`, so at most one row is live per output.
- Tile shows the playing bookmark's name (or the host of the URL when none) under the output name.
- Remove confirmation: keep `confirmationDialog` (icon explained above).

## Verification

- `swift build` clean; debug self-checks pass.
- OSC: raw UDP to each scoped form on a throwaway profile; Syphon client dump confirms the right
  output changed; legacy still by id.
- UI interactions listed for the user (drag, double-click menu, popover, bookmark row labels).

## Commits

Phase 2 (after cluster 0) → cluster 1 → 2 → 3 (serial: each builds on the last's API), each commit building on its own.
