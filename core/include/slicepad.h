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
    SP_ERR_PARSE = 2,       /* malformed profile bundle, model, or override JSON */
    SP_ERR_UNRESOLVED = 3,  /* an `inherits` parent is not in the bundled profiles */
    SP_ERR_STATE = 4,       /* required preset or model not selected yet */
    SP_ERR_SLICE = 5,       /* the engine rejected the job (see sp_last_error) */
    SP_ERR_CANCELLED = 6,
} sp_result;

typedef enum {
    SP_PRESET_MACHINE = 0,
    SP_PRESET_PROCESS = 1,
    SP_PRESET_FILAMENT = 2,
} sp_preset_kind;

/* Return 0 to continue slicing, non-zero to cancel (yields SP_ERR_CANCELLED).
 * `stage` is an engine phase name such as "Generating perimeters"; it is only
 * valid for the duration of the call. */
typedef int (*sp_progress_fn)(int percent, const char *stage, void *user);

/* `system_profiles_dir` holds the trimmed copy of OrcaSlicer's
 * resources/profiles tree that ships in the app bundle. It is the search path
 * for resolving `inherits` chains in user-supplied presets. */
sp_engine *sp_engine_create(const char *system_profiles_dir);
void sp_engine_destroy(sp_engine *engine);

/* Human-readable detail for the most recent non-SP_OK return. Valid until the
 * next call on this engine. Never NULL. */
const char *sp_last_error(const sp_engine *engine);

/* Load presets from an .orca_bundle (zip), or a single .orca_printer /
 * .orca_filament / .json preset file. Merges into any already loaded, so a
 * printer bundle and separately exported filaments can be combined. */
sp_result sp_load_presets(sp_engine *engine, const char *path);

int sp_preset_count(const sp_engine *engine, sp_preset_kind kind);
/* Valid until the next sp_load_presets. Returns NULL if index is out of range. */
const char *sp_preset_name(const sp_engine *engine, sp_preset_kind kind, int index);
sp_result sp_select_preset(sp_engine *engine, sp_preset_kind kind, const char *name);

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

/* Config overrides layered on top of the selected process preset — the "tweak
 * the basics" path.
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

/* Version of the embedded engine, e.g. "2.4.2". Profiles are only guaranteed
 * to round-trip against the desktop Orca that produced them at this version. */
const char *sp_engine_version(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SLICEPAD_H */
