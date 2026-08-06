/* SlicePad slicing core — C ABI over OrcaSlicer's libslic3r.
 *
 * Everything crossing this boundary is a C string, a primitive, or a byte
 * buffer, so Swift can call it directly without a C++ interop shim. Structured
 * data is JSON: it keeps the surface small enough to stay stable across
 * OrcaSlicer version bumps, where the config key set is the thing that moves.
 *
 * All functions are single-threaded with respect to one sp_engine. Call
 * sp_slice from a background queue; the progress callback fires on that same
 * thread.
 */
#ifndef SLICEPAD_H
#define SLICEPAD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sp_engine sp_engine;

typedef enum {
    SP_OK = 0,
    SP_ERR_IO = 1,          /* file missing, unreadable, or not the claimed format */
    SP_ERR_PARSE = 2,       /* malformed project, model, or override JSON */
    SP_ERR_UNRESOLVED = 3,  /* the project carries no usable configuration */
    SP_ERR_STATE = 4,       /* no profile or model loaded yet */
    SP_ERR_SLICE = 5,       /* the engine rejected the job (see sp_last_error) */
    SP_ERR_CANCELLED = 6,
} sp_result;

/* Note there is no notion of presets here, deliberately. A profile arrives as a
 * project .3mf saved by desktop Orca, whose Metadata/project_settings.config
 * holds the printer, process and filament settings already merged — 655 keys for
 * a real SV08 profile. Consuming that instead of an exported preset bundle means
 * no `inherits` chains to resolve, no vendor profiles to ship, and no dependence
 * on PresetBundle, whose preset resolution is built around GUI and cloud-sync
 * state that does not exist here. */

/* Return 0 to continue slicing, non-zero to cancel (yields SP_ERR_CANCELLED).
 * `stage` is an engine phase name such as "Generating perimeters"; it is only
 * valid for the duration of the call. */
typedef int (*sp_progress_fn)(int percent, const char *stage, void *user);

/* `resources_dir` is the OrcaSlicer resources tree shipped in the app bundle.
 * `data_dir` must be writable. Neither needs to contain profiles/ any more, since
 * profiles arrive fully resolved; they are still set because libslic3r reads
 * other things from both. On iOS, data_dir belongs under Application Support. */
sp_engine *sp_engine_create(const char *resources_dir, const char *data_dir);
void sp_engine_destroy(sp_engine *engine);

/* Human-readable detail for the most recent non-SP_OK return. Valid until the
 * next call on this engine. Never NULL. */
const char *sp_last_error(const sp_engine *engine);

/* Load a profile from a project .3mf saved by desktop OrcaSlicer (File → Save
 * Project As). The geometry in it is ignored — only the resolved configuration
 * is kept — so one "profile carrier" project can be exported when the profile
 * changes and reused for every model afterwards. */
sp_result sp_load_config(sp_engine *engine, const char *path);

/* The engine version the profile was written by, if the project records one.
 * Returns an empty string when absent. A profile from a different OrcaSlicer
 * version than sp_engine_version() may not slice identically. */
const char *sp_config_source_version(const sp_engine *engine);

/* Replaces any previously loaded model. Accepts .stl, .3mf, and .obj — note
 * that STEP is deliberately not built, so OCCT is absent. */
sp_result sp_load_model(sp_engine *engine, const char *path);
int sp_object_count(const sp_engine *engine);

/* Uniform scale plus Z rotation in degrees, applied about the object centre;
 * translation is in bed millimetres. This is the whole plate-editing model —
 * anything richer belongs in desktop Orca, not here. */
sp_result sp_set_transform(sp_engine *engine, int object_index,
                           double scale, double rotate_z_deg,
                           double translate_x, double translate_y);
/* Drop objects onto the bed and space them out, mirroring Orca's arrange. */
sp_result sp_arrange(sp_engine *engine);

/* Config overrides layered on top of the loaded profile — the "tweak the
 * basics" path.
 *
 * The shape is a fragment of an Orca preset file, not an encoding of our own:
 * an object of config keys to strings, or to arrays of strings for per-extruder
 * vector options ({"sparse_infill_density": "25%", "nozzle_temperature":
 * ["215"]}). That is how libslic3r natively represents a preset — see
 * ConfigBase::load_from_json and ConfigBase::set_deserialize — so overrides can
 * be copy-pasted from an exported preset and validated against PrintConfigDef.
 * An unknown key or unparseable value fails here rather than being silently
 * dropped at slice time. Pass NULL or "{}" to clear. */
sp_result sp_set_overrides(sp_engine *engine, const char *overrides_json);

/* Runs the full pipeline and writes G-code to out_gcode_path. `progress` may
 * be NULL. Blocks until done. */
sp_result sp_slice(sp_engine *engine, const char *out_gcode_path,
                   sp_progress_fn progress, void *user);

/* JSON: estimated print time, filament length and weight per extruder, layer
 * count, object bounding box. Valid until the next sp_slice. */
const char *sp_slice_stats_json(const sp_engine *engine);

/* The configuration the next slice would use — the loaded profile plus any
 * overrides — as "key = value" lines sorted
 * by key. That is deliberately the same shape Orca embeds in its own G-code, so
 * the two can be diffed directly to test profile resolution without slicing
 * anything. Valid until the next call on this engine. */
const char *sp_resolved_config_text(sp_engine *engine);

/* Version of the embedded engine, e.g. "2.4.2". Profiles are only guaranteed
 * to round-trip against the desktop Orca that produced them at this version. */
const char *sp_engine_version(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SLICEPAD_H */
