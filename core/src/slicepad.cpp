#include "slicepad.h"
#include "thumbnail.hpp"

#include <libslic3r/libslic3r.h>
#include <libslic3r/Config.hpp>
#include <libslic3r/Model.hpp>
#include <libslic3r/ModelArrange.hpp>
#include <libslic3r/Orient.hpp>
#include <libslic3r/Print.hpp>
#include <libslic3r/PrintConfig.hpp>
#include <libslic3r/Utils.hpp>
#include <libslic3r/miniz_extension.hpp>
#include <libslic3r/GCode/GCodeProcessor.hpp>
#include <libslic3r/GCode/ThumbnailData.hpp>

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem.hpp>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace Slic3r;

struct sp_engine {
    // One Print for the engine's lifetime, applied to repeatedly. That is how the
    // desktop drives it — Plater holds a Slic3r::Print and calls apply() — and the
    // invalidation machinery exists for exactly that. Constructing a fresh Print
    // per slice is not how the library expects to be used.
    Print print;
    DynamicPrintConfig config;   // the loaded profile, already fully resolved
    DynamicPrintConfig overrides;
    Model model;
    std::string config_version;
    std::string last_error;
    std::string stats_json = "{}";
    std::string config_text;
    std::vector<float> toolpath;   // packed x1,y1,z1,x2,y2,z2 per segment
    std::vector<float> mesh;       // packed 9 floats per triangle, bed coords
    std::vector<float> bed;        // packed x,y per printable-area point
    int repaired_errors = 0;
    bool config_loaded = false;
    bool model_loaded = false;
};

