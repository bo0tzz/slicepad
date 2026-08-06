// Software rendering for G-code thumbnails. Separate from slicepad.cpp because it
// is self-contained pixel work with no libslic3r dependency.
#pragma once

#include <vector>

namespace slicepad {

// Fills `pixels` with width*height RGBA from a packed triangle buffer — nine
// floats per triangle, as sp_mesh_vertices returns. Returns false when there is
// nothing to draw, leaving `pixels` a valid empty frame.
bool render_mesh(const std::vector<float> &mesh, unsigned width, unsigned height,
                 bool transparent_background, std::vector<unsigned char> &pixels);

} // namespace slicepad
