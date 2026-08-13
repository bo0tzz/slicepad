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

/* The config schema version the profile was written against, e.g. "02.06.00.51",
 * or an empty string if the project does not record one. Compare against
 * sp_engine_config_version(): equal versions mean no migration was needed. A
 * mismatch is a caution rather than an error — libslic3r migrates older
 * profiles, and doing so is normal. */
const char *sp_config_source_version(const sp_engine *engine);

/* Number of mesh defects libslic3r repaired while loading the model. Non-zero
 * means the mesh was not watertight and has been patched up, which is worth
 * surfacing before someone prints it. */
int sp_model_repaired_errors(const sp_engine *engine);

/* Replaces any previously loaded model. Accepts .stl, .3mf, and .obj — note
 * that STEP is deliberately not built, so OCCT is absent.
 *
 * Loading drops each object onto the bed in Z, as Plater does, and a saved
 * project keeps the placement it came with.
 *
 * It does NOT move anything in X or Y. A bare CAD export therefore stays where
 * it was modelled — usually the origin, often with negative coordinates — and
 * sp_slice refuses it as outside the printable area rather than emitting G-code
 * that would drive the toolhead off the bed. Call sp_arrange (and, for a part
 * lying in a modelling orientation, sp_auto_orient) to place it. Centring here
 * was tried and made libslic3r emit INT64_MIN coordinates for the test model;
 * see the note in sp_load_model's implementation. */
sp_result sp_load_model(sp_engine *engine, const char *path);
int sp_object_count(const sp_engine *engine);

/* Uniform scale, rotation about each axis in degrees, and translation in bed
 * millimetres. Rotation is absolute rather than incremental, so a control can
 * bind straight to it. X and Y rotation is what stands a part up: without it the
 * only way to reorient a CAD export is sp_auto_orient.
 *
 * The object is dropped back onto the bed afterwards, since rotating about X or
 * Y moves it through the print surface. Anything richer than this belongs in
 * desktop Orca. */
sp_result sp_set_transform(sp_engine *engine, int object_index, double scale,
                           double rotate_x_deg, double rotate_y_deg,
                           double rotate_z_deg,
                           double translate_x, double translate_y);
/* The object's current placement, as six doubles: scale, rotation about each axis
 * in degrees, then translation x and y — exactly the arguments sp_set_transform
 * takes, so the two round-trip.
 *
 * Needed because sp_set_transform is absolute in every argument. A caller that
 * exposes only some of them, as a simple UI will, has to pass the rest back
 * unchanged; without this it would send zeros, which teleports the object to the
 * bed origin and undoes any auto-orientation. */
sp_result sp_object_transform(sp_engine *engine, int object_index, double *out_values);

/* Place objects on the bed using libslic3r's own arrange — the same code the
 * desktop's arrange button drives. Needs a profile loaded, since the bed comes
 * from it. A bare CAD export arrives at the origin and will not slice until this
 * or an explicit transform puts it on the bed. */
sp_result sp_arrange(sp_engine *engine);

/* Turn the object so the flat face nearest to facing down does face down.
 *
 * For a control that tidies up a rough placement: rotate the part roughly, and
 * this settles it onto the face it was nearly on. It picks the candidate closest
 * to the current orientation rather than the largest one, so it corrects what was
 * meant instead of overruling it.
 *
 * Candidates come from the convex hull, since a face worth standing on is on the
 * outside — the floor of a pocket is flat and useless for this — grouped by
 * normal and weighted by area, ignoring anything under 5mm². The same approach
 * the desktop's place-on-face gizmo takes, though that code lives in its GUI.
 *
 * SP_ERR_STATE when the model has no face large enough to stand on. */
sp_result sp_place_nearest_face_down(sp_engine *engine, int object_index);

/* Rotate objects into a printable orientation using the desktop's auto-orient
 * algorithm, then drop them back onto the bed. CAD exports are usually oriented
 * for modelling rather than printing, and sp_set_transform only rotates about Z,
 * so this is the only way to stand a part up. */
sp_result sp_auto_orient(sp_engine *engine);

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

/* Geometry a plate view needs. Together these answer the question the view
 * exists for: is the model the size I meant, and is it on the bed?
 *
 * sp_mesh_* gives the loaded model's triangles in bed millimetres with object
 * and instance transforms already applied — nine floats per triangle, ready for
 * a vertex buffer. sp_bed_* gives the printable area outline from the profile,
 * as x,y pairs. Both are owned by the engine.
 *
 * The mesh is rebuilt, and any pointer to it invalidated, by anything that moves
 * geometry: sp_load_model, sp_set_transform, sp_arrange and sp_auto_orient. The
 * bed lasts until the next sp_load_config. Copy out what you need rather than
 * holding these across calls.
 *
 * sp_object_bounds writes min then max as six floats (x,y,z,x,y,z). */