namespace {

bool extract_project_config(const std::string &path, std::string &out);

// libslic3r signals failure by throwing, and an exception crossing the C ABI is
// undefined behaviour, so every entry point funnels through here.
template <typename Fn> sp_result guard(sp_engine *engine, Fn &&fn)
{
    if (engine == nullptr)
        return SP_ERR_STATE;
    engine->last_error.clear();
    try {
        return fn();
    } catch (const std::exception &e) {
        engine->last_error = e.what();
        return SP_ERR_SLICE;
    } catch (...) {
        engine->last_error = "unknown error";
        return SP_ERR_SLICE;
    }
}

// Pulls Metadata/project_settings.config out of a project 3MF. Orca writes the
// fully merged printer, process and filament settings there, which is why a
// saved project can act as a self-contained profile.
bool extract_project_config(const std::string &path, std::string &out)
{
    mz_zip_archive zip{};
    if (!open_zip_reader(&zip, path))
        return false;

    bool found = false;
    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    for (mz_uint i = 0; i < count && !found; ++i) {
        mz_zip_archive_file_stat stat;
        if (!mz_zip_reader_file_stat(&zip, i, &stat))
            continue;
        if (std::string(stat.m_filename) != "Metadata/project_settings.config")
            continue;
        out.assign(size_t(stat.m_uncomp_size), '\0');
        found = mz_zip_reader_extract_to_mem(&zip, i, out.data(), out.size(), 0);
    }
    close_zip_reader(&zip);
    return found;
}

// Extracts what a UI needs to show after a slice. Every figure here is checked
// against the corresponding line Orca writes into its own G-code, so the values
// agree with what the desktop reports for the same job.
// The extruding moves as line segments, which is all a stacked-layer view needs.
// A segment runs from the previous move's position to this one, so only moves
// that actually deposit material contribute.
// The loaded model's triangles in bed coordinates. Object and instance
// transforms are baked in so a view can draw the buffer without knowing
// anything about the scene graph.
// The GUI blocks slicing when an object leaves the build volume, but it does so
// in the GL canvas (check_volumes_outside_state), which a headless build cannot
// reuse. libslic3r's own Print::validate does not cover it, so without this the
// engine emits G-code with coordinates outside the bed.
std::string outside_build_volume(const Model &model, const std::vector<float> &bed,
                                 double printable_height)
{
    if (bed.size() < 4)
        return {};
    float lo_x = bed[0], hi_x = bed[0], lo_y = bed[1], hi_y = bed[1];
    for (size_t i = 0; i + 1 < bed.size(); i += 2) {
        lo_x = std::min(lo_x, bed[i]);   hi_x = std::max(hi_x, bed[i]);
        lo_y = std::min(lo_y, bed[i + 1]); hi_y = std::max(hi_y, bed[i + 1]);
    }

    for (const ModelObject *object : model.objects) {
        if (object->instances.empty())
            continue;
        const BoundingBoxf3 box = object->instance_bounding_box(0);
        const double slack = 0.001; // ignore floating-point dust at the edges
        if (box.min.x() < lo_x - slack || box.max.x() > hi_x + slack ||
            box.min.y() < lo_y - slack || box.max.y() > hi_y + slack ||
            (printable_height > 0.0 && box.max.z() > printable_height + slack)) {
            char detail[256];
            std::snprintf(detail, sizeof(detail),
                          "%s is outside the printable area: it spans x %.1f..%.1f, "
                          "y %.1f..%.1f, z up to %.1f, but the bed is x %.1f..%.1f, "
                          "y %.1f..%.1f with %.0fmm of height",
                          object->name.empty() ? "the model" : object->name.c_str(),
                          box.min.x(), box.max.x(), box.min.y(), box.max.y(), box.max.z(),
                          double(lo_x), double(hi_x), double(lo_y), double(hi_y),
                          printable_height);
            return detail;
        }
    }
    return {};
}

std::vector<float> extract_mesh(const Model &model)
{
    std::vector<float> vertices;
    for (const ModelObject *object : model.objects) {
        if (object->instances.empty())
            continue;
        const Transform3d instance_matrix = object->instances.front()->get_matrix();
        for (const ModelVolume *volume : object->volumes) {
            if (!volume->is_model_part())
                continue;
            const Transform3d matrix = instance_matrix * volume->get_matrix();
            const indexed_triangle_set &its = volume->mesh().its;
            vertices.reserve(vertices.size() + its.indices.size() * 9);
            for (const Vec3i32 &face : its.indices) {
                for (int corner = 0; corner < 3; ++corner) {
                    const Vec3d point =
                        matrix * its.vertices[size_t(face[corner])].cast<double>();
                    vertices.push_back(float(point.x()));
                    vertices.push_back(float(point.y()));
                    vertices.push_back(float(point.z()));
                }
            }
        }
    }
    return vertices;
}

std::vector<float> extract_bed(const DynamicPrintConfig &config)
{
    std::vector<float> points;
    if (const auto *area = config.opt<ConfigOptionPoints>("printable_area")) {
        for (const Vec2d &point : area->values) {
            points.push_back(float(point.x()));
            points.push_back(float(point.y()));
        }
    }
    return points;
}

std::vector<float> extract_toolpath(const GCodeProcessorResult &result)
{
    std::vector<float> segments;
    bool have_previous = false;
    Vec3f previous = Vec3f::Zero();

    for (const auto &move : result.moves) {
        if (move.type == EMoveType::Extrude && have_previous) {
            segments.insert(segments.end(), {previous.x(), previous.y(), previous.z(),
                                             move.position.x(), move.position.y(),
                                             move.position.z()});
        }
        previous = move.position;
        have_previous = true;
    }
    return segments;
}

std::string summarise(const Print &print, const GCodeProcessorResult &result,
                      const DynamicPrintConfig &config)
{
    const auto &stats = result.print_statistics;

    double volume_mm3 = 0.0;
    for (const auto &[extruder, volume] : stats.total_volumes_per_extruder)
        volume_mm3 += volume;

    auto first_float = [&](const char *key, double fallback) {
        const auto *opt = config.opt<ConfigOptionFloats>(key);
        return (opt != nullptr && !opt->values.empty()) ? opt->values.front() : fallback;
    };
    const double diameter = first_float("filament_diameter", 1.75);
    const double density = first_float("filament_density", 1.24);

    // Orca reports filament as a length of stock filament, not as extruded
    // volume, so convert back through the filament's cross-section.
    const double radius = diameter / 2.0;
    const double area = M_PI * radius * radius;
    const double length_mm = area > 0.0 ? volume_mm3 / area : 0.0;
    // Density is g/cm3 against a volume in mm3.
    const double grams = volume_mm3 * density / 1000.0;

    // Orca's "total layer number" counts layer-change tags in the emitted
    // G-code, which is not the same as the sliced layer count: PrintObject
    // reports 65 where the G-code shows 64. Take it from the moves so the figure
    // matches what the desktop displays.
    unsigned int highest_layer_id = 0;
    bool saw_layer = false;
    for (const auto &move : result.moves) {
        highest_layer_id = std::max(highest_layer_id, move.layer_id);
        saw_layer = true;
    }
    const unsigned int layers = saw_layer ? highest_layer_id + 1 : 0; // ids are 0-based

    const double seconds =
        stats.modes[static_cast<size_t>(PrintEstimatedStatistics::ETimeMode::Normal)].time;

    nlohmann::json out;
    out["estimated_seconds"] = seconds;
    out["filament_mm"] = length_mm;
    out["filament_grams"] = grams;
    out["filament_mm3"] = volume_mm3;
    out["layer_count"] = layers;
    out["travel_mm"] = stats.total_travel_distance;
    out["object_count"] = print.objects().size();
    return out.dump();
}

sp_result require_file(sp_engine *engine, const char *path)
{
    if (path == nullptr || *path == '\0') {
        engine->last_error = "no path given";
        return SP_ERR_IO;
    }
    if (!boost::filesystem::exists(path)) {
        engine->last_error = std::string("no such file: ") + path;
        return SP_ERR_IO;
    }
    return SP_OK;
}

// The profile plus overrides, which is what actually gets sliced.
DynamicPrintConfig effective_config(const sp_engine *engine)
{
    DynamicPrintConfig config = engine->config;
    config.apply(engine->overrides, true);
    return config;
}

} // namespace

