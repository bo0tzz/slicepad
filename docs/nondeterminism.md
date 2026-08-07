# A nondeterministic slice result — and why it was ours

Resolved. This file previously described an apparent nondeterminism in
libslic3r's adaptive infill. The engine was fine. The bug was in how this project
drove it.

Kept rather than deleted, because the reasoning was wrong in an instructive way.

## The symptom

Slicing the fixture with `sparse_infill_density=60%` yielded **either 435.82mm or
329.44mm** of filament. Both exact and repeatable: a given process always produced
the same one, repeating the slice within that process gave the same answer every
time, and roughly one run in three took the other branch.

## The cause

`sp_slice` constructed a **fresh `Print` for every slice**. Desktop Orca keeps one
`Print` alive for the session and calls `apply()` on it repeatedly — the whole
invalidation machinery in `PrintBase` exists for that. Building a new one each
time is not how the library expects to be driven, and it left state that
influenced later slices.

Using one `Print` per engine and applying to it makes the result identical across
runs. It also changes the correct answer: 60% infill uses **442mm**, not the
435.82mm that had looked like the "good" branch. Both previous values were wrong.

## What the investigation got right and wrong

Everything ruled out was about *inputs* — the resolved configuration, the model's
bounds, ASLR, engine state, whether slicing was deterministic in isolation. All of
that was sound and all of it was beside the point, because the calling pattern was
never questioned.

The strongest clue was recorded and misread: **a single slice in a process was
always stable, and only repeated slices flipped**. That is the signature of reused
state. It was written down as evidence that "slicing in general is fine" rather
than as a pointer at the thing doing the reusing.

An amplifier was also identified — `FillAdaptive`'s octree depth is a step
function of `max_cube_edge_length / line_spacing`, so a tiny difference flips a
whole level of subdivision. That part still stands and explains why the symptom
was two discrete values rather than noise. It was an accurate explanation of the
mechanism attached to an incorrect assumption about the source.

## Two bugs it was hiding

Switching to a persistent `Print` immediately exposed two more, both invisible
while every slice got a fresh object:

- **Cancellation was sticky.** `print.cancel()` leaves the Print flagged, so every
  later slice failed instantly with "cancelled" until `restart()` was called first.
- **The status callback outlived its slice.** Passing a null progress callback left
  the *previous* one installed — so a slice after a cancelled one inherited the
  cancelling callback and cancelled itself.

Neither could have been caught by a fresh Print per slice, and both would have hit
a real UI: slice, cancel, slice again.

## The lesson worth keeping

The question "is the library nondeterministic?" was asked and answered carefully
for a week's worth of hypotheses. The question "am I using it the way it expects?"
was never asked, and it took someone pointing out that a 25% swing is implausible
for software this widely used.
