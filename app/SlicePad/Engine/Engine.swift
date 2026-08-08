import Foundation
import SlicePadCore

struct EngineError: LocalizedError {
    let code: sp_result
    let message: String
    var errorDescription: String? { message }

    /// Asked about often enough, and by code that has no business importing the C
    /// module — cancelling is a normal outcome, not a failure to report.
    var isCancellation: Bool { code == SP_ERR_CANCELLED }
}

/// Statistics from the last slice. The engine reports these as JSON; the shape is
/// mirrored here rather than passed around as a dictionary so a view can bind to it.
/// A box for the slice progress callback. A C function pointer cannot capture, so
/// the closure travels through the `user` pointer instead.
private final class ProgressBox {
    let onProgress: (Int, String) -> Bool
    init(_ onProgress: @escaping (Int, String) -> Bool) { self.onProgress = onProgress }
}

private func progressThunk(percent: Int32, stage: UnsafePointer<CChar>?, user: UnsafeMutableRawPointer?) -> Int32 {
    guard let user else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
    let text = stage.map { String(cString: $0) } ?? ""
    return box.onProgress(Int(percent), text) ? 0 : 1
}

/// Swift face of the C ABI. Not thread safe: one engine belongs to one queue, and
/// `slice` is the only call meant to run off the main one.
final class Engine {
    private let handle: OpaquePointer

    init() throws {
        let resources = Bundle.main.resourceURL!.appendingPathComponent("orca-resources")
        let data = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        guard let handle = sp_engine_create(resources.path, data.path) else {
            throw EngineError(code: SP_ERR_STATE, message: "The slicing engine would not start.")
        }
        self.handle = handle
    }

    deinit { sp_engine_destroy(handle) }

    static var version: String { String(cString: sp_engine_version()) }
    static var configVersion: String { String(cString: sp_engine_config_version()) }

    private func check(_ result: sp_result) throws {
        guard result != SP_OK else { return }
        throw EngineError(code: result, message: String(cString: sp_last_error(handle)))
    }

    // MARK: Profile

    func loadProfile(at url: URL) throws {
        try withSecurityScope(url) { scoped in
            try check(sp_load_config(handle, scoped.path))
            // Best effort: a profile that loaded but could not be filed away is
            // still usable now, and the only cost is picking it again next launch.
            try? ProfileStore.save(scoped)
        }
    }

    /// Empty when the profile records no version. A mismatch against
    /// `Engine.configVersion` is a caution, not an error: libslic3r migrates.
    var profileVersion: String { String(cString: sp_config_source_version(handle)) }

    /// The configuration the next slice would use, as the engine reports it — the
    /// same "key = value" shape Orca embeds in its G-code.
    func resolvedConfig() -> [String: String] {
        let text = String(cString: sp_resolved_config_text(handle))
        var config: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            config[key] = value
        }
        return config
    }

    // MARK: Model

    func loadModel(at url: URL) throws {
        try withSecurityScope(url) { try check(sp_load_model(handle, $0.path)) }
    }

    var objectCount: Int { Int(sp_object_count(handle)) }
    var repairedErrors: Int { Int(sp_model_repaired_errors(handle)) }

    func setTransform(object: Int = 0, scale: Double, rotateX: Double, rotateY: Double,
                      rotateZ: Double, translateX: Double, translateY: Double) throws {
        try check(sp_set_transform(handle, Int32(object), scale, rotateX, rotateY,
                                   rotateZ, translateX, translateY))
    }

    /// Scale, rotation about each axis in degrees, then translation — the same six
    /// values `setTransform` takes. Read before writing: every argument there is
    /// absolute, so anything the caller is not changing has to be passed back
    /// unchanged.
    func transform(object: Int = 0) -> [Double]? {
        var values = [Double](repeating: 0, count: 6)
        guard sp_object_transform(handle, Int32(object), &values) == SP_OK else { return nil }
        return values
    }

    func autoOrient() throws { try check(sp_auto_orient(handle)) }
    func arrange() throws { try check(sp_arrange(handle)) }

    // MARK: Slicing

    func setOverrides(_ overrides: Overrides) throws {
        try check(sp_set_overrides(handle, overrides.json))
    }

    /// Blocks. `onProgress` returns false to cancel, and is called on this thread.
    func slice(to url: URL, onProgress: @escaping (Int, String) -> Bool) throws {
        let box = ProgressBox(onProgress)
        let user = Unmanaged.passUnretained(box).toOpaque()
        try check(sp_slice(handle, url.path, progressThunk, user))
    }

    var stats: SliceStats? {
        let json = String(cString: sp_slice_stats_json(handle))
        return try? JSONDecoder().decode(SliceStats.self, from: Data(json.utf8))
    }

    // MARK: Geometry

    /// Triangles in bed millimetres, three vertices each, transforms applied.
    func meshTriangles() -> [SIMD3<Float>] {
        let count = sp_mesh_triangle_count(handle)
        guard count > 0, let base = sp_mesh_vertices(handle) else { return [] }
        return (0 ..< count * 3).map { i in
            SIMD3(base[i * 3], base[i * 3 + 1], base[i * 3 + 2])
        }
    }

    /// The printable area outline from the profile, as x,y pairs.
    func bedOutline() -> [SIMD2<Float>] {
        let count = sp_bed_point_count(handle)
        guard count > 0, let base = sp_bed_points(handle) else { return [] }
        return (0 ..< count).map { SIMD2(base[$0 * 2], base[$0 * 2 + 1]) }
    }

    /// Extruding moves from the last slice as line segment endpoints — already in
    /// the form a vertex buffer wants, which is what makes the layer view cheap.
    func toolpathSegments() -> [SIMD3<Float>] {
        let count = sp_toolpath_segment_count(handle)
        guard count > 0, let base = sp_toolpath_segments(handle) else { return [] }
        return (0 ..< count * 2).map { i in
            SIMD3(base[i * 3], base[i * 3 + 1], base[i * 3 + 2])
        }
    }

    func objectBounds(object: Int = 0) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var values = [Float](repeating: 0, count: 6)
        guard sp_object_bounds(handle, Int32(object), &values) == SP_OK else { return nil }
        return (SIMD3(values[0], values[1], values[2]), SIMD3(values[3], values[4], values[5]))
    }

    // MARK: -

    /// Files chosen through the document picker live outside the sandbox, and the
    /// engine opens them by path — so the scope has to be held across the call.
    private func withSecurityScope(_ url: URL, _ body: (URL) throws -> Void) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try body(url)
    }
}