extern "C" {

sp_engine *sp_engine_create(const char *resources_dir, const char *data_dir)
{
    if (resources_dir == nullptr || data_dir == nullptr)
        return nullptr;
    try {
        auto engine = std::make_unique<sp_engine>();
        // Quiet by default: libslic3r's boost::log writes to stdout, which would
        // corrupt the config dump. SLICEPAD_LOG raises it for debugging.
        const char *log_level = std::getenv("SLICEPAD_LOG");
        set_logging_level(log_level ? unsigned(std::atoi(log_level)) : 0);
        set_resources_dir(resources_dir);
        set_data_dir(data_dir);
        return engine.release();
    } catch (const std::exception &) {
        return nullptr;
    }
}

void sp_engine_destroy(sp_engine *engine) { delete engine; }

const char *sp_last_error(const sp_engine *engine)
{
    return engine ? engine->last_error.c_str() : "engine is null";
}

sp_result sp_load_config(sp_engine *engine, const char *path)
{
    return guard(engine, [&]() -> sp_result {
        if (const sp_result bad = require_file(engine, path); bad != SP_OK)
            return bad;

        // The config is taken straight from the archive rather than through
        // Model::read_from_file, which rejects a project containing no objects
        // ("the supplied file couldn't be read because it's empty"). A profile
        // carrier saved from an empty plate is exactly what we want to support,
        // and its geometry would be discarded anyway.
        std::string extracted;
        if (!extract_project_config(path, extracted)) {
            engine->last_error =
                "no configuration in this file — is it a project saved by Orca "
                "(File > Save Project As) rather than a plain mesh export?";
            return SP_ERR_UNRESOLVED;
        }

        // Written through a temporary so that load_from_json applies the same key
        // migration and legacy-name handling the desktop uses.
        const boost::filesystem::path temp =
            boost::filesystem::path(data_dir()) / "slicepad-profile.json";
        {
            std::ofstream out(temp.string(), std::ios::binary | std::ios::trunc);
            out << extracted;
        }

        DynamicPrintConfig config;
        std::map<std::string, std::string> key_values;
        std::string reason;
        config.load_from_json(temp.string(), ForwardCompatibilitySubstitutionRule::EnableSilent,
                              key_values, reason);
        boost::filesystem::remove(temp);

        if (!reason.empty()) {
            engine->last_error = "cannot read the project configuration: " + reason;
            return SP_ERR_PARSE;
        }
        if (config.keys().empty()) {
            engine->last_error = "the project configuration is empty";
            return SP_ERR_UNRESOLVED;
        }

        engine->config = std::move(config);
        engine->config_loaded = true;
        engine->bed = extract_bed(engine->config);

        // Read the version from the raw project JSON rather than the parsed
        // config: "version" is not a PrintConfigDef key, so load_from_json drops
        // it and looking it up there always yielded nothing.
        engine->config_version.clear();
        try {
            const auto parsed = nlohmann::json::parse(extracted);
            engine->config_version = parsed.value("version", std::string());
        } catch (const std::exception &) {
        }
        return SP_OK;
    });
}

const char *sp_config_source_version(const sp_engine *engine)
{
    return engine ? engine->config_version.c_str() : "";
}

sp_result sp_load_model(sp_engine *engine, const char *path)
{
    return guard(engine, [&]() -> sp_result {
        if (const sp_result bad = require_file(engine, path); bad != SP_OK)
            return bad;
        // LoadModel is a distinct flag: without it the 3MF reader parses the
        // archive but loads no geometry, and read_from_file then rejects the
        // result as an empty file.
        engine->model = Model::read_from_file(path, nullptr, nullptr,
                                              LoadStrategy::AddDefaultInstances |
                                                  LoadStrategy::LoadModel);

        // Placement is the GUI's job upstream, so a headless consumer inherits
        // it: Plater drops every loaded object onto the bed, and centres raw
        // imports while leaving a project's own placement alone. Without this a
        // CAD export arrives at the origin — often with negative coordinates —
        // and slices into G-code that drives the toolhead off the bed.
        std::string project_config;
        const bool is_project = extract_project_config(path, project_config);
        for (ModelObject *object : engine->model.objects)
            if (!object->instances.empty())
                object->ensure_on_bed(is_project);

        // Orca's Plater also centres bare mesh imports here, and deliberately not
        // done yet: doing so makes libslic3r emit INT64_MIN coordinates for this
        // model, i.e. G-code that would drive the toolhead off the bed. Dropping
        // alone is clean, and centring alone or after dropping is not — the
        // manifestation shifts with unrelated changes, so something upstream is
        // reading uninitialised state that ensure_on_bed happens to normalise.
        //
        // Until that is understood, an unplaced import is refused by the build
        // volume check below rather than silently mis-sliced. Real placement
        // belongs with libslic3r's own arrange and an orientation control anyway:
        // a CAD export is rarely in a printable orientation, and sp_set_transform
        // only rotates about Z.

        engine->repaired_errors = 0;
        for (const ModelObject *object : engine->model.objects)
            engine->repaired_errors += object->get_repaired_errors_count();

        engine->model_loaded = true;
        engine->mesh = extract_mesh(engine->model);
        return SP_OK;
    });
}

int sp_object_count(const sp_engine *engine)
{
    return engine ? int(engine->model.objects.size()) : 0;
}

sp_result sp_set_transform(sp_engine *engine, int object_index, double scale,
                           double rotate_x_deg, double rotate_y_deg, double rotate_z_deg,
                           double translate_x, double translate_y)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded || object_index < 0 ||
            size_t(object_index) >= engine->model.objects.size()) {
            engine->last_error = "no such object";
            return SP_ERR_STATE;
        }
        if (scale <= 0.0) {
            engine->last_error = "scale must be positive";
            return SP_ERR_STATE;
        }
        ModelObject *object = engine->model.objects[size_t(object_index)];
        if (object->instances.empty()) {
            engine->last_error = "object has no instances";
            return SP_ERR_STATE;
        }

        const double to_radians = M_PI / 180.0;
        ModelInstance *instance = object->instances.front();
        instance->set_scaling_factor(Vec3d(scale, scale, scale));
        instance->set_rotation(Vec3d(rotate_x_deg * to_radians, rotate_y_deg * to_radians,
                                     rotate_z_deg * to_radians));
        instance->set_offset(Vec3d(translate_x, translate_y, instance->get_offset().z()));
        object->invalidate_bounding_box();

        // Rotating about X or Y moves the object through the bed, so put it back
        // down — the same thing the desktop does after any transform.
        object->ensure_on_bed();
        engine->mesh = extract_mesh(engine->model);
        return SP_OK;
    });
}

