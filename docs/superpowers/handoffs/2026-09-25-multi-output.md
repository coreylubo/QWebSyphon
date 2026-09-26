# Handoff: multiple Syphon outputs in one app (2026-09-25)

Next work: one SyphonWeb process publishing several independent Syphon sources. Before it:
PR #1 (coreylubo/SyphonWebOSC, branch `t3code/osc-multiple-syphon-websites`) with OSC control, a
720p/1080p toggle, bookmark editing and labels, a Settings window, `--profile` instances, and a
status bar.

**Read `docs/multi-output-spec.md` first.** It is the design, already reviewed once by Codex. This
document only adds what the spec doesn't: state, decisions, and traps.

## State at handoff

- Worktree: `/Users/corey/.t3/worktrees/SyphonWebOSC/t3code-324550c6`, branch
  `t3code/osc-multiple-syphon-websites`. `origin/main` is still `2f851a0` (upstream baseline).
- PR #1 targets **`coreylubo/SyphonWebOSC` main**. `gh` with no `--repo` defaults to the upstream
  `doawoo/SyphonWeb`. Always pass `--repo coreylubo/SyphonWebOSC`.
- PR #1 review state:
  - All Codex-bot inline threads are replied to and resolved (3 findings, fixed in `1b9e969` and
    `b8ee19e`).
  - A fresh `@codex review` was requested after `b8ee19e`, and its result had not come in at
    handoff time.
  - Check all four places before merging: inline threads (GraphQL `reviewThreads.isResolved`),
    issue comments, review summaries, checks.
  - The repo has no CI checks.
- PR #1 is **not merged**. The user has not asked to merge it.
- Uncommitted at handoff: none after the handoff commit. `.claude/` is untracked agent-worktree
  debris; don't commit it.
- Unpushed: the handoff commit (this file + the spec). It will ride along on the next push of
  this branch and appear in PR #1.
- No SyphonWeb test processes were running. The user runs their own instances from
  `./SyphonWeb.app`, built with `./build_app.sh`.

## Ground truth the spec relies on

Verified against the code at handoff:

- **Capture:**
  - The capture timer is created in `makeNSView`: `Timer.scheduledTimer` at 60 Hz, default
    run-loop mode (`Sources/SyphonWeb/webView.swift:222`).
  - It calls `captureFrame(webView:)` (`webView.swift:238`).
  - The WKWebView is created inside `makeNSView` (`webView.swift:217`), not as a stored property.
    A stored property allocated a throwaway WKWebView on every SwiftUI render (bot finding).
- **Layout scale:** `WKWebView.setLayoutScale` (`webView.swift:194`) uses `_viewScale` +
  `_layoutMode = 2`. It replaced `pageZoom`, which rendered `vw` font sizes at 0.5x. Measured: 10vw
  gave 64px instead of 128px. The user confirmed the fix on their real page.
- **Unused `CAMetalLayer`:** `initMetal` (`webView.swift:153`) creates a `CAMetalLayer` that
  nothing uses (`webView.swift:146,155`).
- **Syphon server:**
  - Created in `AppDelegate` after settings load, with its final name.
  - Renaming recreates it.
  - `applicationWillTerminate` stops it (`Sources/SyphonWeb/main.swift:102`).
- **OSC:**
  - `dispatchOSCMessage` (`Sources/SyphonWeb/oscServer.swift:92`).
  - The label route is a prefix match on `/syphon/bookmark/` (`oscServer.swift:5,135`), so it
    accepts extra `/` segments.
  - `OSCController.start(port:explicit:)` (`oscServer.swift:191`) falls back to the next free port
    only when no port was saved and `explicit` is false.
  - OSC activity is recorded lock-free: `OutputStats.recordOSC` (`Sources/SyphonWeb/statusBar.swift:26`).
- **Settings storage:**
  - Per-profile settings live in `appDefaults` (`Sources/SyphonWeb/profile.swift:29`), suite
    `SyphonWeb.profile.<name>`.
  - The default profile uses `.standard`. For the bundled app that is domain
    `surf.puppy.SyphonWeb`; for `swift run` it is `SyphonWeb`.
- **Bookmark database:**
  - Label migration: `migrateBookmarkLabels` (`Sources/SyphonWeb/database.swift:83`).
  - The backup before migrating uses `VACUUM INTO`.
  - `SYPHONWEB_DB_PATH` overrides the DB path (`database.swift:5`).
