# Engine patches

Changes to OrcaSlicer itself live here as numbered patches, applied in
filename order by `scripts/fetch-orca.sh` on top of the pinned commit.

`third_party/orcaslicer/` is a build artifact — it is gitignored, and any edit
you make there is lost on the next fetch. The patch stack is the source of
truth.

## Adding a patch

Edit the checkout, then extract the diff:

```sh
git -C third_party/orcaslicer diff > patches/0003-short-description.patch
```

That works for a *new* patch, and only because a new patch is the last one — the
diff then contains nothing but your edit.

## Changing an existing patch

Do not use `git diff` for this. It returns the changes of every patch that touches
the file, so the regenerated patch becomes a superset that no longer applies over
its predecessors. Diffing against the current file is wrong in the opposite
direction, keeping only the new edit and dropping the rest. Both mistakes have
been made here, and `check-patches.sh` caught both.

```sh
scripts/regen-patch.sh edit   patches/0012-forward-apple-platform.patch
# edit third_party/orcaslicer/...
scripts/regen-patch.sh finish patches/0012-forward-apple-platform.patch
mise run check-patches
```

`edit` rewinds the checkout to that patch, leaving the ones after it unapplied —
otherwise their changes are indistinguishable from yours and get folded in.
`finish` diffs against the same baseline the patch is meant to apply to, keeps the
comment block at the top, and puts the full stack back.

One concern per patch, with a comment at the top of the diff saying why it
exists and what would let us delete it. Most patches here should be candidates
for upstreaming or for deletion at the next engine bump — a patch with no stated
reason becomes permanent by accident.

## Bumping the engine

Change `ORCA_TAG`/`ORCA_SHA` in `scripts/fetch-orca.sh` and re-run it. Patches
that no longer apply are the entire cost of the bump, which is why the stack
stays small and each patch stays narrow.