sp_result sp_object_transform(sp_engine *engine, int object_index, double *out_values)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded || object_index < 0 ||
            size_t(object_index) >= engine->model.objects.size()) {
            engine->last_error = "no such object";
            return SP_ERR_STATE;
        }
        if (out_values == nullptr) {
            engine->last_error = "no output buffer";
            return SP_ERR_STATE;
        }
        const ModelObject *object = engine->model.objects[size_t(object_index)];
        if (object->instances.empty()) {
            engine->last_error = "object has no instances";
            return SP_ERR_STATE;
        }

        const double to_degrees = 180.0 / M_PI;
        const ModelInstance *instance = object->instances.front();
        const Vec3d rotation = instance->get_rotation();
        const Vec3d offset = instance->get_offset();
        out_values[0] = instance->get_scaling_factor().x();
        out_values[1] = rotation.x() * to_degrees;
        out_values[2] = rotation.y() * to_degrees;
        out_values[3] = rotation.z() * to_degrees;
        out_values[4] = offset.x();
        out_values[5] = offset.y();
        return SP_OK;
    });
}

sp_result sp_arrange(sp_engine *engine)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded) {
            engine->last_error = "no model loaded";
            return SP_ERR_STATE;
        }
        if (!engine->config_loaded) {
            engine->last_error = "no profile loaded, so the bed is unknown";
            return SP_ERR_STATE;
        }
        // libslic3r's own arrange, invoked the way the CLI does, rather than
        // shifting instances by hand.
        const Points bed = get_bed_shape(engine->config);
        arrangement::ArrangeParams params;
        // Its default progress callback writes to stdout, which would corrupt a
        // consumer's output. A no-op rather than nullptr: the caller invokes it
        // unconditionally.
        params.progressind = [](unsigned, std::string) {};
        arrange_objects(engine->model, bed, params);
        for (ModelObject *object : engine->model.objects)
            if (!object->instances.empty())
                object->ensure_on_bed();
        engine->mesh = extract_mesh(engine->model);
        return SP_OK;
    });
}

