// Renders a G-code thumbnail without a GPU.
//
// Orca's own thumbnails come from the GL canvas, which a headless build has no
// access to, and Mainsail and Fluidd both display whatever the G-code carries. So
// this is a small software rasteriser: flat-shaded triangles with a depth buffer,
// viewed from a fixed three-quarter angle.
//
// libslic3r handles the PNG encoding and embedding — ThumbnailData is just RGBA
// pixels — so this only has to fill a buffer.
#include "thumbnail.hpp"

#include <algorithm>
#include <cmath>

namespace slicepad {

namespace {

struct Projected {
    float x, y, depth;
};

// A fixed three-quarter view: yaw a little off-axis, then tip forward, which is
// close to what the desktop shows and reads better than a plan view.
struct View {
    float cos_yaw, sin_yaw, cos_pitch, sin_pitch;

    static View standard()
    {
        const float yaw = -35.0f * float(M_PI) / 180.0f;
        const float pitch = 60.0f * float(M_PI) / 180.0f;
        return {std::cos(yaw), std::sin(yaw), std::cos(pitch), std::sin(pitch)};
    }

    // Returns view-space coordinates: x right, y up, depth increasing away.
    Projected apply(float x, float y, float z) const
    {
        const float rx = x * cos_yaw - y * sin_yaw;
        const float ry = x * sin_yaw + y * cos_yaw;
        return {rx, z * sin_pitch - ry * cos_pitch, ry * sin_pitch + z * cos_pitch};
    }
};

void shade_triangle(std::vector<unsigned char> &pixels, std::vector<float> &depth,
                    unsigned width, unsigned height, const Projected v[3],
                    unsigned char grey)
{
    const float min_x = std::min({v[0].x, v[1].x, v[2].x});
    const float max_x = std::max({v[0].x, v[1].x, v[2].x});
    const float min_y = std::min({v[0].y, v[1].y, v[2].y});
    const float max_y = std::max({v[0].y, v[1].y, v[2].y});

    const int x0 = std::max(0, int(std::floor(min_x)));
    const int x1 = std::min(int(width) - 1, int(std::ceil(max_x)));
    const int y0 = std::max(0, int(std::floor(min_y)));
    const int y1 = std::min(int(height) - 1, int(std::ceil(max_y)));

    const float area = (v[1].x - v[0].x) * (v[2].y - v[0].y) -
                       (v[2].x - v[0].x) * (v[1].y - v[0].y);
    if (std::fabs(area) < 1e-6f)
        return; // degenerate after projection

    for (int y = y0; y <= y1; ++y) {
        for (int x = x0; x <= x1; ++x) {
            const float px = float(x) + 0.5f;
            const float py = float(y) + 0.5f;
            // Barycentric weights, used both for the inside test and for depth.
            const float w0 = ((v[1].x - px) * (v[2].y - py) - (v[2].x - px) * (v[1].y - py)) / area;
            const float w1 = ((v[2].x - px) * (v[0].y - py) - (v[0].x - px) * (v[2].y - py)) / area;
            const float w2 = 1.0f - w0 - w1;
            if (w0 < 0.0f || w1 < 0.0f || w2 < 0.0f)
                continue;

            const float d = w0 * v[0].depth + w1 * v[1].depth + w2 * v[2].depth;
            const size_t index = size_t(y) * width + size_t(x);
            if (d >= depth[index])
                continue;
            depth[index] = d;
            unsigned char *pixel = &pixels[index * 4];
            pixel[0] = grey;
            pixel[1] = grey;
            pixel[2] = grey;
            pixel[3] = 255;
        }
    }
}

bool render_exact(const std::vector<float> &mesh, unsigned width, unsigned height,
                  bool transparent_background, std::vector<unsigned char> &pixels)
{
    pixels.assign(size_t(width) * height * 4, 0);
    if (!transparent_background)
        for (size_t i = 0; i < pixels.size(); i += 4) {
            pixels[i] = pixels[i + 1] = pixels[i + 2] = 30;
            pixels[i + 3] = 255;
        }

    const size_t triangles = mesh.size() / 9;
    if (triangles == 0 || width == 0 || height == 0)
        return false;

    const View view = View::standard();

    // Fit the projected model into the frame, leaving a small margin.
    float min_x = 1e30f, max_x = -1e30f, min_y = 1e30f, max_y = -1e30f;
    for (size_t i = 0; i < mesh.size(); i += 3) {
        const Projected p = view.apply(mesh[i], mesh[i + 1], mesh[i + 2]);
        min_x = std::min(min_x, p.x); max_x = std::max(max_x, p.x);
        min_y = std::min(min_y, p.y); max_y = std::max(max_y, p.y);
    }
    const float span_x = std::max(max_x - min_x, 1e-3f);
    const float span_y = std::max(max_y - min_y, 1e-3f);
    const float margin = 0.06f;
    const float scale = std::min(float(width) * (1.0f - 2 * margin) / span_x,
                                 float(height) * (1.0f - 2 * margin) / span_y);
    const float offset_x = (float(width) - span_x * scale) / 2.0f;
    const float offset_y = (float(height) - span_y * scale) / 2.0f;

    std::vector<float> depth(size_t(width) * height, 1e30f);

    for (size_t t = 0; t < triangles; ++t) {
        const float *corner = &mesh[t * 9];
        Projected v[3];
        for (int i = 0; i < 3; ++i) {
            const Projected p = view.apply(corner[i * 3], corner[i * 3 + 1], corner[i * 3 + 2]);
            v[i].x = offset_x + (p.x - min_x) * scale;
            // Row 0 is the bottom of the picture, not the top. libslic3r's
            // thumbnails come from glReadPixels, so its PNG encoder is told to
            // flip what it is given; a buffer in screen order comes out of that
            // upside down. Row index therefore rises with the view's y.
            v[i].y = offset_y + (p.y - min_y) * scale;
            v[i].depth = p.depth;
        }

        // Flat shading from the geometric normal against a light over the viewer's
        // shoulder. Enough to read the shape; no attempt at anything prettier.
        const float ax = corner[3] - corner[0], ay = corner[4] - corner[1], az = corner[5] - corner[2];
        const float bx = corner[6] - corner[0], by = corner[7] - corner[1], bz = corner[8] - corner[2];
        float nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
        const float length = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (length > 0.0f) { nx /= length; ny /= length; nz /= length; }
        const float lighting = std::fabs(0.35f * nx + 0.35f * ny + 0.87f * nz);
        const auto grey = static_cast<unsigned char>(90.0f + 150.0f * std::min(lighting, 1.0f));

        shade_triangle(pixels, depth, width, height, v, grey);
    }
    return true;
}

} // namespace

bool render_mesh(const std::vector<float> &mesh, unsigned width, unsigned height,
                 bool transparent_background, std::vector<unsigned char> &pixels)
{
    // Rendered larger and averaged down. A triangle covers a pixel or it does
    // not — there is no coverage to shade with — so every silhouette comes out
    // as stair steps at thumbnail sizes. Three times is enough to read as smooth
    // and costs nine times a few hundred kilobytes.
    constexpr unsigned kSupersample = 3;
    const unsigned wide = width * kSupersample;
    const unsigned tall = height * kSupersample;
    if (width == 0 || height == 0 || wide / kSupersample != width)
        return render_exact(mesh, width, height, transparent_background, pixels);

    std::vector<unsigned char> large;
    if (!render_exact(mesh, wide, tall, transparent_background, large))
        return false;

    pixels.assign(size_t(width) * height * 4, 0);
    for (unsigned y = 0; y < height; ++y) {
        for (unsigned x = 0; x < width; ++x) {
            // Averaged with alpha weighting the colour, so a half-covered edge
            // against a transparent background keeps the shade of the part
            // rather than being dragged towards the empty pixels it borders.
            unsigned alpha = 0, red = 0, green = 0, blue = 0;
            for (unsigned dy = 0; dy < kSupersample; ++dy) {
                for (unsigned dx = 0; dx < kSupersample; ++dx) {
                    const unsigned char *p =
                        &large[((size_t(y) * kSupersample + dy) * wide +
                                size_t(x) * kSupersample + dx) * 4];
                    alpha += p[3];
                    red += unsigned(p[0]) * p[3];
                    green += unsigned(p[1]) * p[3];
                    blue += unsigned(p[2]) * p[3];
                }
            }
            unsigned char *out = &pixels[(size_t(y) * width + x) * 4];
            constexpr unsigned samples = kSupersample * kSupersample;
            out[3] = static_cast<unsigned char>(alpha / samples);
            if (alpha > 0) {
                out[0] = static_cast<unsigned char>(red / alpha);
                out[1] = static_cast<unsigned char>(green / alpha);
                out[2] = static_cast<unsigned char>(blue / alpha);
            }
        }
    }
    return true;
}

} // namespace slicepad
