# OSC control reference

Source: `Sources/SyphonWeb/oscServer.swift`, `Sources/SyphonWeb/webView.swift`,
`Sources/SyphonWeb/appModel.swift`, `Sources/SyphonWeb/bookmark.swift`,
`Sources/SyphonWeb/settingsView.swift`.

## Transport

- **UDP only.** SyphonWeb starts an `OSCUDPServer` (no TCP server).
- **Listens on all interfaces.** The server is created with no `interface` argument, and swift-osc's
  default binding for a `nil` interface is the IPv4 wildcard address `0.0.0.0` (see
  `hostAddressStringForBinding` in `swift-osc-io-nio`'s `Network Utilities.swift`) — not `localhost`.
  IPv6 is not enabled (`isIPv6Enabled` defaults to `false`), so only IPv4 is bound.
- **Default port 9000** (`defaultOSCPort` in `oscServer.swift`), configurable in Settings
  (valid range 1024–65535, enforced by `validOSCPortRange`).
- **Automatic fallback to the next free port**, but only when no port has ever been explicitly saved
  for this profile (`OSCController.start`, checked via `appDefaults.object(forKey: oscPortDefaultsKey)
  == nil`). In that case it tries the requested port, then up to 20 ports above it
  (`oscPortFallbackRange = 1...20`), and binds the first one that succeeds. The status bar and
  Settings reflect the **actual bound port**, which may differ from the configured one — e.g.
  "Listening on UDP 9001 (port 9000 was in use)".
- **An explicitly chosen port that fails to bind shows an error and does not fall back.** Clicking
  Apply in Settings calls `start(port:explicit: true)`, which only tries that one port; on failure
  the status becomes "Failed to bind UDP `<port>`: `<error>`" and the port setting is not persisted
  (so a bad Apply doesn't disable fallback on the next launch).
- The main window's title bar and the status bar both show the bound port (e.g.
  `SyphonWeb · OSC 9000`, or `SyphonWeb — stage1 · OSC 9001` under a profile).
- macOS may prompt for permission to accept incoming network connections the first time the app
  binds a listening socket — allow it, or OSC control won't reach the app.

## Library

[swift-osc](https://github.com/orchetect/swift-osc) by orchetect, version 3.1.0 (pinned in
`Package.resolved`; `Package.swift` requires `from: "3.1.0"`).

- **Bundles are unpacked into individual messages.** The server is created with
  `receiveHandler: .messages { message, _, _, _ in ... }`. Internally
  (`OSCPacketDispatcherProtocol.dispatch`), an incoming `.bundle` is recursively walked and every
  contained message is dispatched to the handler separately — SyphonWeb's dispatch code only ever
  sees single `OSCMessage` values, never a bundle.
- **No OSC wildcard/pattern matching.** `dispatchOSCMessage` parses `message.addressPattern
  .stringValue` with `parseOSCRoute`, an exact-segment parser (see "Addressing an output" below),
  not OSC's `*`/`?`/`[]` address-pattern syntax — senders using that syntax will not match
  anything.

## Addressing an output

One process, one OSC port, any number of outputs. Every command has two forms:

- **Legacy (unscoped)** — `/syphon/url`, `/syphon/bookmark`, `/syphon/bookmark/<label>`,
  `/syphon/refresh` — always targets the **legacy output** (the one created by the one-output→
  multi-output migration, tracked by a fixed id, never by selection or array position). If the
  legacy output has been removed, these are logged ("`no output for /syphon/url, ignoring`") and
  dropped rather than silently retargeted to another output.
- **Scoped** — `/syphon/<output>/url`, `/syphon/<output>/bookmark`,
  `/syphon/<output>/bookmark/<label>`, `/syphon/<output>/refresh` — targets `<output>`, resolved
  (`resolveOutput`) as:
  1. **All-digit** → a 1-based index into the current output list (`1` = first output). `0`,
     negative, or past the last output is logged and dropped.
  2. **Otherwise** → a case-insensitive match against an output's name — but only names that pass
     the OSC slug rule (letters, digits, `-`, `_`, non-empty, ≤64 chars, not all-digits — the same
     rule new output names are validated against). An older hand-edited name that predates the
     rule (e.g. one with a space) is "grandfathered": it still works everywhere else, but over OSC
     it's reachable only by index, never by typing its name. No match at all is logged and
     dropped.

`parseOSCRoute` parses the address by splitting on `/` and requiring exact segment counts — a
missing leading `/`, an empty segment anywhere (`/syphon//url`), a trailing `/`, or extra segments
all fail to parse and are logged as unhandled. `["syphon", "bookmark", x]` is always the *legacy*
bookmark-label form, never a scoped address for an output literally named "bookmark" — `bookmark`
(along with `url` and `refresh`) is a reserved word that can never be assigned as an output name.

Settings' "OSC Commands" reference list (`oscCommandReference(outputs:)`) renders the legacy and
scoped forms above plus one concrete example address per current output, so a show file can be
built by reading that list rather than this doc.

## Commands

Every message — recognized or not — is recorded via `controller.recordOSC(address:)` before any
dispatch logic runs, so the status bar's "last OSC message" always reflects the most recent packet
received, whether or not SyphonWeb understood it.

### `/syphon/url <string>` · `/syphon/<output>/url <string>`

Loads a URL in the target output. The first argument must be a string (`values.first as?
String`; extra arguments are ignored); any other type is logged ("`<address> requires a string
argument, ignoring`") and dropped.

The string is normalized by `Output.normalizedURL` before navigating:

- Trimmed of leading/trailing whitespace; an empty result is ignored.
- **Kept as-is (scheme preserved)** if it starts with `<scheme>://` (regex
  `^[A-Za-z][A-Za-z0-9+.-]*://`, anchored to the start — `"example.com/?next=https://x"` does *not*
  count, only a URL whose own scheme is `://`-terminated at position 0), or if it starts with
  `about:`, `data:`, `javascript:`, or `blob:` (case-insensitive).
- **Otherwise, a scheme is added**: `http://` if the host looks local — `localhost`, anything ending
  in `.local`, or a 4-part all-numeric IPv4 literal (`127.0.0.1`, etc.) — and `https://` for
  everything else. This is why `localhost:3000` and `192.168.1.5:8080` get `http://` while
  `example.com` gets `https://`.

### `/syphon/bookmark <string|int|float>` · `/syphon/<output>/bookmark <string|int|float>`

Uses the first argument (extra arguments are ignored). It must be a string or an integral number
(see below); anything else is logged and ignored.

**String argument** — resolved in this order:
1. Exact match (case-insensitive) against a bookmark's OSC **label** (`Bookmark.find(label:)`).
2. If no label matches, exact match (case-insensitive, trimmed) against a bookmark's **name**, across
   all bookmarks regardless of favorite status.

If neither matches, it's logged ("`/syphon/bookmark no match for <value>`") and ignored.

**Numeric argument** — a 1-based index into sidebar order: all favorited bookmarks first (in their
sidebar order), then all non-favorited bookmarks (in their sidebar order) — i.e. `Favorites` section
then `Bookmarks` section, matching what's on screen. Index 0, negative, or past the end is ignored.

`integralOSCValue` accepts the argument as: `Int32` or `Int64` directly (OSC type tags `i`/`h`), or
`Float32`/`Double` (`f`/`d`) **only when the value is exactly integral** (`Int(exactly:)`) — e.g.
`2.0` resolves to position 2, `2.5` is rejected. This covers senders like TouchOSC that only send
floats.

### `/syphon/bookmark/<label>` · `/syphon/<output>/bookmark/<label>`

Loads the bookmark whose OSC label exactly matches `<label>` (case-insensitive,
`Bookmark.find(label:)`), in the target output. No match: logged and ignored.

**Strict segment matching, not a prefix match**: `parseOSCRoute` splits the address into exactly
three (legacy) or four (scoped) non-empty segments, so `<label>` can't itself contain `/` —
`/syphon/bookmark/foo/bar` doesn't parse (four segments where the legacy bookmark-label form takes
three) and is logged as unhandled, rather than looking up a label `"foo/bar"`. A trailing `/`
(`/syphon/bookmark/foo/`) fails the same way — it produces an empty final segment.

