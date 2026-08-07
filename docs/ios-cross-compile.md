# Cross-compiling the dependency set to iOS

OrcaSlicer's `deps/` superbuild has one assumption running through it: the target
is the machine doing the building. Every failure here has been a consequence of
that, and they arrive one at a time, each hidden behind the last — so this is a
record of the shape rather than a list to fix in one go.

Patches 0010–0012 hold the changes.

## The assumption, in its various disguises

`CMAKE_SYSTEM_PROCESSOR` is empty for iOS. On a native build it names the host's
architecture, so recipes reach for it whenever they want either the target *or*
the build machine, and the two readings are indistinguishable until they differ.

Downstream of that, in the order they surfaced:

- `list(FIND ...)` and OpenSSL's `STREQUAL` on an empty string — a target that is
  simply not in the table (patch 0010).
- GMP's `--build` triple came out as `-apple-darwin`, which `config.sub` rejects
  before anything compiles (patch 0011).
- MPFR passed a bare `--host=` from `TOOLCHAIN_PREFIX`, a Linux cross convention
  that is never set on Apple (patch 0011).
- Sub-builds inherited neither `CMAKE_SYSTEM_NAME` nor the sysroot nor the
  deployment target, so each external project configured itself for macOS inside
  an iOS build (patch 0012).

## Autoconf needs the triples to actually differ

Setting `--build` and `--host` to the same thing makes autoconf conclude the build
is native, so it compiles and runs its test binaries — which on an iOS sysroot
produces `could not find a working compiler`, a message that means something quite
different from what it says.

Making the platform differ (`aarch64-apple-ios` against `aarch64-apple-darwin`) is
the honest fix, and `config.sub` in the pinned GMP accepts it. Two things follow
from it:

- **A cross build needs two compilers.** GMP runs generator programs it has just
  built, so it wants `CC_FOR_BUILD` as well as `CC`. Naming a compiler is not
  enough: an iOS build exports `SDKROOT`, clang honours it, and a bare
  `/usr/bin/clang` therefore still emits iOS binaries. `-isysroot` outranks
  `SDKROOT` and is what makes it a build-machine compiler.
- **GMP's assembly goes with it.** It picks relocation syntax from the host OS,
  and `ios` matches none of its `*-darwin*` patterns, so it emits the ELF form and
  the Mach-O assembler rejects `adrp x7, :got:sym`. Hence `--disable-assembly` on
  iOS, and generic C for bignum arithmetic — which here is CGAL's exact
  predicates, not the slicing hot path.

## Things that are about the platform, not the architecture

Once the triples were right, the remaining failures were all of one kind: a
setting that is correct for macOS and meaningless or wrong for iOS.

- **App bundles.** CMake makes every executable a bundle on iOS. Several
  dependencies build command-line tools and install them with only a runtime
  destination, so they fail to configure with "no BUNDLE DESTINATION". Qhull hits
  it first; PNG, JPEG and Expat would each hit it in turn, so
  `CMAKE_MACOSX_BUNDLE=OFF` is set once for all sub-builds.
- **OpenSSL's sysroot.** Its `ios64-cross` target composes `-isysroot` from
  `CROSS_TOP` and `CROSS_SDK`. Unset, that becomes the literal `/SDKs/`, and every
  file fails to find a header while the configure step reports success. Naming the
  sysroot outright avoids depending on Xcode's directory layout as well.
- **Where find_package looks.** An iOS toolchain confines searches to the sysroot,
  so a dependency prefix that a native build finds through `CMAKE_PREFIX_PATH` is
  invisible. It has to be named in `CMAKE_FIND_ROOT_PATH` too.

## The same bug, four times

`list(FIND CMAKE_OSX_ARCHITECTURES ${CMAKE_SYSTEM_PROCESSOR} ...)` appears in both
`deps/CMakeLists.txt` and the engine's own root `CMakeLists.txt`. Fixing the first
(patch 0010) left the second to be discovered later, by which point the whole
dependency set had to build before configuration could even reach it.

The lesson recorded below — grep for the class, not the instance — was written
after the second occurrence and still did not prevent the fourth, because the
grep was scoped to `deps/`. Widen the search to the whole tree.

## What this costs, and what to do about it

Each round trip is a CI build of a long dependency chain, and a fix only reveals
the next failure. Two things have helped: reading `config.log` in full rather than
the summary line, since autotools explain themselves there and nowhere else, and
checking the recipes for the *class* of problem after each fix rather than only
the instance — the empty-`CMAKE_SYSTEM_PROCESSOR` mistake appears in several
places and was worth grepping for once rather than meeting four times.

Guessing at causes from symptoms has been reliably wrong here. The same message —
`could not find a working compiler` — has now meant a missing SDK path, an
identical build/host pair, and a build compiler producing the wrong binaries.