sp_result sp_place_nearest_face_down(sp_engine *engine, int object_index)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded || object_index < 0 ||
            size_t(object_index) >= engine->model.objects.size()) {
            engine->last_error = "no such object";
            return SP_ERR_STATE;
        }
        ModelObject *object = engine->model.objects[size_t(object_index)];
        if (object->instances.empty()) {
            engine->last_error = "object has no instances";
            return SP_ERR_STATE;
        }

        // The convex hull, because the faces worth standing a part on are the ones
        // on its outside — a pocket floor is flat and useless here. This is what
        // the desktop's place-on-face gizmo does; that code lives in the GUI, so
        // the approach is borrowed rather than the implementation.
        const TriangleMesh hull = object->raw_mesh().convex_hull_3d();
        const std::vector<Vec3f> normals = its_face_normals(hull.its);
        if (normals.empty()) {
            engine->last_error = "the model has no faces to stand on";
            return SP_ERR_STATE;
        }

        ModelInstance *instance = object->instances.front();
        const Transform3d rotation = instance->get_matrix_no_offset();

        // Candidate faces are grouped by normal and weighted by area, so a large
        // flat face beats a chip of one pointing a similar way. The desktop
        // discards anything under 5mm² for the same reason.
        struct Candidate { Vec3d normal; double area; };
        std::vector<Candidate> candidates;
        for (size_t i = 0; i < normals.size(); ++i) {
            const stl_triangle_vertex_indices &face = hull.its.indices[i];
            const Vec3f &a = hull.its.vertices[face(0)];
            const Vec3f &b = hull.its.vertices[face(1)];
            const Vec3f &c = hull.its.vertices[face(2)];
            const double area = 0.5 * double((b - a).cross(c - a).norm());
            const Vec3d normal = normals[i].cast<double>().normalized();

            auto same = std::find_if(candidates.begin(), candidates.end(),
                                     [&](const Candidate &existing) {
                                         return existing.normal.dot(normal) > 0.999;
                                     });
            if (same == candidates.end())
                candidates.push_back({normal, area});
            else
                same->area += area;
        }

        // Nearest to the way the part is already turned, not simply the largest:
        // this runs after someone has rotated it roughly into place, and the point
        // is to tidy that up rather than to overrule it. Area breaks ties between
        // faces pointing much the same way.
        const Vec3d down(0.0, 0.0, -1.0);
        const Candidate *best = nullptr;
        double best_score = -2.0;
        for (const Candidate &candidate : candidates) {
            if (candidate.area < 5.0)
                continue;
            const Vec3d world = (rotation * candidate.normal).normalized();
            const double score = world.dot(down) + 1e-6 * std::min(candidate.area, 1000.0);
            if (score > best_score) {
                best_score = score;
                best = &candidate;
            }
        }
        if (best == nullptr) {
            engine->last_error = "no face large enough to stand this on";
            return SP_ERR_STATE;
        }

        const Vec3d world = (rotation * best->normal).normalized();
        const Eigen::Quaterniond correction = Eigen::Quaterniond::FromTwoVectors(world, down);
        const Transform3d turned = Transform3d(correction.toRotationMatrix()) * rotation;
        instance->set_rotation(Geometry::extract_euler_angles(turned));

        object->invalidate_bounding_box();
        object->ensure_on_bed();
        engine->mesh = extract_mesh(engine->model);
        return SP_OK;
    });
}

