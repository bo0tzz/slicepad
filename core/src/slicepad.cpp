#include "slicepad.h"

#include <libslic3r/libslic3r.h>
#include <libslic3r/AppConfig.hpp>
#include <libslic3r/Config.hpp>
#include <libslic3r/Model.hpp>
#include <libslic3r/Preset.hpp>
#include <libslic3r/PresetBundle.hpp>
#include <libslic3r/Print.hpp>
#include <libslic3r/Utils.hpp>
#include <libslic3r/miniz_extension.hpp>
#include <libslic3r/GCode/GCodeProcessor.hpp>

#include <boost/filesystem.hpp>
#include <boost/log/trivial.hpp>
#include <nlohmann/json.hpp>

#include <cstdlib>
#include <exception>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

using namespace Slic3r;

struct sp_engine {
    AppConfig app_config;
    PresetBundle presets;
    Model model;
    DynamicPrintConfig overrides;
    std::string resources_dir;
    std::string last_error;
    std::string stats_json;
    std::string config_text;
    std::string sel_printer;
    std::string sel_process;
    std::string sel_filament;
    bool model_loaded = false;
};

namespace {

// PresetBundle only surfaces system presets for printer models marked installed
// in AppConfig, and vendor profiles are indexed by resources/profiles/<Vendor>.json
// whose machine_model_list names the models it provides. So a printer model has
// to be mapped back to its vendor before any `inherits` chain resolves.
bool find_vendor_for_model(const std::string &resources_dir,
                           const std::string &printer_model,
                           std::string &vendor_out,
                           std::set<std::string> &variants_out)
{
    namespace fs = boost::filesystem;
    const fs::path profiles = fs::path(resources_dir) / "profiles";
    if (!fs::is_directory(profiles))
        return false;

    for (fs::directory_iterator it(profiles), end; it != end; ++it) {
        if (!fs::is_regular_file(it->status()) || it->path().extension() != ".json")
            continue;

        nlohmann::json index;
        try {
            std::ifstream ifs(it->path().string());
            ifs >> index;
        } catch (const std::exception &) {
            continue; // blacklist.json and friends are not vendor indexes
        }
        if (!index.contains("machine_model_list"))
            continue;

        for (const auto &entry : index["machine_model_list"]) {
            if (!entry.contains("name") || entry["name"] != printer_model)
                continue;

            vendor_out = it->path().stem().string();

            // Variants are the model's nozzle diameters, ";"-separated.
            if (entry.contains("sub_path")) {
                const fs::path model_file =
                    profiles / vendor_out / entry["sub_path"].get<std::string>();
                try {
                    nlohmann::json model_json;
                    std::ifstream mfs(model_file.string());
                    mfs >> model_json;
                    std::string nozzles = model_json.value("nozzle_diameter", std::string());
                    std::string current;
                    for (char c : nozzles + ";") {
                        if (c == ';') {
                            if (!current.empty())
                                variants_out.insert(current);
                            current.clear();
                        } else {
                            current.push_back(c);
                        }
                    }
                } catch (const std::exception &) {
                }
            }
            return true;
        }
    }
    return false;
}

// Reads printer_model from the first printer/*.json inside a preset bundle.
// Needed before importing anything, so it cannot go through PresetBundle.
std::string printer_model_in_bundle(const std::string &path)
{
    mz_zip_archive zip{};
    if (!open_zip_reader(&zip, path))
        return {}; // a bare .json preset rather than a zip bundle
    std::string model;
    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    for (mz_uint i = 0; i < count && model.empty(); ++i) {
        mz_zip_archive_file_stat stat;
        if (!mz_zip_reader_file_stat(&zip, i, &stat))
            continue;
        const std::string name = stat.m_filename;
        if (name.rfind("printer/", 0) != 0)
            continue;
        std::vector<char> buffer(size_t(stat.m_uncomp_size) + 1, '\0');
        if (!mz_zip_reader_extract_to_mem(&zip, i, buffer.data(), buffer.size() - 1, 0))
            continue;
        try {
            const auto parsed = nlohmann::json::parse(buffer.data());
            model = parsed.value("printer_model", std::string());
        } catch (const std::exception &) {
        }
    }
    close_zip_reader(&zip);
    return model;
}

// Imported user presets are namespaced "_local/<uuid>/<name>", so a caller that
// knows a preset as "Sovol SV08 0.4 nozzle" has to be able to find it by the
// trailing component. A user preset may also deliberately shadow a system one of
// the same name, in which case the user's is what the operator meant.
const Preset *find_preset(const PresetCollection &collection, const std::string &name)
{
    auto basename = [](const std::string &full) {
        const size_t slash = full.rfind('/');
        return slash == std::string::npos ? full : full.substr(slash + 1);
    };

    const Preset *system_match = nullptr;
    for (const Preset &preset : collection) {
        if (preset.name != name && basename(preset.name) != name)
            continue;
        if (!preset.is_system)
            return &preset;
        system_match = &preset;
    }
    return system_match;
}


PresetCollection *collection_for(sp_engine *engine, sp_preset_kind kind)
{
    switch (kind) {
    case SP_PRESET_MACHINE:  return &engine->presets.printers;
    case SP_PRESET_PROCESS:  return &engine->presets.prints;
    case SP_PRESET_FILAMENT: return &engine->presets.filaments;
    }
    return nullptr;
}

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


// Merges the selected presets exactly as the GUI's calibration code does, via
// the public static entry point, so no preset selection state is involved.
bool build_config(sp_engine *engine, DynamicPrintConfig &out)
{
    auto pick = [&](sp_preset_kind kind, const std::string &wanted,
                    const char *label) -> const Preset * {
        PresetCollection *collection = collection_for(engine, kind);
        if (collection == nullptr)
            return nullptr;
        const Preset *preset = wanted.empty() ? nullptr : find_preset(*collection, wanted);
        if (preset == nullptr)
            engine->last_error = std::string("no ") + label + " preset selected";
        return preset;
    };

    const Preset *printer = pick(SP_PRESET_MACHINE, engine->sel_printer, "printer");
    const Preset *process = pick(SP_PRESET_PROCESS, engine->sel_process, "process");
    const Preset *filament = pick(SP_PRESET_FILAMENT, engine->sel_filament, "filament");
    if (printer == nullptr || process == nullptr || filament == nullptr)
        return false;

    // construct_full_config takes mutable references and may normalise as it
    // merges, so hand it copies rather than the collection's presets.
    Preset printer_copy = *printer;
    Preset process_copy = *process;
    std::vector<Preset> filament_copies{*filament};

    out = PresetBundle::construct_full_config(printer_copy, process_copy,
                                             engine->presets.project_config,
                                             filament_copies, true, std::nullopt);
    out.apply(engine->overrides, true);
    return true;
}

} // namespace

