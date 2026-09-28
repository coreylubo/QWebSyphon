# SyphonWebOSC

A macOS app that renders a web page to a [Syphon](https://syphon.info) source, for use in
show-control and live visual software — QLab, VDMX, TouchDesigner, Resolume, and anything else that
can consume Syphon.

This is a fork of [Digit (@doawoo)'s SyphonWeb](https://github.com/doawoo/SyphonWeb), which does the
same core job (WKWebView → Metal → Syphon) at a fixed 1280×720, one hard-coded page, controlled only
by clicking in its own window. All credit for that foundation goes to the original author — see
[Credits](#credits).

## Why this fork

The original SyphonWeb is a manual, single-page tool. This fork is built for running a page (or
several) unattended during a live show, driven from a booth:

- **Pages switch remotely over OSC** — no one needs to touch the SyphonWeb window during a show. See
  [docs/OSC.md](docs/OSC.md).
- **Pages are organized as bookmarks**, each with an optional OSC label, so a show file can address
  them by name (`/syphon/bookmark/lower-third`) instead of a raw URL.
- **Output can be 1080p at 60 fps**, not just 720p.
- **The background can be transparent**, for overlays — lower thirds, toasts, scoreboards — composited
  over other sources in your visual mixer.
- **Several independent Syphon sources can run at once.** Today that's one process per source via
  `--profile` (see [Multiple instances](#multiple-instances)); multiple outputs from a single process
  is planned — see [docs/multi-output-spec.md](docs/multi-output-spec.md).

## Features

- **Bookmarks**: a sidebar list of saved pages, split into Favorites and Bookmarks sections. Add or
  edit a bookmark via a popover (name, URL, optional OSC label); right-click a bookmark for Open,
  Edit, Favorite/Unfavorite, and Delete; double-click (or the context menu's Open) navigates the
  output to it. A bookmark currently loaded in the output shows a globe icon and bold text.
- **Settings window** (`Cmd-,`): output resolution (720p/1080p), OSC listen port, Syphon server name,
  transparent background toggle, a live reference list of every OSC command (including one line per
  labeled bookmark), and the active profile name.
- **`Cmd-R`** reloads the current page.
- **Status bar** below the preview: Syphon client connection state, live output fps, page load state
  (loading / loaded / failed), and the OSC server's bound port plus the most recent OSC message
  received and how long ago.
- **Profiles**: run multiple isolated instances from one build, each with its own settings and Syphon
  source (see [Multiple instances](#multiple-instances)).

## Requirements

- **macOS 14 or later at runtime.** `Package.swift` declares a `.v13` deployment target, but
  `main.swift` gates the whole app behind `#available(macOS 14, *)` — on macOS 13 it logs "You cannot
  run this app on this version of macOS!" and never launches the UI.
- **Swift 6.0+ toolchain** (`Package.swift` declares `swift-tools-version: 6.0`).

## OSC control

SyphonWeb listens for OSC messages over UDP, port 9000 by default (configurable in Settings). One
port serves every output — legacy (unscoped) addresses always target the legacy output; scoped
addresses target a specific output by name or 1-based index:

| Address | Args | Behavior |
|---|---|---|
| `/syphon/url` | string | Load a URL in the legacy output. Without a scheme, `http://` is added for `localhost`, `*.local` and IPv4 addresses, `https://` otherwise. |
| `/syphon/bookmark` | string or int/float | Load a bookmark by OSC label or name (string), or by 1-based sidebar position (int, or a whole-number float for senders like TouchOSC), in the legacy output. |
| `/syphon/bookmark/<label>` | none | Load the bookmark with this exact OSC label, in the legacy output. |
| `/syphon/refresh` | none | Reload the current page in the legacy output. |
| `/syphon/<output>/url` | string | Same as `/syphon/url`, targeting `<output>` (its name, case-insensitive, or its 1-based position). |
| `/syphon/<output>/bookmark` | string or int/float | Same as `/syphon/bookmark`, targeting `<output>`. |
| `/syphon/<output>/bookmark/<label>` | none | Same as `/syphon/bookmark/<label>`, targeting `<output>`. |
| `/syphon/<output>/refresh` | none | Same as `/syphon/refresh`, targeting `<output>`. |

An output's name must match the OSC slug rule (letters, digits, `-`, `_`) to be addressable by
name; an older hand-edited name that doesn't (e.g. one with spaces) is still addressable by index.
Settings' OSC command reference lists the exact addresses for every current output.

Full reference — argument types, URL normalization rules, bookmark resolution order, failure
behavior, and worked examples (QLab, TouchOSC, raw UDP) — is in [docs/OSC.md](docs/OSC.md).

## Multiple instances

Run more than one SyphonWeb window (each publishing its own Syphon server) with `--profile NAME`:

```
open -n SyphonWeb.app --args --profile stage1
swift run -c release SyphonWeb --profile stage1   # from source
```

Each profile gets its own settings (window position aside), stored separately — give each one a
different OSC port in Settings so they don't collide. Bookmarks are stored in one shared database
and are the same across every profile. The Syphon server name (Settings → Syphon) also defaults to
`SyphonWeb <profile>` so each instance is identifiable in VDMX/TouchDesigner; change it there if you
want something else.

## Developing

Everything you need should be in this repo, including the pre-built Syphon framework converted into
a `.xcframework` so you don't need Xcode.

Run `swift run` from the command line and it should boot right up.

## Building App Bundle

Because this project doesn't use Xcode, it takes a more rough approach to creating an app bundle: a
"skeleton" app is filled up with the framework and binary, then patched to run properly.

`build_app.sh` does all the steps and produces a `SyphonWeb.app` bundle in the root of the repo.

## Limitations

- Videos (like YouTube) do not render in the frame output — they're rendered on a different
  CoreGraphics context layer that this app doesn't have access to.
- If the SyphonWeb window is fully covered by another window, or the screen locks or the display
  sleeps, WebKit stops painting and output freezes (measured in the Phase 0 spike in
  `docs/multi-output-spec.md`). Show machines should disable screen lock and display sleep and keep
  the window at least partly visible.

## Bookmark storage

Bookmarks are stored in a shared SQLite database at
`~/Library/Application Support/syphon_web.sqlite`. Override the path (e.g. for testing) with the
`SYPHONWEB_DB_PATH` environment variable.

## Credits

Forked from [SyphonWeb](https://github.com/doawoo/SyphonWeb) by Digit (@doawoo).

Made with 🐾 by Digit (@doawoo)