Note the ambiguity rule: `/syphon/bookmark/<x>` is *always* the legacy label form, never a scoped
address for an output named "bookmark" — `bookmark` is a reserved output name (along with `url`
and `refresh`), so no output can ever collide with it.

### `/syphon/refresh` · `/syphon/<output>/refresh`

Reloads the current page in the target output (`webView?.reload()`). No arguments used.

## Bookmark labels

Labels are set per bookmark in the Add/Edit popover (`validateBookmarkLabel` in `bookmark.swift`):

- The raw text is trimmed; if empty after trimming, the bookmark has **no** label (not an error).
- Otherwise it must contain only `A-Z a-z 0-9 - _`.
- It can't be all digits (all-digit strings are reserved for position lookup in `/syphon/bookmark`).
- It must be unique, case-insensitively, among all other bookmarks' labels.

A bookmark's label (when set) also appears as its own row in Settings → OSC Commands
(`/syphon/bookmark/<label>` — Load "`<name>`"), and as `/label` text next to its name in the sidebar.

## Threading and implementation notes

- Incoming packets are decoded and dispatched to `dispatchOSCMessage` on the OSC server's own
  receive queue, **not** the main actor. `parseOSCRoute` (address → route) and `resolveOutput`
  (an `<output>` segment → an id, given a plain `[(id, name)]` snapshot) are pure functions with
  no actor affinity, so they're usable from either side and unit-testable without a database or
  Metal.
