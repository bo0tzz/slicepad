# Getting the app onto an iPad

The App Store is not available to this project — OrcaSlicer is AGPL-3.0 and
Apple's terms are incompatible with it, and the copyright is not ours to add an
exception to. So installation is sideloading, and the build is unsigned: SideStore
signs with the certificate of the device doing the installing.

## From CI

Every green run of the `ios-arm64` job publishes `SlicePad-unsigned-ipa` as a
workflow artifact. Download it from the run's summary page, unzip it — GitHub
wraps artifacts in a zip of their own — and open the `.ipa` in SideStore.

Or with the CLI:

```sh
gh run download -R bo0tzz/slicepad -n SlicePad-unsigned-ipa
```

## Locally, on a Mac

```sh
mise run ipa          # build/SlicePad.ipa
```

This needs the iOS dependency prefix, which `mise run deps` builds when given the
iOS CMake flags — see the `ios-arm64` job in `.github/workflows/ci.yml` for the
exact set.

## What to expect on the device

A free Apple ID signs for seven days, after which SideStore has to refresh the
app; a paid developer account extends that to a year. Neither is something this
project can do anything about.

The app is iPad-only. It asks for two files, separately: a profile — a project
`.3mf` saved from desktop Orca — and a model. Both come in through the document
picker, so they can live in iCloud Drive, on the device, or anywhere else Files
can reach, including Shapr3D's own export.

## Through SideStore's source list

Once a release exists, add this to SideStore under **Sources → +**:

```
https://raw.githubusercontent.com/bo0tzz/slicepad/main/sidestore.json
```

SlicePad then appears in the source and installs like any other app, and later
releases show up as updates rather than needing another manual `.ipa`.

The source file is written by `scripts/update-source.py` during the release
workflow and committed back to `main`, so what SideStore reads is always the
file in the repository. Each entry carries the `.ipa`'s size and SHA-256, which
SideStore checks against what it downloaded.

## Cutting a release

Push a tag:

```sh
git tag v0.0.1 && git push origin v0.0.1
```

That builds the app, verifies the bundle, attaches `SlicePad.ipa` to a GitHub
release, and adds the version to `sidestore.json`. `MARKETING_VERSION` comes from
the tag, so the version the app reports cannot drift from the one released.