- **Tests:** the DEBUG startup self-check `checkBookmarkLabelValidation` (`Sources/SyphonWeb/bookmark.swift:246`)
  is the test pattern. The package can't host a test target; the Syphon header path is an
  `unsafeFlags` hack.
- **Performance** (release build, this Mac, one output):
  - 720p: 60 fps, ~4 ms per `getFrame`.
  - 1080p: 60 fps, ~8–13 ms.
  - A test Syphon client received 303 frames in 5 s.

## Decisions already made (by the user, this session)

- Double-click on a sidebar bookmark opens it. Edit is from the right-click menu only.
- Resolution lives in Settings only, not the sidebar.
- Transparent background is a setting. The user confirmed it works in QLab.
- Multiple instances use `--profile` (per-instance settings, shared bookmarks). The user
  confirmed two instances show as separate named sources in QLab.
- ScreenCaptureKit capture was skipped: CPU capture reaches 1080p60. Revisit only if multi-output
  can't hold the needed frame rate.
- Status bar shows: Syphon clients, output fps, page load state, last OSC message.
- Multi-output: the user asked for a spec and a fresh session. No product choices made yet; see
  the spec's open questions.

## Things that will bite

- **Rename after announce.**
  - Trap: creating a Syphon server with a placeholder name and renaming it later.
  - Symptom: QLab, already running, kept the first announced name. Two instances showed as
    identical sources and neither worked properly.
  - Correct move: create each server with its final name. Recreate it, don't rename in place.
- **Hidden web views.**
  - Trap: assuming a web view keeps painting when it isn't visible.
  - Symptom: `layer.render(in:)` returns stale or blank frames; it snapshots what WebKit last
    committed and does not make it paint.
  - Correct move: this is why the spec starts with the Phase 0 spike. Check that consecutive
    frames differ, not just that pixels are non-blank.
- **Parallel agents share the worktree.**
  - Trap: an agent with worktree isolation still wrote into this worktree once.
  - Symptom: an experiment's code got swept into a feature commit and had to be amended out.
  - Correct move: before committing, check `git diff` for code you didn't expect, and commit with
    explicit paths.
- **Splitting shared files into separate commits.**
  - Trap: a file changed by two features, committed one feature at a time.
  - Symptom: the first commit may not build on its own. A chained `grep "Build complete"` passed
    even though errors were printed.
  - Correct move: verify an isolated commit with `git worktree add /tmp/x <sha> && swift build`.
- **zsh globbing.**
  - Trap: `rm -f /tmp/foo*` in a chain when nothing matches.
  - Symptom: the whole chain aborts.
  - Correct move: `setopt nullglob` first.
- **Test launches.**
  - Trap: launching the app for tests with the user's real settings or database.
  - Symptom: a test agent ran `defaults delete SyphonWeb` and wiped the user's saved settings for
    the `swift run` build.
  - Correct move: always use `SYPHONWEB_DB_PATH=/tmp/...` and a throwaway `--profile`. Delete only
    the suites you created. Never kill instances you didn't start.
- **Permission classifier.** It blocks `kill` of processes you didn't start and `rm -rf` of the
  app bundle. Ask the user to run `./build_app.sh` instead of deleting `SyphonWeb.app` yourself.
- **Stale-looking review activity.** `reviews.last.commit` can point at a new SHA only because
  old comments were re-attached to it.
  - Symptom: it looks like a new review when it isn't.
  - Correct move: compare `submitted_at`/`created_at` against the time of the `@codex review`
    request.

## Open questions

Product (block phase 1; ask with `AskUserQuestion`), from the spec:

1. Tiles of all outputs vs one large selected preview.
2. Is a cap of 4 outputs enough, and what 720p/1080p mix?
3. Keep `--profile` once multi-output works?
4. Skip capture for outputs with no Syphon clients?

Investigation (Phase 0 spike, doesn't need the user): which rendering approach keeps every
output's web view painting at 60 fps, and the end-to-end p95 capture cost for 1–4 outputs.

## Process notes

- **Workflow the user expects:**
  1. Plan.
  2. `codex:codex-rescue` plan review with `--wait --model gpt-5.6-terra`.
  3. Sonnet or Opus subagents implement.
  4. Opus reviews the diff.
  5. Local commits only when the user says so.
  6. PR changes get a `codex:codex-rescue` code review plus the Codex GitHub bot (`@codex review`
     comment). Reply to and resolve every bot thread.
- **Syphon lister/client and raw OSC recipes** are in the spec's "Verification rules".
