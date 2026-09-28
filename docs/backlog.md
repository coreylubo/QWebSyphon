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
