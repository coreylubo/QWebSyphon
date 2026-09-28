# Backlog

Filed from user notes (2026-09-27). GitHub issues are disabled on this repo, so they live here.

## Interact with an output's live page (navigate, log in)

Output tiles are non-interactive images, so there's no way to click, scroll or navigate inside a
page, or to log in to a page that needs it. Proposal: an "Interact…" action on each tile that
opens that output's live page in a normal window, taking its input. The page's layout stays at
the output's pixel size. Closing the window returns the page to the output. Cookies already
persist: all outputs share WebKit's default persistent data store, so a login done this way
would stick across relaunches.

## Load a custom URL into an output

Today an output can only load a URL through a bookmark (sidebar, drag onto a tile,
double-click), or through OSC `/syphon/<output>/url`. `UtilityView` (an "Enter URL" field with a
Go button) exists in `utilityView.swift`, but nothing uses it, even on main. Proposal: put a URL
field in the output gear popover, or above the tiles, wired to `Output.navigate(to:)`.

## Bookmarks vs favorites

Favorites aren't a separate thing. They're bookmarks with `favorite = true`, shown in a
"Favorites" section above "Bookmarks" in the sidebar. Question: keep the pinned section, or drop
the flag and rely on bookmark ordering and OSC labels?

## Menu bar icon: `record.circle` with a status-colored center

User request (2026-09-27): the status item icon should be the SF Symbol `record.circle`, with its
inner dot filled in the status color (green/orange/red) instead of the current symbol plus a
separate dot. The outer ring keeps following the menu bar's appearance. The status item exists
since PR #4 (`statusMenu.swift`, icon adapted from the Prompter's `statusImage`).

## Page drawn at the wrong size after a backing-scale change

Found while testing GPU capture (2026-09-27). After the output's backing scale changes (e.g.
moving the main window between a 2x and a 1x screen), the page sometimes lays out at the wrong
size and covers only a quarter of the frame. About half of repeated runs showed it, on the GPU
and CPU capture paths alike. The layer tree itself had the wrong size, so it is WebKit's viewport,
probably the viewport-nudge race in `OutputWebViewController.applySize`, not capture. It was
reproduced only by setting `backingScale` directly; a real screen move is untested.

## `<video>` is blank in outputs

WebKit hosts video outside the app process, so neither capture path (CARenderer or
renderInContext) sees it. Pages that are mostly video won't work until capture reads the window
server's composited result instead (e.g. ScreenCaptureKit, which needs Screen Recording
permission).