sp_result sp_auto_orient(sp_engine *engine)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded) {
            engine->last_error = "no model loaded";
            return SP_ERR_STATE;
        }
        // A CAD export is rarely in a printable orientation. This is the same
        // algorithm the desktop's auto-orient uses.
        for (ModelObject *object : engine->model.objects)
            orientation::orient(object);
        for (ModelObject *object : engine->model.objects)
            if (!object->instances.empty())
                object->ensure_on_bed();
        engine->mesh = extract_mesh(engine->model);
        return SP_OK;
    });
}

sp_result sp_set_overrides(sp_engine *engine, const char *overrides_json)
{
    return guard(engine, [&]() -> sp_result {
        engine->overrides.clear();
        if (overrides_json == nullptr || *overrides_json == '\0')
            return SP_OK;

        nlohmann::json parsed;
        try {
            parsed = nlohmann::json::parse(overrides_json);
        } catch (const std::exception &e) {
            engine->last_error = std::string("override JSON is malformed: ") + e.what();
            return SP_ERR_PARSE;
        }
        if (!parsed.is_object()) {
            engine->last_error = "overrides must be a JSON object";
            return SP_ERR_PARSE;
        }

        for (const auto &[key, value] : parsed.items()) {
            if (print_config_def.get(key) == nullptr) {
                engine->last_error = "unknown config key: " + key;
                return SP_ERR_PARSE;
            }
            // Orca stores vector options as arrays of strings and scalars as
            // strings; joining with "," is how libslic3r deserialises vectors.
            std::string serialised;
            if (value.is_array()) {
                for (const auto &element : value) {
                    if (!serialised.empty())
                        serialised += ",";
                    serialised += element.is_string() ? element.get<std::string>() : element.dump();
                }
            } else {
                serialised = value.is_string() ? value.get<std::string>() : value.dump();
            }
            ConfigSubstitutionContext substitutions{ForwardCompatibilitySubstitutionRule::Disable};
            if (!engine->overrides.set_deserialize_nothrow(key, serialised, substitutions)) {
                engine->last_error = "cannot parse value for " + key + ": " + serialised;
                return SP_ERR_PARSE;
            }
        }
        return SP_OK;
    });
}