extern "C" {

sp_engine *sp_engine_create(const char *resources_dir, const char *data_dir)
{
    if (resources_dir == nullptr || data_dir == nullptr)
        return nullptr;
    try {
        auto engine = std::make_unique<sp_engine>();
        engine->resources_dir = resources_dir;
        // Quiet by default: libslic3r's boost::log writes to stdout, which would
        // corrupt the config dump. SLICEPAD_LOG raises it for debugging.
        const char *log_level = std::getenv("SLICEPAD_LOG");
        set_logging_level(log_level ? unsigned(std::atoi(log_level)) : 0);
        set_resources_dir(resources_dir);
        set_data_dir(data_dir);
        engine->presets.setup_directories();
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

sp_result sp_load_presets(sp_engine *engine, const char *path)
{
    return guard(engine, [&]() -> sp_result {
        if (path == nullptr || !boost::filesystem::exists(path)) {
            engine->last_error = std::string("no such file: ") + (path ? path : "(null)");
            return SP_ERR_IO;
        }

        // The vendor's system presets have to be installed before importing:
        // import silently skips any preset whose `inherits` parent is missing,
        // and every import mints a fresh bundle UUID, so importing twice to work
        // around that leaves duplicate presets under unstable names.
        //
        // So read the printer model straight out of the bundle first.
        const std::string printer_model = printer_model_in_bundle(path);
        if (printer_model.empty()) {
            engine->last_error = "bundle contains no printer preset naming a printer_model";
            return SP_ERR_PARSE;
        }

        std::string vendor;
        std::set<std::string> variants;
        if (!find_vendor_for_model(engine->resources_dir, printer_model, vendor, variants)) {
            engine->last_error = "no bundled vendor provides printer model " + printer_model;
            return SP_ERR_UNRESOLVED;
        }

        std::map<std::string, std::map<std::string, std::set<std::string>>> vendors;
        vendors[vendor][printer_model] = variants;
        if (!engine->presets.apply_vendor_config(vendors, {}, &engine->app_config, true,
                                                 printer_model)) {
            engine->last_error = "failed to install vendor " + vendor;
            return SP_ERR_UNRESOLVED;
        }
        BOOST_LOG_TRIVIAL(info) << "slicepad: after apply_vendor_config prints="
                                << engine->presets.prints.size()
                                << " filaments=" << engine->presets.filaments.size()
                                << " printers=" << engine->presets.printers.size();

        // 3 is yes-to-all for the overwrite prompt, per import_json_presets.
        std::vector<std::string> files{path};
        auto overwrite_all = [](const std::string &) { return 3; };
        engine->presets.import_presets(files, overwrite_all,
                                       ForwardCompatibilitySubstitutionRule::EnableSilent,
                                       engine->app_config);
        BOOST_LOG_TRIVIAL(info) << "slicepad: after import prints="
                                << engine->presets.prints.size()
                                << " filaments=" << engine->presets.filaments.size()
                                << " printers=" << engine->presets.printers.size();
        return SP_OK;
    });
}

int sp_preset_count(const sp_engine *engine, sp_preset_kind kind)
{
    if (engine == nullptr)
        return 0;
    auto *collection = collection_for(const_cast<sp_engine *>(engine), kind);
    return collection ? int(collection->size()) : 0;
}

const char *sp_preset_name(const sp_engine *engine, sp_preset_kind kind, int index)
{
    if (engine == nullptr)
        return nullptr;
    auto *collection = collection_for(const_cast<sp_engine *>(engine), kind);
    if (collection == nullptr || index < 0 || size_t(index) >= collection->size())
        return nullptr;
    return collection->preset(size_t(index)).name.c_str();
}

sp_result sp_select_preset(sp_engine *engine, sp_preset_kind kind, const char *name)
{
    return guard(engine, [&]() -> sp_result {
        auto *collection = collection_for(engine, kind);
        if (collection == nullptr || name == nullptr)
            return SP_ERR_STATE;
        if (find_preset(*collection, name) == nullptr) {
            engine->last_error = std::string("no such preset: ") + name;
            return SP_ERR_UNRESOLVED;
        }
        // Recorded rather than selected in the collection: PresetCollection's
        // selection is entangled with visibility and compatibility filtering,
        // which is GUI behaviour we do not want deciding what we slice.
        switch (kind) {
        case SP_PRESET_MACHINE:  engine->sel_printer = name; break;
        case SP_PRESET_PROCESS:  engine->sel_process = name; break;
        case SP_PRESET_FILAMENT: engine->sel_filament = name; break;
        }
        return SP_OK;
    });
}

sp_result sp_load_model(sp_engine *engine, const char *path)
{
    return guard(engine, [&]() -> sp_result {
        if (path == nullptr || !boost::filesystem::exists(path)) {
            engine->last_error = std::string("no such file: ") + (path ? path : "(null)");
            return SP_ERR_IO;
        }
        engine->model = Model::read_from_file(path, nullptr, nullptr,
                                              LoadStrategy::AddDefaultInstances);
        engine->model_loaded = true;
        return SP_OK;
    });
}

int sp_object_count(const sp_engine *engine)
{
    return engine ? int(engine->model.objects.size()) : 0;
}

sp_result sp_set_transform(sp_engine *engine, int object_index, double scale,
                           double rotate_z_deg, double translate_x, double translate_y)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded || object_index < 0 ||
            size_t(object_index) >= engine->model.objects.size())
            return SP_ERR_STATE;
        ModelObject *object = engine->model.objects[size_t(object_index)];
        if (object->instances.empty())
            return SP_ERR_STATE;
        ModelInstance *instance = object->instances.front();
        instance->set_scaling_factor(Vec3d(scale, scale, scale));
        instance->set_rotation(Z, rotate_z_deg * M_PI / 180.0);
        instance->set_offset(Vec3d(translate_x, translate_y, instance->get_offset().z()));
        object->invalidate_bounding_box();
        return SP_OK;
    });
}

