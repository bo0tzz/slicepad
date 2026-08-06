# SlicePad

An iPad slicer that runs OrcaSlicer's engine on-device, driven by profiles you
build in desktop Orca.

The workflow it targets: model in Shapr3D on the iPad, export a mesh, slice it
with your real Orca profile, send the G-code to a Klipper printer over
Moonraker. Desktop Orca is involved exactly once — to author and export the
profile bundle.

## Non-goals

Orca's UI does not come along, and this is not trying to replace it. You get
plate placement, preset selection, and a small set of overrides (layer height,
infill, supports, temperatures). Anything deeper is a desktop job.

Also deliberately absent: multi-material and painting (the engine paths there
are the least stable when ported off desktop), STEP import (no OCCT — Shapr3D's
free tier exports mesh only), and any non-Klipper printer integration.

## Architecture

```
SlicePad.app                       SwiftUI, iPad only
    │
    │  slicepad.h                  C ABI, ~15 functions, JSON for structured data
    ▼
SlicePadCore.xcframework           arm64-ios + arm64-simulator
    └── libslic3r.a + deps         OrcaSlicer v2.4.2, GUI excluded
```

`libslic3r` is built headless: no wxWidgets, no OpenGL, and with OCCT, OpenVDB,
and OpenCV excluded. Those three are the bulk of the porting pain and none are
reachable from the feature set above.

## Layout

| Path | Contents |
| --- | --- |
| `core/` | The C ABI and its implementation over libslic3r |
| `cli/` | Linux harness running the same core — the fast development loop |
| `deps/` | Cross-compile scripts for the iOS dependency set |
| `ios/` | Xcode project and SwiftUI app |
| `patches/` | Changes to the engine itself, as a numbered patch stack |
| `third_party/orcaslicer/` | Pinned upstream source — fetched, patched, gitignored |

`mise run fetch` populates `third_party/orcaslicer` at the pinned commit and
applies the patch stack. Dev tooling is pinned in `mise.toml`; the rest of the
dependency set is built from source into `deps/prefix`, deliberately including
the ones Arch would happily provide — the iOS build has to build them anyway,
and a Linux build that leans on system packages stops predicting whether the
iOS build works.

The app ships OrcaSlicer's `resources/profiles` as-is, so any printer you later
point it at resolves its `inherits` chain without a rebuild.

## Development loop

There is no Mac in the inner loop. Two consequences shape the whole project:

1. **Engine work happens on Linux.** `cli/` builds the same `core/` against
   host libslic3r, so profile resolution, overrides, and slicing correctness are
   developed and tested at full speed locally. The correctness oracle is desktop
   Orca's own CLI: same profile, same mesh, same engine version, diffed G-code.
2. **iOS work happens in CI.** GitHub Actions `macos-26` runners cross-compile
   the dependency set, build the xcframework, and run the core's tests on the
   iOS Simulator. The app is exported as an **unsigned** `.ipa` artifact;
   SideStore signs it on-device at install time, so no Apple Developer account
   and no signing secrets in CI.

Because the device is out of the loop until install time, anything that can be
asserted headlessly must be — the simulator tests are the only thing standing
between a bad commit and a ten-minute round trip.

`tests/gate.cpp` is that assertion: it compares the resolved configuration, every
G-code command and the reported statistics against a reference sliced by desktop
Orca, and it is plain C++ over the C ABI so the same source runs wherever the
engine builds.

Building the whole thing with clang as well as gcc found two real portability
defects (see `patches/0006` and the `nanosvg`/`tbbmalloc` notes in
`CMakeLists.txt`) and produced **byte-identical G-code**, so the output does not
depend on the compiler. Worth knowing if a build ever disagrees: suspect the
build, not the engine. Reproduce it by pointing `CMAKE_PREFIX_PATH` at a
clang-built dependency prefix — a clang consumer of gcc-built dependencies fails
to link, which is a toolchain-mixing artefact rather than a defect.

## Licence

OrcaSlicer is AGPL-3.0, so this is too. Note that this rules out App Store
distribution: Apple's terms are incompatible with the GPL family, and the
copyright isn't ours to add an exception to. SideStore or another sideloading
route is the only distribution path.