sp_result sp_slice(sp_engine *engine, const char *out_gcode_path,
                   sp_progress_fn progress, void *user)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->config_loaded) {
            engine->last_error = "no profile loaded";
            return SP_ERR_STATE;
        }
        if (!engine->model_loaded) {
            engine->last_error = "no model loaded";
            return SP_ERR_STATE;
        }
        if (out_gcode_path == nullptr)
            return SP_ERR_IO;
        boost::system::error_code ignored;

        const DynamicPrintConfig config = effective_config(engine);

        if (const std::string problem = outside_build_volume(
                engine->model, engine->bed,
                config.opt_float("printable_height"));
            !problem.empty()) {
            engine->last_error = problem;
            return SP_ERR_SLICE;
        }

        Print &print = engine->print;
        // The Print outlives the slice now, and cancelling leaves it flagged. Clear
        // it or every subsequent slice fails immediately with "cancelled" — which
        // the previous fresh-Print-per-slice arrangement hid.
        print.restart();
        print.apply(engine->model, config);

        // Print::m_isBBLPrinter has no initialiser and is never assigned inside
        // libslic3r — the GUI writes it through the is_BBL_printer() reference.
        // Leaving it alone means indeterminate memory selects the G-code comment
        // dialect: GCodeProcessor::reserved_tag() switches on it, emitting Bambu
        // tags ("; CHANGE_LAYER") instead of the PrusaSlicer-compatible ones
        // (";LAYER_CHANGE") that Klipper's exclude_object and the web UIs read.
        const auto *printer_model = config.opt<ConfigOptionString>("printer_model");
        print.is_BBL_printer() =
            printer_model != nullptr && boost::starts_with(printer_model->value, "Bambu Lab");

        // validate() reports advisories through its out-param and real problems
        // through the return value, distinguished by is_warning.
        const StringObjectException problem = print.validate();
        if (!problem.string.empty() && !problem.is_warning) {
            engine->last_error = problem.string;
            return SP_ERR_SLICE;
        }

        // Always replace the callback, including with a no-op: it lives on the
        // Print, so passing nullptr after a cancelling slice would otherwise leave
        // the previous one attached and cancel this one too.
        if (progress != nullptr) {
            // The callback's return value is how a caller cancels. libslic3r polls
            // its cancel status between steps and unwinds with CanceledException,
            // which has to be caught here: the guard around this lambda would
            // otherwise report it as an ordinary slicing failure.
            print.set_status_callback([progress, user, &print](const PrintBase::SlicingStatus &status) {
                if (progress(int(status.percent), status.text.c_str(), user) != 0)
                    print.cancel();
            });
        } else {
            print.set_status_callback([](const PrintBase::SlicingStatus &) {});
        }

        GCodeProcessorResult result;
        try {
            print.process();

            // GCode::do_export returns immediately, without touching `result`, when
            // its step is still done from an earlier slice and a file already sits
            // at the path. Slicing twice without changing anything is exactly that,
            // and the app writes to one filename every time — so the second slice
            // reported no statistics and no toolpath for G-code that was perfectly
            // good, and only moving the object appeared to fix it.
            //
            // sp_slice promises statistics and a toolpath on every call, so the
            // export always runs. process() above still skips the expensive steps
            // it can, which is where the time actually goes.
            print.set_gcode_file_invalidated();
            // Mainsail and Fluidd show whatever the G-code carries, and libslic3r
            // does the PNG encoding and embedding — the callback only has to
            // return pixels. It renders the mesh rather than the toolpath because
            // it runs during export, before the moves exist.
            const std::vector<float> &mesh = engine->mesh;
            print.export_gcode(out_gcode_path, &result,
                               [&mesh](const ThumbnailsParams &params) {
                                   ThumbnailsList thumbnails;
                                   for (const Vec2d &size : params.sizes) {
                                       ThumbnailData data;
                                       data.set(static_cast<unsigned>(size.x()),
                                                static_cast<unsigned>(size.y()));
                                       if (slicepad::render_mesh(mesh, data.width, data.height,
                                                                 params.transparent_background,
                                                                 data.pixels))
                                           thumbnails.emplace_back(std::move(data));
                                   }
                                   return thumbnails;
                               });
        } catch (const CanceledException &) {
            boost::filesystem::remove(out_gcode_path, ignored);
            engine->last_error = "cancelled";
            return SP_ERR_CANCELLED;
        }

        engine->stats_json = summarise(print, result, config);
        engine->toolpath = extract_toolpath(result);
        return SP_OK;
    });
}

