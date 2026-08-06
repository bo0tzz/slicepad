# Test fixtures

Real inputs and a real reference output, used as the correctness oracle for the
slicing core.

| File | What it is |
| --- | --- |
| `Sovol SV08 0.4 nozzle.orca_printer` | Preset bundle exported from desktop Orca (a zip: printer, filament and process presets plus `bundle_structure.json`) |
| `model.3mf` | Exported from Shapr3D on the iPad — a real input, low-resolution mesh and all |
| `reference.gcode` | The same model sliced by desktop OrcaSlicer 2.4.2 using the presets above |

## Provenance — read before trusting a diff

`reference.gcode` was produced by **OrcaSlicer 2.4.2** on **x86-64 Linux**, and
`scripts/fetch-orca.sh` pins that version. A diff against it only means something
while those match: move the pin and the reference has to be regenerated.

The architecture matters as much as the version. Slicing is sensitive to
floating-point code generation — building the same source for x86-64-v3, where
fused multiply-add is available, changes the G-code — so a reference produced on
one architecture is not automatically the standard for another. An arm64 build
disagreeing with this file is not necessarily wrong; see
`docs/nondeterminism.md` and the `-ffp-contract` note in the CI workflow.

The presets actually selected, per the G-code's own config block:

- printer `Sovol SV08`
- process `0.20mm Standard @Sovol SV08 - Copy`
- filament `SV08 PLA`

## Why this is a good oracle

Orca writes its fully resolved configuration into the G-code as `; key = value`
comments — 635 of them here. That gives two independent gates rather than one:

1. **Config resolution.** Load the bundle, resolve `inherits`, and compare all
   635 keys against the reference block. This isolates profile handling from
   slicing entirely, so a mismatch points straight at preset merging.
2. **Slice output.** Compare generated G-code against `reference.gcode`.

Stage 1 is the one that matters for "my profile came out different on the iPad",
and it is cheap enough to run on every commit.

The user presets are thin deltas over system parents — the process preset
carries 17 keys inheriting `0.20mm Standard @Sovol SV08`, the filament 9 keys
inheriting `Sovol SV08 PLA`, both of which live in Orca's bundled
`resources/profiles/Sovol`. The printer preset is self-contained (157 keys, empty
`inherits`). So stage 1 is a real test of parent resolution, not a formality.
