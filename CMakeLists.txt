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

add_library(slicepad_core STATIC core/src/slicepad.cpp)
target_include_directories(slicepad_core PUBLIC core/include)
# libslic3r exports its generated-header dir publicly but keeps its source dir
# private; Orca's own consumers pick up src/ from a directory-scoped
# include_directories that does not reach a target outside its tree.
target_include_directories(slicepad_core PRIVATE third_party/orcaslicer/src)
target_link_libraries(slicepad_core PUBLIC libslic3r)

add_executable(slicepad-cli cli/main.cpp)
target_link_libraries(slicepad-cli PRIVATE slicepad_core)
