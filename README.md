# SlicePad

An iPad slicer that runs OrcaSlicer's engine on-device, driven by a profile you
build in desktop Orca.

The workflow it targets: model in Shapr3D on the iPad, export a mesh, slice it
with your real Orca profile, send the G-code to a Klipper printer over Moonraker.
Desktop Orca is involved once, to author the profile.

## Status

The engine works and is verified against real inputs. The app does not exist yet.

- **Done**: headless libslic3r, the C ABI, auto-orient, arrange, overrides,
  cancellation, slice statistics, G-code thumbnails, and the geometry a plate view
  needs. Eleven gates compare all of it against G-code sliced by desktop Orca from
  the same profile and mesh — including a byte-identical match, 3328 of 3328
  commands, starting from a raw Shapr3D export.
- **Verified on Apple's toolchain**: the whole dependency set, libslic3r and the
  gates build and pass on macOS arm64 in CI, using Apple clang, ld64 and SDK.
- **Not started**: the iOS build — now a cross-compilation problem on a target
  already known good — the SwiftUI app, and the Moonraker upload.

Two findings qualify what this can promise, both written up under `docs/`:
slicing is not reproducible at some infill densities, and byte-identical G-code
is a property of identical code generation rather than of the engine. The iPad
will produce the same object as your desktop, not the same bytes.

## How a profile gets here

Save a project in desktop Orca (**File → Save Project As**) and hand the `.3mf`
to `sp_load_config`. Its `Metadata/project_settings.config` holds the printer,
process and filament settings **already merged** — 655 keys for a real SV08
profile.

That is why there is no notion of presets in the ABI. An exported preset bundle
contains thin deltas plus the *name* of a system parent, and resolving those names
means `PresetBundle`, whose machinery is built around GUI and cloud-sync state
that does not exist here. A saved project sidesteps all of it: no `inherits`
chains, no vendor profile tree to ship.

The geometry in the profile project is ignored, so one "carrier" project can be
exported per profile and reused for every model. It works equally well saved from
an empty plate.

A carrier is a snapshot of a *combination*, not composable presets — a different
filament means a different carrier.

## Non-goals

Orca's UI does not come along. You get placement, three overrides (wall loops,
infill density, supports on/off) and a slice. Anything deeper is a desktop job.

Deliberately absent: multi-material and painting, STEP import (no OCCT), and any
non-Klipper printer integration.

## Architecture

```
SwiftUI app                    does not exist yet
    │
    │  core/include/slicepad.h  C ABI, ~25 functions, JSON for structured data
    ▼
slicepad_core + libslic3r       OrcaSlicer v2.4.2, GUI excluded
```

`libslic3r` is built headless: no wxWidgets, no OpenGL, and with OCCT, OpenVDB and
OpenCV excluded. Those three are the bulk of the porting pain and none are
reachable from the feature set above.

Everything crossing the ABI is a C string, a primitive or a packed float buffer,
so Swift can call it without a C++ interop shim. Mesh triangles, bed outline and
toolpath segments come out ready for a vertex buffer.

## Layout

| Path | Contents |
| --- | --- |
| `core/` | The C ABI and its implementation over libslic3r |
| `cli/` | Linux harness driving the same core — the fast development loop |
| `tests/` | The correctness gates, plain C++ so they run wherever the engine builds |
| `testdata/` | A real profile, a real mesh, and G-code from desktop Orca |
| `patches/` | Changes to the engine itself, as a numbered patch stack |
| `scripts/` | Fetching the engine, and running heavy builds without hurting the machine |
| `docs/` | Findings worth keeping, e.g. how Orca drives Moonraker |
| `third_party/orcaslicer/` | Pinned upstream source — fetched, patched, gitignored |

`mise run fetch` populates `third_party/orcaslicer` at the pinned commit and
applies the patch stack; `mise run deps` builds the dependency set into
`build/deps-prefix`. Dev tooling is pinned in `mise.toml`.

## Development loop

There is no Mac in the inner loop, which shapes everything:

1. **Engine work happens on Linux.** `cli/` builds the same `core/`, so profile
   handling and slicing correctness are developed at full speed locally. The
   oracle is `testdata/reference.gcode`, sliced by desktop Orca 2.4.2 — the same
   version the engine is pinned to.
2. **Apple work happens in CI.** A `macos-26` runner exercises Apple's clang, ld64
   and SDK, and runs the same gates. iOS then adds only cross-compilation on top
   of a target already known good.

`tests/gate.cpp` is the safety net: eleven gates covering config resolution,
G-code equality, statistics, toolpath and plate geometry, the override controls,
cancellation, transforms, thumbnails and the failure paths. The suite also checks
that eleven of them reported, because a deleted test otherwise looks exactly like
a passing one. Plain C++ over the C ABI with no
platform dependencies, so the same source runs on an Apple target later. Both
`ctest` and the binary directly take a fixtures directory and a working directory.

Each gate compares against something independent rather than asserting a value
computed by the code under test. That has repeatedly caught the oracle being wrong
rather than the engine — worth knowing before trusting a failure.

Building with clang as well as gcc found two real portability defects (patch 0006
and the `nanosvg`/`tbbmalloc` notes in `CMakeLists.txt`), and both produce
byte-identical G-code on x86-64 — but that is a narrower result than it first
appears. Output *does* depend on code generation: building the same source for
`x86-64-v3`, where the compiler vectorises differently, changes the G-code, and the
slicer's thresholds turn sub-ulp differences into whole millimetres. So gate 2 asks
for byte equality only on the architecture the reference came from.

## Licence

OrcaSlicer is AGPL-3.0, so this is too. That rules out App Store distribution:
Apple's terms are incompatible with the GPL family, and the copyright is not ours
to add an exception to. SideStore or another sideloading route is the only path.
