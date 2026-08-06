// Provides nanosvg's implementation for a headless build.
//
// nanosvg is header-only and needs exactly one translation unit to define
// NANOSVG_IMPLEMENTATION. Upstream does that in src/slic3r/GUI/BitmapCache.cpp,
// so libslic3r calls nsvgParse/nsvgDelete from NSVGUtils.cpp while depending on
// the GUI to supply them — which does not link with SLIC3R_GUI=OFF.
//
// Kept here rather than as an engine patch: it is three lines, and every patch
// is a cost at the next version bump. Delete it if upstream ever gives the
// nanosvg target a real implementation TU.
#define NANOSVG_IMPLEMENTATION
#define NANOSVG_ALL_COLOR_KEYWORDS
#include "nanosvg.h"