size_t sp_mesh_triangle_count(const sp_engine *engine);
const float *sp_mesh_vertices(const sp_engine *engine);
size_t sp_bed_point_count(const sp_engine *engine);
const float *sp_bed_points(const sp_engine *engine);
sp_result sp_object_bounds(sp_engine *engine, int object_index, float *out_min_max);

/* Extruding moves from the last slice, as packed line segments: six floats per
 * segment, (x1,y1,z1,x2,y2,z2) in bed millimetres. Travel, wipe and retract
 * moves are excluded, so drawing every segment as a line gives the stacked-layer
 * view directly — no parsing and no geometry generation, because the engine
 * already produces this while slicing.
 *
 * The pointer is owned by the engine and valid until the next sp_slice; it is
 * NULL when the count is zero. Feed it to a vertex buffer as-is. */
size_t sp_toolpath_segment_count(const sp_engine *engine);
const float *sp_toolpath_segments(const sp_engine *engine);

/* What each segment is, where it sits and how big it is: one entry per segment in
 * each of these, in the same order as sp_toolpath_segments, so index i describes
 * the segment at floats [i*6, i*6+6). Same ownership as the coordinates —
 * engine-owned, valid until the next sp_slice, NULL when the count is zero.
 *
 * Parallel arrays rather than one array of structs, because a struct crossing
 * this boundary would tie the two sides together by padding and alignment, which
 * is the kind of agreement that breaks silently. These are read once per slice
 * and indexed thereafter, so the extra calls cost nothing.
 *
 * Roles are ours rather than libslic3r's. Its ExtrusionRole is an implementation
 * detail that gains and reorders values between versions, and it draws
 * distinctions a viewer cannot act on; these are the groups worth a colour:
 *
 *   - the two wall roles are separate because the outer one is the surface you
 *     see and the inner one is not
 *   - sparse and solid infill are separate because their density is the thing
 *     someone is usually looking for
 *   - bridges are separate because they print over air, which is where a print
 *     most often fails
 *   - support and skirt/brim are separate because they are not the part
 *
 * Roles that lose a distinction here: overhang perimeters are reported as outer
 * wall, since they are the outside surface and Orca's own separation of them is
 * about speed and cooling rather than about where the line sits; gap fill is
 * OTHER rather than being folded into walls or infill, because it is neither and
 * pretending otherwise would misdescribe what is on screen.
 *
 * Layer indices are zero-based and non-decreasing through the buffer, so a layer
 * range selects a contiguous run. sp_toolpath_layer_count is how many layers
 * contain extrusions, which is what a layer control should scrub over; it agrees
 * with layer_count in sp_slice_stats_json. */
typedef enum {
    SP_ROLE_OTHER = 0,
    SP_ROLE_OUTER_WALL = 1,
    SP_ROLE_INNER_WALL = 2,
    SP_ROLE_INFILL = 3,
    SP_ROLE_SOLID_INFILL = 4,
    SP_ROLE_BRIDGE = 5,
    SP_ROLE_SUPPORT = 6,
    SP_ROLE_SKIRT_BRIM = 7,
} sp_extrusion_role;

/* One byte per segment, each an sp_extrusion_role. A byte rather than the enum's
 * own width because this is a buffer a renderer walks, and a real print has
 * hundreds of thousands of segments. */
const unsigned char *sp_toolpath_roles(const sp_engine *engine);
const unsigned *sp_toolpath_layers(const sp_engine *engine);

/* The extruded cross-section in millimetres, as the slicer planned it: the width
 * of the line on the bed and the height of the layer it belongs to. Drawing a
 * segment at these dimensions is what makes a layer view look like the object
 * being built rather than a wireframe of its centre lines, and they are not
 * constant — first layers, solid infill and bridges all differ from the walls
 * around them. */
const float *sp_toolpath_widths(const sp_engine *engine);
const float *sp_toolpath_heights(const sp_engine *engine);

size_t sp_toolpath_layer_count(const sp_engine *engine);

/* The configuration the next slice would use — the loaded profile plus any
 * overrides — as "key = value" lines sorted by key. That is deliberately the
 * same shape Orca embeds in its own G-code, so
 * the two can be diffed directly to test profile resolution without slicing
 * anything. Valid until the next call on this engine. */
const char *sp_resolved_config_text(sp_engine *engine);

/* Release version of the embedded engine, e.g. "2.4.2". Profiles are only
 * guaranteed to round-trip against the desktop Orca that produced them at this
 * version. */
const char *sp_engine_version(void);

/* Config schema version of the embedded engine, e.g. "02.06.00.51". This is what
 * profile versions are comparable against; the release version is not. */
const char *sp_engine_config_version(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SLICEPAD_H */
