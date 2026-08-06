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

One concern per patch, with a comment at the top of the diff saying why it
exists and what would let us delete it. Most patches here should be candidates
for upstreaming or for deletion at the next engine bump — a patch with no stated
reason becomes permanent by accident.

## Bumping the engine

Change `ORCA_TAG`/`ORCA_SHA` in `scripts/fetch-orca.sh` and re-run it. Patches
that no longer apply are the entire cost of the bump, which is why the stack
stays small and each patch stays narrow.
