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
