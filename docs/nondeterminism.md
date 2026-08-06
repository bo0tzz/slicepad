# A nondeterministic slice result

Found while making gate 7 assert that raising infill density raises filament
usage. It does — but not reproducibly.

## What happens

Slicing the fixture with `sparse_infill_density=60%` yields **either 435.82mm or
329.44mm** of filament. Both values are exact and repeatable; a given process
always produces the same one, and repeating the identical slice within that
process gives the identical answer three times out of three.

Roughly one run in three takes the other branch.

## What it is not

- **Not the overrides.** The resolved configuration is correct in both cases —
  `walls=3 infill=60%` — printed and checked.
- **Not the model.** Object bounds agree to six decimal places across runs.
- **Not ASLR.** `setarch -R` does not make it deterministic, so it is not pointer
  ordering.
- **Not engine state.** A fresh `sp_engine` with its own freshly loaded profile and
  model still flips.
- **Not slicing in general.** Driven from the CLI as the only slice in the process,
  the same job gives 435.82mm every time.

## What it looks like

State that is process-global rather than engine-local, established during earlier
slices and then stable. Two discrete outcomes rather than noise suggests a race
whose tiny difference lands either side of a threshold — plausibly in the adaptive
cubic octree, since the profile uses `adaptivecubic` and a `grid` pattern behaves
differently.

## Why it does not invalidate the engine work

The profile's own settings are unaffected. Gates 2, 3 and 6 — byte-identical
G-code against the desktop, filament and time matching exactly, and the full
raw-export workflow — passed in every run while this was being investigated,
across dozens of runs. The instability appears only at a non-default density.

## Why it matters anyway

The app will reuse one engine across many slices, and a person changing infill
density is exactly the case this affects. A filament or time estimate that differs
by 25% between two identical slices would rightly destroy confidence in the tool.

Worth pursuing when there is time to read the adaptive infill code properly.
Reproduce with `tests/gate.cpp`'s gate 7 asserting the direction of the change
rather than only that it changed.