const char *sp_slice_stats_json(const sp_engine *engine)
{
    return engine ? engine->stats_json.c_str() : "{}";
}

const char *sp_resolved_config_text(sp_engine *engine)
{
    if (engine == nullptr)
        return "";
    engine->config_text.clear();
    try {
        const DynamicPrintConfig config = effective_config(engine);
        // keys() is sorted, which keeps the output diffable.
        for (const std::string &key : config.keys())
            engine->config_text += key + " = " + config.opt_serialize(key) + "\n";
    } catch (const std::exception &e) {
        engine->last_error = e.what();
        engine->config_text.clear();
    }
    return engine->config_text.c_str();
}

int sp_model_repaired_errors(const sp_engine *engine)
{
    return engine ? engine->repaired_errors : 0;
}

size_t sp_mesh_triangle_count(const sp_engine *engine)
{
    return engine ? engine->mesh.size() / 9 : 0;
}

const float *sp_mesh_vertices(const sp_engine *engine)
{
    return (engine != nullptr && !engine->mesh.empty()) ? engine->mesh.data() : nullptr;
}

size_t sp_bed_point_count(const sp_engine *engine)
{
    return engine ? engine->bed.size() / 2 : 0;
}

const float *sp_bed_points(const sp_engine *engine)
{
    return (engine != nullptr && !engine->bed.empty()) ? engine->bed.data() : nullptr;
}

sp_result sp_object_bounds(sp_engine *engine, int object_index, float *out_min_max)
{
    return guard(engine, [&]() -> sp_result {
        if (out_min_max == nullptr)
            return SP_ERR_STATE;
        if (!engine->model_loaded || object_index < 0 ||
            size_t(object_index) >= engine->model.objects.size()) {
            engine->last_error = "no such object";
            return SP_ERR_STATE;
        }
        const BoundingBoxf3 box =
            engine->model.objects[size_t(object_index)]->instance_bounding_box(0);
        out_min_max[0] = float(box.min.x());
        out_min_max[1] = float(box.min.y());
        out_min_max[2] = float(box.min.z());
        out_min_max[3] = float(box.max.x());
        out_min_max[4] = float(box.max.y());
        out_min_max[5] = float(box.max.z());
        return SP_OK;
    });
}

size_t sp_toolpath_segment_count(const sp_engine *engine)
{
    return engine ? engine->toolpath.size() / 6 : 0;
}

const float *sp_toolpath_segments(const sp_engine *engine)
{
    return (engine != nullptr && !engine->toolpath.empty()) ? engine->toolpath.data() : nullptr;
}

const char *sp_engine_version(void) { return SoftFever_VERSION; }

const char *sp_engine_config_version(void) { return SLIC3R_VERSION; }

} // extern "C"
