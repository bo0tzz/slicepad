// The project's two correctness gates, as a portable test.
//
//   slicepad-gate <fixtures-dir> <writable-dir>
//
// Deliberately plain C++ over slicepad.h with no platform dependencies and no
// shell, so the same source runs on the Linux dev machine and on the iOS
// Simulator in CI. Anything Apple-specific belongs above the C ABI, never here.
//
// Gate 1 compares the resolved configuration against the config block Orca
// embeds in reference.gcode; it needs no slicing and catches profile handling.
// Gate 2 slices the fixture mesh and compares every G/M command line in order.
#include "slicepad.h"

// The one exception to going through the C ABI. Thumbnail orientation is not
// observable from the outside without a PNG decoder, and it was wrong in a
// shipped build.
#include "thumbnail.hpp"

#include <algorithm>
#include <filesystem>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

// Byte-equal G-code is a property of identical code generation, not of the engine.
// Building the same source for x86-64-v3, where the compiler vectorises
// differently, changes the output, and the slicer's thresholds amplify tiny
// differences into whole millimetres. Disabling fused multiply-add changes nothing
// on either architecture, so this is not something a flag fixes.
#if defined(__x86_64__) || defined(_M_X64)
constexpr bool kReferenceArchitecture = true;   // where reference.gcode was made
#else
constexpr bool kReferenceArchitecture = false;
#endif



// Keys where a difference from the reference is understood and expected.
const std::vector<std::pair<const char *, const char *>> kKnownConfigDiffs = {
    {"enable_prime_tower",
     "Orca normalises the prime tower off for single-filament prints, so the "
     "reference records the post-slice value while the project stores the "
     "pre-slice one"},
    {"extruder_colour", "a display colour with no effect on toolpaths"},
};

std::string read_file(const std::string &path)
{
    std::ifstream in(path, std::ios::binary);
    std::ostringstream buffer;
    buffer << in.rdbuf();
    return buffer.str();
}

std::string trim(const std::string &text)
{
    const size_t first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos)
        return {};
    const size_t last = text.find_last_not_of(" \t\r\n");
    return text.substr(first, last - first + 1);
}

std::vector<std::string> lines_of(const std::string &text)
{
    std::vector<std::string> out;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        out.push_back(line);
    }
    return out;
}

// "key = value" pairs, from either our config dump or the "; key = value"
// comment block Orca writes into its G-code.
std::map<std::string, std::string> parse_config(const std::string &text, bool comment_prefixed)
{
    std::map<std::string, std::string> out;
    for (const std::string &raw : lines_of(text)) {
        std::string line = raw;
        if (comment_prefixed) {
            if (line.rfind("; ", 0) != 0)
                continue;
            line = line.substr(2);
        }
        const size_t sep = line.find(" = ");
        if (sep == std::string::npos)
            continue;
        const std::string key = trim(line.substr(0, sep));
        if (key.empty() || key.find(' ') != std::string::npos)
            continue;
        out[key] = trim(line.substr(sep + 3));
    }
    return out;
}

// G-code motion and machine commands, ignoring comments and metadata so that
// timestamps and embedded thumbnails do not register as differences.
std::vector<std::string> commands_of(const std::string &gcode)
{
    std::vector<std::string> out;
    for (const std::string &line : lines_of(gcode))
        if (!line.empty() && (line[0] == 'G' || line[0] == 'M'))
            out.push_back(line);
    return out;
}

bool is_known_diff(const std::string &key)
{
    return std::any_of(kKnownConfigDiffs.begin(), kKnownConfigDiffs.end(),
                       [&](const auto &entry) { return key == entry.first; });
}

// Minimal extractors so the test stays free of a JSON dependency.
double number_after(const std::string &text, const std::string &needle)
{
    const size_t at = text.find(needle);
    if (at == std::string::npos)
        return -1.0;
    return std::strtod(text.c_str() + at + needle.size(), nullptr);
}

// "1m 44s", "2h 3m 5s" and bare "44s" all appear in Orca's output.
double seconds_from_duration(const std::string &text)
{
    double total = 0.0;
    double value = 0.0;
    for (size_t i = 0; i < text.size(); ++i) {
        if (std::isdigit(static_cast<unsigned char>(text[i]))) {
            value = value * 10 + (text[i] - '0');
        } else if (text[i] == 'h') { total += value * 3600; value = 0; }
        else if (text[i] == 'm') { total += value * 60;   value = 0; }
        else if (text[i] == 's') { total += value;        value = 0; }
    }
    return total;
}

std::string line_containing(const std::string &text, const std::string &needle)
{
    for (const std::string &line : lines_of(text))
        if (line.find(needle) != std::string::npos)
            return line;
    return {};
}

// Exactly what the app sends: the three controls it exposes, on every slice.
const char *const kAppOverrides =
    "{\"wall_loops\": \"3\", \"sparse_infill_density\": \"20%\", \"enable_support\": \"0\"}";

// Every gate reports itself, and the total is checked at the end. Deleting a gate
// otherwise looks exactly like it passing — which is how five of them once went
// missing while the suite still said PASS.
int gates_reported = 0;

int reported(const char *gate)
{
    ++gates_reported;
    return 0;
}

int fail(const char *gate, const std::string &detail)
{
    std::fprintf(stderr, "FAIL %s: %s\n", gate, detail.c_str());
    return 1;
}