sp_result sp_arrange(sp_engine *engine)
{
    return guard(engine, [&]() -> sp_result {
        if (!engine->model_loaded)
            return SP_ERR_STATE;
        // Placement beyond centring is not implemented yet; the plate editor is
        // the natural place to decide policy and it does not exist.
        engine->model.center_instances_around_point(Vec2d(0, 0));
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

        const ConfigDef *def = engine->overrides.def() ? engine->overrides.def()
                                                       : &Slic3r::print_config_def;
        for (const auto &[key, value] : parsed.items()) {
            if (def->get(key) == nullptr) {
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
        if (!engine->model_loaded) {
            engine->last_error = "no model loaded";
            return SP_ERR_STATE;
        }
        if (out_gcode_path == nullptr)
            return SP_ERR_IO;

        DynamicPrintConfig config;
        if (!build_config(engine, config))
            return SP_ERR_STATE;

        Print print;
        print.apply(engine->model, config);
        // validate() reports warnings through its out-param and real problems
        // through the return value, distinguished by is_warning.
        const StringObjectException problem = print.validate();
        if (!problem.string.empty() && !problem.is_warning) {
            engine->last_error = problem.string;
            return SP_ERR_SLICE;
        }

        if (progress != nullptr) {
            print.set_status_callback([progress, user](const PrintBase::SlicingStatus &status) {
                progress(int(status.percent), status.text.c_str(), user);
            });
        }

        print.process();

        GCodeProcessorResult result;
        print.export_gcode(out_gcode_path, &result, nullptr);

        // TODO: populate from result.print_statistics once the UI needs it. Left
        // empty deliberately rather than reporting a number I have not verified
        // against what Orca shows for the same slice.
        engine->stats_json = "{}";
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
        DynamicPrintConfig config;
        if (!build_config(engine, config))
            return engine->config_text.c_str();
        // keys() is sorted, which keeps the output diffable.
        for (const std::string &key : config.keys())
            engine->config_text += key + " = " + config.opt_serialize(key) + "\n";
    } catch (const std::exception &e) {
        engine->last_error = e.what();
        engine->config_text.clear();
    }
    return engine->config_text.c_str();
}

const char *sp_engine_version(void) { return SLIC3R_VERSION; }

} // extern "C"
