# Sending G-code to Moonraker

Notes from reading OrcaSlicer's own implementation, so that when this is built it
copies proven behaviour rather than being invented from the Moonraker docs.

## Why not reuse the code directly

`src/slic3r/Utils/Moonraker.cpp` is first-class Moonraker support and is unusually
well commented. It is not reusable as-is:

- `PrintHost.hpp` includes `<wx/string.h>`, and the implementation passes
  `wxString` around for messages and errors.
- It talks HTTP through `Utils/Http.hpp`, which wraps libcurl.

Both wxWidgets and libcurl are deliberately excluded from this build — curl by
patch 0004. Pulling them in for a file upload would be the largest dependency
addition in the project, on the iOS target, for the least engine-critical
feature. So the plan is a small multipart POST of our own, informed by the
below.

## The protocol, as Orca actually drives it

**Upload** — `POST /server/files/upload`, `multipart/form-data`:

| field | value |
| --- | --- |
| `file` | the G-code |
| `root` | storage root, default `gcodes` |

Response shape — **two of them are in the field**:

```json
{ "result": { "item": { "path": "<name>.gcode", "root": "<root>" },
              "print_started": false } }
```

```json
{ "item": { "path": "<name>.gcode", "root": "<root>" },
  "print_started": false, "action": "create_file" }
```

Orca reads only `result.item.path`. A Sovol SV08 returns the second, top-level
shape, so reading only the envelope reported a failure for an upload that had
already succeeded — the file was on the printer and the app said otherwise. Read
both.

**Start the print** — `POST /printer/print/start`, JSON body
`{"filename": "<item.path>"}`.

The path comes from the upload response, is relative to `root`, has no leading
slash, and keeps its extension.

### Where we diverge from Orca deliberately

When the path is missing or the reply will not parse, Orca falls back to the
filename it uploaded. We refuse instead. Moonraker renames on collision, so that
fallback can name an *older* file of the same name, and silently printing the
wrong thing is worse than an error saying the upload landed but could not be
identified.

## The correction worth carrying forward

Earlier research from Moonraker's own documentation said to pass a `print=true`
form field on the upload and let the server start the job. **Orca does not do
that.** It ignores `print_started` and always starts explicitly through
`/printer/print/start`, with the stated reason that a caller then has a single
place where print state changes.

That is the better design for us too: the upload response tells you the exact
path the server assigned, so starting explicitly removes any guessing about how
the filename was interpreted.

## Details worth keeping

- `GET /server/files/roots` enumerates storage roots and their permissions; only
  roots granting `w` are usable. It is optional in the spec and absent on older
  Moonraker, so a 404 should degrade quietly to the `gcodes` default rather than
  warn.
- Orca runs a connectivity test before uploading, so a wrong address fails with a
  clear message instead of a confusing upload error. It asks `GET /server/info`
  and wants `result.klippy_state` present — not any particular state, because
  buddy-fork firmwares idle in states other than `ready`.
- **Do not use `/printer/info` for that check.** It is proxied to Klipper and
  answers 503 whenever Klippy is starting, shut down or disconnected, which are
  all states a perfectly reachable printer sits in. Using it produced "could not
  reach the printer" against a printer that was plainly there and accepted the
  upload moments later. `/server/info` is answered by Moonraker itself.
- First contact with a `.local` address waits on mDNS, which can take longer than
  a five-second timeout allows.
- A `plateindex` form field exists for uploading `.gcode.3mf`, where the G-code is
  index-coded per plate. Irrelevant here: we upload a plain `.gcode`. Servers
  ignore unknown fields.
- Plain HTTP on a local network, so no TLS is needed — and therefore this must not
  be pointed at anything reachable from outside the LAN.
