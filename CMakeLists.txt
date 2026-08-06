cmake_minimum_required(VERSION 3.13)
project(slicepad CXX C)

# OrcaSlicer is embedded rather than linked against a prebuilt archive so that
# CMake resolves libslic3r's transitive private dependencies (clipper, admesh,
# mcut, qhull, TBB, CGAL, …) itself. Restating that link line by hand is the
# kind of thing that silently rots.
set(SLIC3R_STATIC        ON  CACHE BOOL "" FORCE)
set(SLIC3R_GUI           OFF CACHE BOOL "" FORCE)
set(SLIC3R_WITH_OCCT     OFF CACHE BOOL "" FORCE)
set(SLIC3R_WITH_OPENCV   OFF CACHE BOOL "" FORCE)
set(SLIC3R_WITH_OPENVDB  OFF CACHE BOOL "" FORCE)

add_subdirectory(third_party/orcaslicer EXCLUDE_FROM_ALL)

# libslic3r's NSVGUtils calls nanosvg, which is header-only and whose
# implementation upstream defines only in the GUI. Attaching ours to libslic3r
# rather than to our own library matters for link order: in a static link the
# implementation has to come after the archive that needs it.
add_library(nanosvg_impl STATIC core/src/nanosvg_impl.c)
target_link_libraries(nanosvg_impl PRIVATE nanosvg)
target_link_libraries(libslic3r PRIVATE nanosvg_impl)

# libslic3r_cgal instantiates tbb::scalable_allocator but does not link
# tbbmalloc, which supplies scalable_malloc/scalable_free. The GCC build gets
# away with it because those calls happen to be elided or resolved through
# libslic3r's own link line; clang leaves the references and the link fails.
# Resolved by path rather than through TBB::tbbmalloc: that imported target is
# scoped to Orca's directory and is not visible here.
find_library(SLICEPAD_TBBMALLOC NAMES tbbmalloc REQUIRED)
target_link_libraries(libslic3r_cgal PRIVATE ${SLICEPAD_TBBMALLOC})

add_library(slicepad_core STATIC core/src/slicepad.cpp core/src/thumbnail.cpp)
# Stated explicitly rather than inherited: Orca sets a standard for its own
# targets, and ours are not among them. GCC on Linux defaults to C++17 so this
# went unnoticed, while Apple's clang driver defaults to gnu++98 and every use of
# std::optional, std::filesystem or structured bindings fails. PUBLIC so the CLI
# and the gates get it too.
target_compile_features(slicepad_core PUBLIC cxx_std_17)
target_include_directories(slicepad_core PUBLIC core/include)
# libslic3r exports its generated-header dir publicly but keeps its source dir
# private; Orca's own consumers pick up src/ from a directory-scoped
# include_directories that does not reach a target outside its tree.
target_include_directories(slicepad_core PRIVATE third_party/orcaslicer/src)
target_link_libraries(slicepad_core PUBLIC libslic3r)

add_executable(slicepad-cli cli/main.cpp)
target_link_libraries(slicepad-cli PRIVATE slicepad_core)

# Plain C++ over the C ABI with no platform dependencies, so the same test runs
# on the Linux dev machine and on the iOS Simulator in CI.
add_executable(slicepad-gate tests/gate.cpp)
target_link_libraries(slicepad-gate PRIVATE slicepad_core)

enable_testing()
add_test(NAME gates
         COMMAND slicepad-gate ${CMAKE_CURRENT_SOURCE_DIR}/testdata
                               ${CMAKE_CURRENT_BINARY_DIR}/gate-work)