- `dispatchOSCMessage` extracts the address and argument values as plain (`Sendable`) data on that
  thread, then wraps the actual state mutation (`state.navigate`, `state.reload`, bookmark lookups)
  — including resolving *which* output a scoped address means, since that reads live
  `AppModel.outputs`/`legacyOutput` — in `Task { @MainActor in ... }` to hop onto the main actor.
- The "last OSC message" indicator is written from the receive thread through an
  `OSAllocatedUnfairLock`-protected value (`OSCController.recordOSC`), not by hopping to the main
  actor per packet — the OSC controller's 1-second tick reads and publishes it, so a
  high-rate sender doesn't queue a main-actor task per packet just for the indicator.
- Unknown/unhandled addresses are logged (`OSC: ignoring unhandled address ...`) and still
  update the "last OSC message" indicator — the status bar shows *something arrived*, not just
  *something was understood*.

## Examples

### QLab Network cue

Create a Network cue, set it to OSC, target `127.0.0.1` port `9000` (or whatever port Settings shows
bound), and set the message to (for example):

```
/syphon/bookmark/chuds
```

### TouchOSC button

Map a button to send a float value to `/syphon/bookmark` at `127.0.0.1:9000`. A button that sends
`2.0` on press loads the bookmark at sidebar position 2 (favorites first). Values with a fractional
part (e.g. `2.5`) are rejected — most TouchOSC controls send whole-number floats for this kind of
mapping already.

### Targeting one output among several

Given outputs named "Main" and "Overlay" (in that order), any of these load a URL in "Overlay"
without touching "Main":

```
/syphon/Overlay/url "https://example.com/lower-third"
/syphon/overlay/url "https://example.com/lower-third"   (case-insensitive)
/syphon/2/url "https://example.com/lower-third"          (1-based index)
```

`/syphon/url` (no output segment) always targets the legacy output regardless of how many outputs
now exist or which one is selected in the UI.

### Raw UDP from Python (no dependencies)

```python
import socket
import struct

def osc_string(s: str) -> bytes:
    b = s.encode("utf-8") + b"\x00"
    pad = (4 - len(b) % 4) % 4
    return b + b"\x00" * pad

def osc_message(address: str, type_tag: str, *args) -> bytes:
    msg = osc_string(address)
    msg += osc_string("," + type_tag)
    for tag, arg in zip(type_tag, args):
        if tag == "s":
            msg += osc_string(arg)
        elif tag == "i":
            msg += struct.pack(">i", arg)
        elif tag == "f":
            msg += struct.pack(">f", arg)
    return msg

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.sendto(osc_message("/syphon/url", "s", "https://example.com"), ("127.0.0.1", 9000))
sock.sendto(osc_message("/syphon/bookmark", "s", "chuds"), ("127.0.0.1", 9000))
sock.sendto(osc_message("/syphon/bookmark", "i", 1), ("127.0.0.1", 9000))
sock.sendto(osc_message("/syphon/refresh", ""), ("127.0.0.1", 9000))
```

### `oscsend` (liblo), if you already have it installed

```sh
oscsend 127.0.0.1 9000 /syphon/url s "https://example.com"
oscsend 127.0.0.1 9000 /syphon/bookmark s "chuds"
oscsend 127.0.0.1 9000 /syphon/bookmark/chuds
oscsend 127.0.0.1 9000 /syphon/refresh
```

`oscsend` is optional — the app itself has no dependency on liblo; this is just a common
already-installed alternative to the raw Python snippet above.

## Multiple instances

Each profile (`--profile NAME`) runs its own `OSCController` bound to its own port. Give each profile
a distinct OSC port in its Settings. If two profiles want the same port, the second to start either
fails to bind (if its port was saved explicitly) or falls back to a nearby free port (if it never
saved one) — probably not the port your show file expects. Check the window title for the port each
instance actually bound.