// Compares produced G-code against the desktop's. Byte equality is required only
// on the architecture the reference was made on; elsewhere the same object is
// required rather than the same bytes. Shared so the rule cannot drift between
// the gates that use it.
int compare_gcode(const char *gate, const std::vector<std::string> &ref,
                  const std::vector<std::string> &ours)
{
    if (ref.size() < 1000 || ours.size() < 1000)
        return fail(gate, "implausibly few commands — check the fixtures parsed");

    if (!kReferenceArchitecture) {
        auto extrusions = [](const std::vector<std::string> &cmds) {
            size_t n = 0;
            for (const std::string &c : cmds) {
                const size_t e = c.find(" E");
                if (c.rfind("G1", 0) == 0 && e != std::string::npos &&
                    (std::isdigit(static_cast<unsigned char>(c[e + 2])) || c[e + 2] == '.'))
                    ++n;
            }
            return n;
        };
        const double theirs = double(extrusions(ref)), mine = double(extrusions(ours));
        const double drift = std::fabs(mine - theirs) / theirs;
        const double size_drift =
            std::fabs(double(ours.size()) - double(ref.size())) / double(ref.size());
        if (drift > 0.02 || size_drift > 0.03)
            return fail(gate, "differs by more than code generation explains: " +
                                  std::to_string(size_t(theirs)) + " extrusions against " +
                                  std::to_string(size_t(mine)));
        std::printf("%s gcode: %zu commands against %zu, extrusions within %.1f%% "
                    "(not the reference architecture, so equivalence not equality)\n",
                    gate, ours.size(), ref.size(), drift * 100.0);
        return reported(gate);
    }

    if (ref.size() != ours.size()) {
        auto tally = [](const std::vector<std::string> &cmds) {
            std::map<std::string, size_t> counts;
            for (const std::string &c : cmds)
                counts[c.substr(0, c.find_first_of(" \t"))]++;
            return counts;
        };
        const auto theirs = tally(ref), mine = tally(ours);
        std::string detail = "command count differs (" + std::to_string(ref.size()) + " vs " +
                             std::to_string(ours.size()) + "):";
        for (const auto &[opcode, n] : theirs) {
            const auto found = mine.find(opcode);
            const size_t got = found == mine.end() ? 0 : found->second;
            if (got != n)
                detail += " " + opcode + " " + std::to_string(n) + "->" + std::to_string(got);
        }
        return fail(gate, detail);
    }

    for (size_t i = 0; i < ref.size(); ++i)
        if (ref[i] != ours[i])
            return fail(gate, "first difference at command " + std::to_string(i) +
                                  "\n  reference: " + ref[i] + "\n  ours:      " + ours[i]);

    std::printf("%s gcode: all %zu commands identical in sequence\n", gate, ref.size());
    return reported(gate);
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 3) {
        std::fputs("usage: slicepad-gate <fixtures-dir> <writable-dir>\n", stderr);
        return 2;
    }
    const std::string fixtures = argv[1];
    const std::string work = argv[2];

    // The engine writes a temporary profile here and the sliced G-code, so the
    // directory has to exist before anything else. CI passes a path that does
    // not exist yet.
    std::error_code ec;
    std::filesystem::create_directories(work, ec);
    if (ec)
        return fail("setup", "cannot create working directory " + work + ": " + ec.message());

    const std::string profile = fixtures + "/empty.3mf";
    const std::string model = fixtures + "/model.3mf";
    const std::string reference = fixtures + "/reference.gcode";

    // Resources only need to exist; profiles arrive fully resolved.
    sp_engine *engine = sp_engine_create(fixtures.c_str(), work.c_str());
    if (engine == nullptr)
        return fail("setup", "could not create engine");

    int failures = 0;

    if (sp_load_config(engine, profile.c_str()) != SP_OK) {
        failures += fail("gate1", std::string("loading profile: ") + sp_last_error(engine));
    } else {
        const auto ours = parse_config(sp_resolved_config_text(engine), false);
        const auto ref = parse_config(read_file(reference), true);

        size_t compared = 0, matched = 0;
        std::vector<std::string> unexpected;
        for (const auto &[key, ref_value] : ref) {
            const auto found = ours.find(key);
            if (found == ours.end())
                continue; // the G-code omits some keys and adds legacy aliases
            ++compared;
            if (found->second == ref_value)
                ++matched;
            else if (!is_known_diff(key))
                unexpected.push_back(key + " (reference " + ref_value + ", ours " + found->second + ")");
        }

        reported("gate1"), std::printf("gate1 config: %zu/%zu keys identical, %zu known differences\n",
                    matched, compared, compared - matched);
        if (compared < 500)
            failures += fail("gate1", "suspiciously few keys compared — is the reference intact?");
        for (const std::string &key : unexpected)
            failures += fail("gate1", "unexpected difference: " + key);
    }

    const std::string produced = work + "/gate.gcode";
    if (sp_load_model(engine, model.c_str()) != SP_OK) {
        failures += fail("gate2", std::string("loading model: ") + sp_last_error(engine));
    } else if (sp_slice(engine, produced.c_str(), nullptr, nullptr) != SP_OK) {
        failures += fail("gate2", std::string("slicing: ") + sp_last_error(engine));
    } else {
        const auto ref = commands_of(read_file(reference));
        const auto ours = commands_of(read_file(produced));
        reported("gate2"), std::printf("gate2 gcode: %zu reference commands, %zu ours\n", ref.size(), ours.size());
        failures += compare_gcode("gate2", ref, ours);
    }

    // Gate 3: the figures a UI shows must agree with what the desktop reports
    // for the same job, since a number that is quietly wrong by a little is
    // worse than one that is obviously missing.
    if (failures == 0) {
        const std::string stats = sp_slice_stats_json(engine);
        const std::string ref = read_file(reference);

        struct Check { const char *label; double ours; double theirs; double tolerance; };
        const std::string time_line = line_containing(ref, "estimated printing time (normal mode)");
        const Check checks[] = {
            {"filament_mm", number_after(stats, "\"filament_mm\":"),
             number_after(line_containing(ref, "filament used [mm]"), "= "), 0.01},
            {"filament_grams", number_after(stats, "\"filament_grams\":"),
             number_after(line_containing(ref, "total filament used [g]"), "= "), 0.01},
            {"layer_count", number_after(stats, "\"layer_count\":"),
             number_after(line_containing(ref, "total layer number:"), ": "), 0.0},
            {"estimated_seconds", number_after(stats, "\"estimated_seconds\":"),
             seconds_from_duration(time_line.substr(time_line.find("= ") + 2)), 0.01},
        };

        for (const Check &check : checks) {
            if (check.theirs <= 0.0) {
                failures += fail("gate3", std::string("no reference value for ") + check.label);
                continue;
            }
            const double drift = std::fabs(check.ours - check.theirs) / check.theirs;
            if (drift > check.tolerance)
                failures += fail("gate3", std::string(check.label) + ": ours " +
                                              std::to_string(check.ours) + ", desktop " +
                                              std::to_string(check.theirs));
        }
        if (failures == 0)
            std::puts("gate3 stats: filament, layers and time agree with the desktop");

        // Gate 4: the toolpath handed to a renderer must actually describe the
        // printed object. Cheap to check and worth doing before any view is built
        // on top of it: the tallest extrusion should reach the same height the
        // desktop's G-code does.
        const size_t segments = sp_toolpath_segment_count(engine);
        const float *packed = sp_toolpath_segments(engine);
        if (segments == 0 || packed == nullptr) {
            failures += fail("gate4", "no toolpath segments produced");
        } else {
            float top = 0.0f;
            for (size_t i = 0; i < segments * 6; i += 3)
                top = std::max(top, packed[i + 2]);

            // The highest Z at which the desktop actually extrudes. Not simply the
            // highest Z move: the last one is the end-of-print lift, a travel, so
            // comparing against that overstates the object by one hop.
            double reference_top = 0.0;
            double current_z = 0.0;
            for (const std::string &line : lines_of(ref)) {
                if (line.rfind("G1", 0) != 0)
                    continue;
                const size_t z_at = line.find(" Z");
                if (z_at != std::string::npos)
                    current_z = std::strtod(line.c_str() + z_at + 2, nullptr);
                // Values are written like "E.33867", so the character after " E"
                // is often a decimal point; only a leading '-' means retraction.
                const size_t e_at = line.find(" E");
                const char after_e = e_at != std::string::npos ? line[e_at + 2] : '\0';
                const bool extruding =
                    e_at != std::string::npos &&
                    (std::isdigit(static_cast<unsigned char>(after_e)) || after_e == '.');
                if (extruding && line.find(" X") != std::string::npos)
                    reference_top = std::max(reference_top, current_z);
            }

            if (reference_top <= 0.0)
                failures += fail("gate4", "no Z moves found in the reference");
            else if (std::fabs(top - reference_top) / reference_top > 0.01)
                failures += fail("gate4", "toolpath top " + std::to_string(top) +
                                              " but the desktop reaches " +
                                              std::to_string(reference_top));
            else
                reported("gate4"), std::printf("gate4 toolpath: %zu segments, top %.2fmm matches the desktop\n",
                            segments, double(top));

            // Gate 5: the geometry a plate view draws. Checked by cross-referencing
            // two independent paths — the mesh buffer against the reported object
            // bounds, and the mesh height against what the slice actually printed —
            // so a transform applied in one place but not the other shows up.
            const size_t triangles = sp_mesh_triangle_count(engine);
            const float *mesh = sp_mesh_vertices(engine);
            float bounds[6] = {0};
            if (triangles == 0 || mesh == nullptr) {
                failures += fail("gate5", "no mesh triangles exposed");
            } else if (sp_object_bounds(engine, 0, bounds) != SP_OK) {
                failures += fail("gate5", std::string("object bounds: ") + sp_last_error(engine));
            } else {
                float lo[3] = {mesh[0], mesh[1], mesh[2]};
                float hi[3] = {mesh[0], mesh[1], mesh[2]};
                for (size_t i = 0; i < triangles * 9; i += 3)
                    for (int axis = 0; axis < 3; ++axis) {
                        lo[axis] = std::min(lo[axis], mesh[i + axis]);
                        hi[axis] = std::max(hi[axis], mesh[i + axis]);
                    }

                for (int axis = 0; axis < 3; ++axis) {
                    if (std::fabs(lo[axis] - bounds[axis]) > 0.05 ||
                        std::fabs(hi[axis] - bounds[axis + 3]) > 0.05) {
                        failures += fail("gate5", "mesh buffer and reported bounds disagree on axis " +
                                                      std::to_string(axis));
                        break;
                    }
                }
                // The printed top should land within a layer of the model's height.
                if (std::fabs(hi[2] - top) > 0.5f)
                    failures += fail("gate5", "model is " + std::to_string(hi[2]) +
                                                  "mm tall but the slice printed to " +
                                                  std::to_string(top));

                const size_t bed_points = sp_bed_point_count(engine);
                if (bed_points < 3)
                    failures += fail("gate5", "printable area has too few points");
                else
                    reported("gate5"), std::printf("gate5 geometry: %zu triangles, %zu bed points, "
                                "model %.1fx%.1fx%.1fmm consistent with the slice\n",
                                triangles, bed_points, double(hi[0] - lo[0]),
                                double(hi[1] - lo[1]), double(hi[2] - lo[2]));
            }
        }
    }

    // Gate 6: the actual target workflow, end to end. A raw CAD export — not a
    // project Orca has already placed — auto-oriented and arranged by us should
    // reproduce what the desktop produced when a person did the same by hand.
    // This is the one gate that exercises the path a user actually takes.
    if (failures == 0) {
        const std::string raw = fixtures + "/model-shapr3d.3mf";
        const std::string out = work + "/raw.gcode";
        if (sp_load_model(engine, raw.c_str()) != SP_OK) {
            failures += fail("gate6", std::string("loading raw export: ") + sp_last_error(engine));
        } else if (sp_auto_orient(engine) != SP_OK) {
            failures += fail("gate6", std::string("auto-orient: ") + sp_last_error(engine));
        } else if (sp_arrange(engine) != SP_OK) {
            failures += fail("gate6", std::string("arrange: ") + sp_last_error(engine));
        } else if (sp_slice(engine, out.c_str(), nullptr, nullptr) != SP_OK) {
            failures += fail("gate6", std::string("slicing: ") + sp_last_error(engine));
        } else {
            // The same rule, via the same code: on a non-reference architecture
            // this asks whether the raw export produces the same object.
            failures += compare_gcode("gate6", commands_of(read_file(reference)),
                                      commands_of(read_file(out)));
        }
    }

    // Gate 7: the three overrides the UI exposes. Accepting a key and validating
    // it against PrintConfigDef proves nothing about whether it reaches the
    // engine, so each is checked for moving filament usage in the direction it
    // should.
    //
    // On its own engine, deliberately. Running these on the engine the gates above
    // have been using gives one of two stable results per process — the same
    // inputs, the same model bounds to six decimals, and yet a baseline of either
    // 385mm or 280mm. Something in libslic3r carries state across slices on one
    // engine, and a test that inherits it measures that instead of the override.
    // Worth remembering beyond the test: the app will reuse one engine too.
    if (failures == 0) {
        sp_engine *fresh = sp_engine_create(fixtures.c_str(), work.c_str());
        if (fresh == nullptr) {
            failures += fail("gate7", "could not create an engine");
        } else if (sp_load_config(fresh, profile.c_str()) != SP_OK ||
                   sp_load_model(fresh, model.c_str()) != SP_OK) {
            failures += fail("gate7", std::string("setting up: ") + sp_last_error(fresh));
        } else {
            auto filament_for = [&](const char *overrides) -> double {
                if (sp_set_overrides(fresh, overrides) != SP_OK)
                    return -1.0;
                const std::string out = work + "/override.gcode";
                if (sp_slice(fresh, out.c_str(), nullptr, nullptr) != SP_OK)
                    return -1.0;
                return number_after(sp_slice_stats_json(fresh), "\"filament_mm\":");
            };

            const double baseline = filament_for(nullptr);
            const double thinner_walls = filament_for("{\"wall_loops\":\"1\"}");
            const double denser_infill = filament_for("{\"sparse_infill_density\":\"60%\"}");

            if (baseline <= 0.0 || thinner_walls <= 0.0 || denser_infill <= 0.0) {
                failures += fail("gate7", std::string("an override slice failed: ") + sp_last_error(fresh));
            } else {
                if (thinner_walls >= baseline)
                    failures += fail("gate7", "one wall loop used " + std::to_string(thinner_walls) +
                                                  "mm, not less than the baseline " +
                                                  std::to_string(baseline));
                if (denser_infill <= baseline)
                    failures += fail("gate7", "60% infill used " + std::to_string(denser_infill) +
                                                  "mm, not more than the baseline " +
                                                  std::to_string(baseline));
                if (failures == 0)
                    reported("gate7"), std::printf("gate7 overrides: baseline %.0fmm, one wall %.0fmm, dense infill %.0fmm\n",
                                baseline, thinner_walls, denser_infill);
            }
            sp_engine_destroy(fresh);
        }
    }

    // Gate 8: cancellation, because the header promises it and a slice on a
    // tablet runs long enough that a caller will want it. Also checks the partial
    // file is cleaned up rather than left looking like a finished slice.
    if (failures == 0) {
        const std::string abandoned = work + "/cancelled.gcode";
        int calls = 0;
        auto cancel_immediately = [](int, const char *, void *counter) {
            ++*static_cast<int *>(counter);
            return 1; // non-zero means stop
        };
        const sp_result outcome = sp_slice(engine, abandoned.c_str(), cancel_immediately, &calls);
        if (outcome != SP_ERR_CANCELLED)
            failures += fail("gate8", "cancelling returned " + std::to_string(int(outcome)) +
                                          " rather than SP_ERR_CANCELLED");
        else if (calls == 0)
            failures += fail("gate8", "the progress callback was never invoked");
        else if (std::filesystem::exists(abandoned))
            failures += fail("gate8", "a cancelled slice left its output file behind");
        else
            reported("gate8"), std::printf("gate8 cancellation: stopped after %d progress calls, no output left\n",
                        calls);
    }

    // Gate 9: the transform controls a UI binds to. Rotation about X or Y is the
    // part that matters — it is how a part stands up — and it is checked by the
    // dimensions it must produce rather than by inspecting a matrix.
    if (failures == 0) {
        const std::string raw = fixtures + "/model-shapr3d.3mf";
        float before[6] = {0}, rotated[6] = {0}, scaled[6] = {0};
        auto extent = [](const float *b, int axis) { return b[axis + 3] - b[axis]; };

        if (sp_load_model(engine, raw.c_str()) != SP_OK ||
            sp_object_bounds(engine, 0, before) != SP_OK) {
            failures += fail("gate9", std::string("reloading the raw export: ") + sp_last_error(engine));
        } else if (sp_set_transform(engine, 0, 1.0, 90.0, 0.0, 0.0, 100.0, 100.0) != SP_OK ||
                   sp_object_bounds(engine, 0, rotated) != SP_OK) {
            failures += fail("gate9", std::string("rotating about X: ") + sp_last_error(engine));
        } else {
            // A quarter turn about X exchanges the Y and Z extents.
            const bool swapped = std::fabs(extent(rotated, 1) - extent(before, 2)) < 0.05 &&
                                 std::fabs(extent(rotated, 2) - extent(before, 1)) < 0.05;
            if (!swapped)
                failures += fail("gate9", "90 degrees about X gave " +
                                              std::to_string(extent(rotated, 1)) + " x " +
                                              std::to_string(extent(rotated, 2)) +
                                              " in Y,Z from " + std::to_string(extent(before, 1)) +
                                              " x " + std::to_string(extent(before, 2)));
            if (rotated[2] < -0.05)
                failures += fail("gate9", "rotation left the object below the bed");

            if (sp_set_transform(engine, 0, 2.0, 0.0, 0.0, 0.0, 100.0, 100.0) != SP_OK ||
                sp_object_bounds(engine, 0, scaled) != SP_OK) {
                failures += fail("gate9", std::string("scaling: ") + sp_last_error(engine));
            } else if (std::fabs(extent(scaled, 0) - 2 * extent(before, 0)) > 0.05) {
                failures += fail("gate9", "scale 2 gave width " + std::to_string(extent(scaled, 0)) +
                                              " from " + std::to_string(extent(before, 0)));
            } else if (failures == 0) {
                reported("gate9"), std::printf("gate9 transform: X rotation swaps Y/Z (%.1f/%.1f -> %.1f/%.1f), "
                            "scale 2 doubles width\n",
                            double(extent(before, 1)), double(extent(before, 2)),
                            double(extent(rotated, 1)), double(extent(rotated, 2)));
            }
        }
    }

    // Gate 11: thumbnails. libslic3r does the PNG encoding, so what is checked
    // here is that our renderer supplied pixels at every size the profile asks
    // for, and that they carry content — a blank frame compresses to a few
    // hundred bytes, so the size floor separates a drawn model from an empty one.
    if (failures == 0) {
        const std::string with_thumbs = work + "/thumbnail.gcode";
        if (sp_load_model(engine, (fixtures + "/model.3mf").c_str()) != SP_OK ||
            sp_slice(engine, with_thumbs.c_str(), nullptr, nullptr) != SP_OK) {
            failures += fail("gate11", std::string("slicing for thumbnails: ") + sp_last_error(engine));
        } else {
            // Sizes are compared per dimension against the desktop's own
            // thumbnails rather than against a fixed floor: a flat threshold is
            // meaningless across 300x300 and 32x32, where even the reference's
            // small one is only 628 bytes.
            auto thumbnails_in = [](const std::string &text) {
                std::map<std::string, long> sizes;
                for (const std::string &line : lines_of(text)) {
                    const size_t at = line.find("thumbnail begin ");
                    if (at == std::string::npos)
                        continue;
                    std::istringstream fields(line.substr(at + 16));
                    std::string dims;
                    long bytes = 0;
                    if (fields >> dims >> bytes)
                        sizes[dims] = bytes;
                }
                return sizes;
            };

            const auto ours_sizes = thumbnails_in(read_file(with_thumbs));
            const auto their_sizes = thumbnails_in(read_file(reference));

            if (ours_sizes.size() != their_sizes.size()) {
                failures += fail("gate11", "produced " + std::to_string(ours_sizes.size()) +
                                               " thumbnails against the desktop's " +
                                               std::to_string(their_sizes.size()));
            } else {
                for (const auto &[dims, theirs] : their_sizes) {
                    const auto found = ours_sizes.find(dims);
                    if (found == ours_sizes.end()) {
                        failures += fail("gate11", "no thumbnail at " + dims);
                    } else if (found->second * 4 < theirs) {
                        // A blank frame compresses to almost nothing, so a quarter
                        // of the desktop's size still separates drawn from empty
                        // while allowing for our simpler shading.
                        failures += fail("gate11", dims + " thumbnail is " +
                                                       std::to_string(found->second) +
                                                       " bytes against the desktop's " +
                                                       std::to_string(theirs));
                    }
                }
                // Which way up they are, which the sizes above cannot see: the
                // thumbnail shipped upside down for two releases because
                // libslic3r's encoder flips whatever it is handed, expecting the
                // OpenGL buffer the desktop gives it.
                //
                // Rendered directly rather than decoded back out of the G-code,
                // which would mean a PNG decoder in here. A broad triangle lying on
                // the bed and a thin spike standing above it: most of the ink is
                // near the ground, so a correct bottom-up buffer is far denser in
                // its low rows, and a flipped one fails this by a wide margin.
                if (failures == 0) {
                    const std::vector<float> ground_and_spike = {
                        -20, -20, 0,   20, -20, 0,    0, 20,  0,
                         -2,   0, 0,    2,   0, 0,    0,  0, 60,
                    };
                    std::vector<unsigned char> pixels;
                    const unsigned side = 64;
                    if (!slicepad::render_mesh(ground_and_spike, side, side, false, pixels)) {
                        failures += fail("gate11", "the rasteriser drew nothing");
                    } else {
                        auto drawn_in = [&](unsigned from, unsigned to) {
                            size_t n = 0;
                            for (unsigned row = from; row < to; ++row)
                                for (unsigned col = 0; col < side; ++col) {
                                    const unsigned char *p = &pixels[(size_t(row) * side + col) * 4];
                                    if (p[0] != 30 || p[1] != 30 || p[2] != 30)
                                        ++n;
                                }
                            return n;
                        };
                        const size_t low = drawn_in(0, side / 2);
                        const size_t high = drawn_in(side / 2, side);
                        if (low <= high)
                            failures += fail("gate11", "the thumbnail is upside down: " +
                                                           std::to_string(low) + " pixels in the bottom "
                                                           "half against " + std::to_string(high) +
                                                           " in the top");
                    }
                }

                if (failures == 0)
                    reported("gate11"), std::printf("gate11 thumbnails: %zu embedded at the desktop's sizes, "
                                "drawn the right way up\n", ours_sizes.size());
            }
        }
    }

    // Gate 10: failure paths, on a fresh engine so the checks above are undisturbed.
    // A UI shows these messages to a person, and picking the wrong file is the
    // likeliest mistake now that profile and model are separate surfaces — so
    // each wrong input must be refused with the right code rather than
    // half-succeeding.
    if (failures == 0) {
        sp_engine *probe = sp_engine_create(fixtures.c_str(), work.c_str());
        if (probe == nullptr) {
            failures += fail("gate10", "could not create a second engine");
        } else {
            struct Case { const char *what; sp_result got; sp_result want; };
            const std::string missing = fixtures + "/does-not-exist.3mf";
            const std::string mesh_only = fixtures + "/model-shapr3d.3mf";
            const std::string carrier = fixtures + "/empty.3mf";

            const Case cases[] = {
                {"profile that does not exist",
                 sp_load_config(probe, missing.c_str()), SP_ERR_IO},
                {"a bare mesh offered as a profile",
                 sp_load_config(probe, mesh_only.c_str()), SP_ERR_UNRESOLVED},
                {"slicing with nothing loaded",
                 sp_slice(probe, (work + "/never.gcode").c_str(), nullptr, nullptr), SP_ERR_STATE},
                {"model that does not exist",
                 sp_load_model(probe, missing.c_str()), SP_ERR_IO},
                {"a profile carrier offered as a model",
                 sp_load_model(probe, carrier.c_str()), SP_ERR_SLICE},
                {"unknown override key",
                 sp_set_overrides(probe, "{\"not_a_real_key\":\"1\"}"), SP_ERR_PARSE},
                {"override value of the wrong shape",
                 sp_set_overrides(probe, "{\"wall_loops\":\"three\"}"), SP_ERR_PARSE},
                {"malformed override JSON",
                 sp_set_overrides(probe, "{oops"), SP_ERR_PARSE},
            };

            for (const Case &c : cases) {
                if (c.got != c.want)
                    failures += fail("gate10", std::string(c.what) + ": returned " +
                                                   std::to_string(int(c.got)) + ", expected " +
                                                   std::to_string(int(c.want)));
                else if (std::string(sp_last_error(probe)).empty())
                    failures += fail("gate10", std::string(c.what) + ": refused without a message");
            }
            if (failures == 0)
                reported("gate10"), std::printf("gate10 failure paths: %zu wrong inputs each refused with a reason\n",
                            sizeof(cases) / sizeof(cases[0]));
            sp_engine_destroy(probe);
        }
    }

    // Gate 12: placement round-trips. sp_set_transform is absolute in every
    // argument, so a caller exposing only some of them has to read the rest back
    // and pass them through unchanged. If it cannot, the app sends zeros — which
    // drops the object on the bed origin and undoes auto-orient, both silently.
    if (failures == 0) {
        sp_engine *probe = sp_engine_create(fixtures.c_str(), work.c_str());
        if (probe == nullptr) {
            failures += fail("gate12", "could not create an engine");
        } else {
            const std::string profile = fixtures + "/model.3mf";
            const std::string mesh = fixtures + "/model-shapr3d.3mf";
            if (sp_load_config(probe, profile.c_str()) != SP_OK ||
                sp_load_model(probe, mesh.c_str()) != SP_OK) {
                failures += fail("gate12", std::string("setup: ") + sp_last_error(probe));
            } else if (sp_set_transform(probe, 0, 1.5, 30, 0, 45, 100, 120) != SP_OK) {
                failures += fail("gate12", std::string("placing: ") + sp_last_error(probe));
            } else {
                const double placed[6] = {1.5, 30, 0, 45, 100, 120};
                double read_back[6] = {0};
                if (sp_object_transform(probe, 0, read_back) != SP_OK) {
                    failures += fail("gate12", std::string("reading back: ") + sp_last_error(probe));
                } else {
                    for (int i = 0; i < 6 && failures == 0; ++i)
                        if (std::fabs(read_back[i] - placed[i]) > 1e-6)
                            failures += fail("gate12", "component " + std::to_string(i) +
                                                           " read back as " +
                                                           std::to_string(read_back[i]) +
                                                           " after being set to " +
                                                           std::to_string(placed[i]));
                }

                // The flow the app actually performs: change one control, pass the
                // rest back as read. Everything not being changed has to survive —
                // without the getter the app sends zeros here, which drops the
                // object on the bed origin and undoes any auto-orientation.
                if (failures == 0) {
                    double next[6] = {0};
                    sp_object_transform(probe, 0, next);
                    next[0] = 2.0;   // as though a scale control moved
                    if (sp_set_transform(probe, 0, next[0], next[1], next[2], next[3],
                                         next[4], next[5]) != SP_OK) {
                        failures += fail("gate12", std::string("re-applying: ") + sp_last_error(probe));
                    } else {
                        double after[6] = {0};
                        sp_object_transform(probe, 0, after);
                        const double want[6] = {2.0, 30, 0, 45, 100, 120};
                        for (int i = 0; i < 6 && failures == 0; ++i)
                            if (std::fabs(after[i] - want[i]) > 1e-6)
                                failures += fail("gate12",
                                                 "changing the scale moved component " +
                                                     std::to_string(i) + " to " +
                                                     std::to_string(after[i]) + ", expected " +
                                                     std::to_string(want[i]));
                    }
                }

                if (failures == 0)
                    reported("gate12"), std::printf(
                        "gate12 placement: round-trips, and changing one control keeps the rest\n");
            }
            sp_engine_destroy(probe);
        }
    }

    // Gate 13: the metadata the ABI reports about itself. Small, and added because
    // every documentation-versus-implementation mismatch found in this ABI so far
    // has been in a function no gate called — including sp_config_source_version,
    // which once returned "" for every profile, was fixed, and could have
    // regressed silently.
    if (failures == 0) {
        sp_engine *probe = sp_engine_create(fixtures.c_str(), work.c_str());
        if (probe == nullptr) {
            failures += fail("gate13", "could not create an engine");
        } else {
            // The reference G-code names the desktop that produced it, which is the
            // version this engine is pinned to. Comparing against that rather than
            // a literal means moving the pin without regenerating the reference is
            // caught here instead of as a mystery in the G-code gates.
            const std::string header = read_file(fixtures + "/reference.gcode").substr(0, 200);
            const std::string marker = "generated by OrcaSlicer ";
            const size_t at = header.find(marker);
            const std::string engine_version = sp_engine_version();
            if (at == std::string::npos) {
                failures += fail("gate13", "the reference G-code does not name its generator");
            } else {
                const size_t start = at + marker.size();
                const std::string reference_version =
                    header.substr(start, header.find(' ', start) - start);
                if (reference_version != engine_version)
                    failures += fail("gate13", "engine reports " + engine_version +
                                                   " but the reference came from " +
                                                   reference_version);
            }

            if (failures == 0 && std::string(sp_engine_config_version()).empty())
                failures += fail("gate13", "the engine reports no config version");

            if (failures == 0 && sp_object_count(probe) != 0)
                failures += fail("gate13", "a fresh engine already has objects");

            const std::string profile = fixtures + "/model.3mf";
            if (failures == 0 && sp_load_config(probe, profile.c_str()) != SP_OK)
                failures += fail("gate13", std::string("loading a profile: ") + sp_last_error(probe));

            // The bug this guards: a profile carries the config version it was
            // saved against, and looking up a key that is not in PrintConfigDef
            // returned an empty string for every profile ever loaded.
            const std::string source_version = sp_config_source_version(probe);
            if (failures == 0 && source_version.empty())
                failures += fail("gate13", "the profile's own config version is empty");

            if (failures == 0 && sp_load_model(probe, (fixtures + "/model-shapr3d.3mf").c_str()) != SP_OK)
                failures += fail("gate13", std::string("loading a model: ") + sp_last_error(probe));
            if (failures == 0 && sp_object_count(probe) != 1)
                failures += fail("gate13", "expected one object, got " +
                                               std::to_string(sp_object_count(probe)));
            // Not asserting a count: this is a real mesh and the number is the
            // engine's business. Asserting it is non-negative and reported at all
            // is the contract — a UI shows it before someone prints.
            if (failures == 0 && sp_model_repaired_errors(probe) < 0)
                failures += fail("gate13", "negative repaired-error count");

            if (failures == 0)
                reported("gate13"), std::printf(
                    "gate13 metadata: engine %s, config %s, profile saved against %s, "
                    "1 object, %d repairs\n",
                    engine_version.c_str(), sp_engine_config_version(),
                    source_version.c_str(), sp_model_repaired_errors(probe));
            sp_engine_destroy(probe);
        }
    }

    // Gate 14: slicing twice without changing anything gives the same answer.
    // Reported from a real device — the second slice emptied the statistics and the
    // layer view fell back to the solid model, while auto-orient fixed it only when
    // it actually moved the object.
    //
    // Both slices write to the same path on purpose, because that is what triggers
    // it: libslic3r skips the export when its step is still done and a file is
    // already sitting there, and the app slices to one fixed filename every time.
    if (failures == 0) {
        sp_engine *probe = sp_engine_create(fixtures.c_str(), work.c_str());
        if (probe == nullptr) {
            failures += fail("gate14", "could not create an engine");
        } else {
            const std::string profile = fixtures + "/model.3mf";
            const std::string mesh = fixtures + "/model-shapr3d.3mf";
            const std::string path = work + "/twice.gcode";

            if (sp_load_config(probe, profile.c_str()) != SP_OK ||
                sp_load_model(probe, mesh.c_str()) != SP_OK ||
                sp_auto_orient(probe) != SP_OK || sp_arrange(probe) != SP_OK) {
                failures += fail("gate14", std::string("setup: ") + sp_last_error(probe));
            } else if (sp_set_overrides(probe, kAppOverrides) != SP_OK ||
                       sp_slice(probe, path.c_str(), nullptr, nullptr) != SP_OK) {
                failures += fail("gate14", std::string("first slice: ") + sp_last_error(probe));
            } else {
                const std::string first_stats = sp_slice_stats_json(probe);
                const size_t first_segments = sp_toolpath_segment_count(probe);
                const std::string first_gcode = read_file(path);

                if (sp_set_overrides(probe, kAppOverrides) != SP_OK ||
                    sp_slice(probe, path.c_str(), nullptr, nullptr) != SP_OK) {
                    failures += fail("gate14", std::string("second slice: ") + sp_last_error(probe));
                } else {
                    const std::string second_stats = sp_slice_stats_json(probe);
                    if (second_stats != first_stats)
                        failures += fail("gate14", "statistics changed on an unchanged re-slice:\n"
                                                       "  first  " + first_stats + "\n"
                                                       "  second " + second_stats);
                    if (failures == 0 && sp_toolpath_segment_count(probe) != first_segments)
                        failures += fail("gate14", "toolpath went from " +
                                                       std::to_string(first_segments) + " segments to " +
                                                       std::to_string(sp_toolpath_segment_count(probe)));
                    // Commands rather than bytes: the header carries the time of
                    // day, which differs between two slices seconds apart.
                    if (failures == 0 && commands_of(read_file(path)) != commands_of(first_gcode))
                        failures += fail("gate14", "the G-code itself differs between identical slices");
                }
                if (failures == 0)
                    reported("gate14"), std::printf(
                        "gate14 re-slice: identical stats and %zu toolpath segments both times\n",
                        first_segments);
            }
            sp_engine_destroy(probe);
        }
    }

    // Gate 15: the per-segment description a layer view is built from. The
    // coordinates alone only draw centre lines; these say what each line is, which
    // layer it belongs to and how much material it lays down, and a view that
    // colours or scrubs by them is wrong in a way that looks plausible if any of
    // it is misaligned with the coordinate buffer.
    if (failures == 0) {
        sp_engine *probe = sp_engine_create(fixtures.c_str(), work.c_str());
        if (probe == nullptr) {
            failures += fail("gate15", "could not create an engine");
        } else {
            const std::string profile = fixtures + "/model.3mf";
            const std::string mesh = fixtures + "/model-shapr3d.3mf";
            const std::string path = work + "/segments.gcode";

            if (sp_load_config(probe, profile.c_str()) != SP_OK ||
                sp_load_model(probe, mesh.c_str()) != SP_OK ||
                sp_auto_orient(probe) != SP_OK || sp_arrange(probe) != SP_OK ||
                sp_slice(probe, path.c_str(), nullptr, nullptr) != SP_OK) {
                failures += fail("gate15", std::string("setup: ") + sp_last_error(probe));
            } else {
                const size_t count = sp_toolpath_segment_count(probe);
                const unsigned char *roles = sp_toolpath_roles(probe);
                const unsigned *layers = sp_toolpath_layers(probe);
                const float *widths = sp_toolpath_widths(probe);
                const float *heights = sp_toolpath_heights(probe);
                const size_t layer_count = sp_toolpath_layer_count(probe);

                if (count == 0 || roles == nullptr || layers == nullptr ||
                    widths == nullptr || heights == nullptr) {
                    failures += fail("gate15", "a slice produced no per-segment description");
                } else {
                    // Layers must be non-decreasing and cover every index, which is
                    // what lets a layer range be a contiguous slice of the buffer —
                    // and is the check that catches an array misaligned against the
                    // coordinates, since the ordering would no longer hold.
                    unsigned previous = 0;
                    unsigned highest = 0;
                    for (size_t i = 0; i < count && failures == 0; ++i) {
                        if (layers[i] < previous)
                            failures += fail("gate15", "layer index falls from " +
                                                           std::to_string(previous) + " to " +
                                                           std::to_string(layers[i]) +
                                                           " at segment " + std::to_string(i));
                        previous = layers[i];
                        highest = std::max(highest, layers[i]);
                    }
                    if (failures == 0 && size_t(highest) + 1 != layer_count)
                        failures += fail("gate15", "layers run to " + std::to_string(highest) +
                                                       " but the count says " +
                                                       std::to_string(layer_count));

                    // The same number the statistics report, from a different path
                    // through the moves: they should not be able to disagree.
                    const auto reported_layers =
                        size_t(number_after(sp_slice_stats_json(probe), "\"layer_count\":"));
                    if (failures == 0 && reported_layers != layer_count)
                        failures += fail("gate15", "toolpath has " + std::to_string(layer_count) +
                                                       " layers, statistics say " +
                                                       std::to_string(reported_layers));

                    // Roles are checked against the ";TYPE:" comments in the
                    // G-code we just wrote, rather than against a list written
                    // here: that is the same slice described by a different part
                    // of the engine, so a mapping that quietly collapses or
                    // renames a role disagrees with it.
                    std::map<std::string, unsigned char> expected_for_type = {
                        {"Outer wall", SP_ROLE_OUTER_WALL},
                        {"Overhang wall", SP_ROLE_OUTER_WALL},
                        {"Inner wall", SP_ROLE_INNER_WALL},
                        {"Sparse infill", SP_ROLE_INFILL},
                        {"Internal solid infill", SP_ROLE_SOLID_INFILL},
                        {"Top surface", SP_ROLE_SOLID_INFILL},
                        {"Bottom surface", SP_ROLE_SOLID_INFILL},
                        {"Ironing", SP_ROLE_SOLID_INFILL},
                        {"Bridge", SP_ROLE_BRIDGE},
                        {"Internal Bridge", SP_ROLE_BRIDGE},
                        {"Support", SP_ROLE_SUPPORT},
                        {"Support interface", SP_ROLE_SUPPORT},
                        {"Skirt", SP_ROLE_SKIRT_BRIM},
                        {"Brim", SP_ROLE_SKIRT_BRIM},
                    };

                    std::set<unsigned char> allowed;
                    std::set<std::string> unmapped_types;
                    for (const std::string &line : lines_of(read_file(path))) {
                        if (line.rfind(";TYPE:", 0) != 0)
                            continue;
                        const std::string type = trim(line.substr(6));
                        const auto known = expected_for_type.find(type);
                        if (known != expected_for_type.end())
                            allowed.insert(known->second);
                        else
                            unmapped_types.insert(type);   // gap fill, custom, …
                    }
                    // Anything the table does not name is deliberately OTHER, so
                    // its presence in the G-code licenses OTHER in the buffer.
                    if (!unmapped_types.empty())
                        allowed.insert(SP_ROLE_OTHER);

                    std::map<unsigned char, size_t> role_counts;
                    for (size_t i = 0; i < count; ++i)
                        role_counts[roles[i]]++;

                    for (const auto &[role, times] : role_counts) {
                        if (failures == 0 && allowed.count(role) == 0)
                            failures += fail("gate15", "role " + std::to_string(int(role)) +
                                                           " appears " + std::to_string(times) +
                                                           " times but nothing in the G-code is "
                                                           "that kind of extrusion");
                    }
                    // The walls and both infills are what this model is made of; a
                    // mapping that lost one of them would still satisfy the check
                    // above, since a smaller set is a subset.
                    for (unsigned char role : {SP_ROLE_OUTER_WALL, SP_ROLE_INNER_WALL,
                                               SP_ROLE_INFILL, SP_ROLE_SOLID_INFILL}) {
                        if (failures == 0 && role_counts.count(role) == 0)
                            failures += fail("gate15", "no segments of role " +
                                                           std::to_string(int(role)) +
                                                           ", which this print is made of");
                    }

                    // Width and height are what let a view draw the object rather
                    // than its centre lines, so zero or nonsense is worse than
                    // useless — it would render as nothing at all.
                    //
                    // Bounded only for the extrusions the slicer planned. The
                    // start G-code's prime line is erCustom, and its dimensions
                    // are whatever the processor can infer from the E and XY it
                    // was handed — 3.2mm wide here — which says nothing about
                    // whether these fields are being filled in correctly.
                    float widest = 0.0f, narrowest = 1e9f;
                    std::map<int, size_t> height_counts;   // keyed by micrometres
                    for (size_t i = 0; i < count && failures == 0; ++i) {
                        if (!(widths[i] > 0.0f) || !(heights[i] > 0.0f)) {
                            failures += fail("gate15", "segment " + std::to_string(i) +
                                                           " has no extrusion size: " +
                                                           std::to_string(widths[i]) + " by " +
                                                           std::to_string(heights[i]));
                            continue;
                        }
                        if (roles[i] == SP_ROLE_OTHER)
                            continue;

                        if (!(widths[i] > 0.1f && widths[i] < 1.5f))
                            failures += fail("gate15", "segment " + std::to_string(i) +
                                                           " has width " +
                                                           std::to_string(widths[i]));
                        else if (!(heights[i] > 0.02f && heights[i] < 1.0f))
                            failures += fail("gate15", "segment " + std::to_string(i) +
                                                           " has height " +
                                                           std::to_string(heights[i]));
                        widest = std::max(widest, widths[i]);
                        narrowest = std::min(narrowest, widths[i]);
                        height_counts[int(heights[i] * 1000.0f + 0.5f)]++;
                    }

                    // The commonest height should be the profile's layer height —
                    // an independent oracle, since it comes from the configuration
                    // rather than from the same buffer being checked.
                    const auto config = parse_config(sp_resolved_config_text(probe), false);
                    const auto layer_height_at = config.find("layer_height");
                    if (failures == 0 && layer_height_at == config.end()) {
                        failures += fail("gate15", "the profile has no layer_height to check against");
                    } else if (failures == 0) {
                        const double configured = std::strtod(layer_height_at->second.c_str(), nullptr);
                        const auto commonest =
                            std::max_element(height_counts.begin(), height_counts.end(),
                                             [](const auto &a, const auto &b) {
                                                 return a.second < b.second;
                                             });
                        const double typical = commonest->first / 1000.0;
                        if (std::fabs(typical - configured) / configured > 0.15)
                            failures += fail("gate15", "most segments are " +
                                                           std::to_string(typical) +
                                                           "mm tall, but the profile asks for " +
                                                           std::to_string(configured));
                    }

                    // A constant would satisfy every bound above; the first layer
                    // and the solid infill are deliberately not the same width as
                    // the walls, so a single value means the field is not real.
                    if (failures == 0 && widest - narrowest < 0.01f)
                        failures += fail("gate15", "every segment is " + std::to_string(widest) +
                                                       "mm wide, which no real slice is");

                    if (failures == 0)
                        reported("gate15"), std::printf(
                            "gate15 segments: %zu across %zu layers, %zu roles, widths %.2f-%.2fmm\n",
                            count, layer_count, role_counts.size(), narrowest, widest);
                }
            }
            sp_engine_destroy(probe);
        }
    }

    sp_engine_destroy(engine);

    constexpr int kExpectedGates = 15;
    if (failures == 0 && gates_reported != kExpectedGates)
        failures += fail("suite", "only " + std::to_string(gates_reported) + " of " +
                                      std::to_string(kExpectedGates) +
                                      " gates reported — has one been removed or skipped?");

    if (failures == 0)
        std::puts("PASS");
    return failures == 0 ? 0 : 1;
}
