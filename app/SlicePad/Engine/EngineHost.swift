import Foundation

/// Geometry snapshot for the plate view. Copied out of the engine's buffers, which
/// are only valid until the next call — so the view never holds engine memory.
struct PlateGeometry {
    var bed: [SIMD2<Float>] = []
    var triangles: [SIMD3<Float>] = []
    var toolpath: [SIMD3<Float>] = []
    /// Per segment, in the same order as `toolpath`'s pairs: what kind of extrusion
    /// it is, which layer it belongs to, and how wide and tall the slicer laid it.
    var roles: [UInt8] = []
    var layers: [UInt32] = []
    var widths: [Float] = []
    var heights: [Float] = []
    var layerCount = 0
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    /// Where the object sits on the bed, so a drag can start from it rather than
    /// from wherever the finger landed on the mesh.
    var offset = SIMD2<Float>(0, 0)

    /// Bumped whenever the engine is read again. The view rebuilds on a change of
    /// this rather than on a change of the arrays: a progress tick redraws the whole
    /// UI a hundred times during a slice, and comparing a few hundred thousand
    /// floats to discover nothing moved is its own kind of waste.
    var revision = 0

    /// Bumped only when a different model is loaded. The camera follows this, not
    /// `revision`: it should frame a newly opened part, but must not snap back to
    /// its default every time a slider moves the one you are already looking at.
    var modelGeneration = 0
}

/// Serialises access to the engine, which is single-threaded per instance, and
/// keeps slicing off the main thread.
///
/// A dedicated thread rather than an actor, because a slice is a synchronous C
/// call that does not return for as long as it takes. Swift's cooperative pool
/// has one thread per core and expects work to yield; parking one of them for a
/// minute starves everything else scheduled on it. A queue of our own is the
/// right place for blocking work, and serialising it gives the same guarantee
/// the engine asks for: one call at a time.
final class EngineHost: @unchecked Sendable {
    private let engine: Engine
    private let queue = DispatchQueue(label: "slicepad.engine", qos: .userInitiated)

    init() throws {
        engine = try Engine()
    }

    /// Every entry point funnels through here, so "one call at a time, never on the
    /// caller's thread" is stated once rather than per method.
    private func perform<T: Sendable>(_ work: @escaping @Sendable (Engine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work(self.engine) })
            }
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (Engine) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work(self.engine))
            }
        }
    }

    struct LoadedProfile {
        let version: String
        /// What the profile already says, so the controls start where it left off.
        let settings: Overrides
        /// True when loading the profile also placed a model that was waiting for a
        /// bed — the view needs to re-frame, since the part is no longer where the
        /// camera was pointed.
        let placedModel: Bool
    }

    /// The profile from the last run, if there is one. Separate from loadProfile
    /// so a stored file that no longer loads — an engine bump, a corrupted copy —
    /// is a quiet absence at launch rather than an error over an empty plate.
    func restoreProfile() async -> LoadedProfile? {
        guard let saved = ProfileStore.saved else { return nil }
        return try? await loadProfile(at: saved)
    }

    func loadProfile(at url: URL) async throws -> LoadedProfile {
        try await perform { engine in
            try engine.loadProfile(at: url)

            // The bed arrives with the profile, so a model opened before it could
            // not be placed at the time. Nothing else would revisit that, and the
            // symptom is a slice refused for a model the app appears to have put
            // down properly.
            var placed = false
            if Self.isOffBed(engine) {
                try? engine.arrange()
                placed = true
            }
            return LoadedProfile(version: engine.profileVersion,
                                 settings: Overrides(from: engine.resolvedConfig()),
                                 placedModel: placed)
        }
    }

    func loadModel(at url: URL) async throws -> Int {
        try await perform { engine in
            try engine.loadModel(at: url)

            // A CAD export arrives where it was modelled — for Shapr3D that is the
            // origin, with negative coordinates — and the engine refuses to slice
            // anything off the bed. Desktop Orca puts an import on the plate for
            // you; without this the first thing the app does with a real export is
            // report "outside the printable area".
            //
            // Only when it is actually off the bed, so a saved project keeps the
            // placement it came with. Arranging needs the bed, so it does nothing
            // useful before a profile is loaded — and slicing is blocked until then
            // anyway, which is where the missing profile gets reported.
            if Self.isOffBed(engine) {
                try? engine.arrange()
            }
            return engine.repairedErrors
        }
    }

    private static func isOffBed(_ engine: Engine) -> Bool {
        let bed = engine.bedOutline()
        guard !bed.isEmpty, let bounds = engine.objectBounds() else { return false }
        // The bed outline can be any polygon; its bounding rectangle is enough to
        // answer "did this land somewhere impossible", which is the question here.
        let minX = bed.map(\.x).min() ?? 0, maxX = bed.map(\.x).max() ?? 0
        let minY = bed.map(\.y).min() ?? 0, maxY = bed.map(\.y).max() ?? 0
        return bounds.min.x < minX || bounds.min.y < minY
            || bounds.max.x > maxX || bounds.max.y > maxY
    }

    func autoOrient() async throws {
        try await perform { try $0.autoOrient() }
    }

    /// What the Z control should read after the engine has placed the object itself.
    func rotationZ() async -> Double {
        await perform { $0.transform()?[3] ?? 0 }
    }

    func arrange() async throws {
        try await perform { try $0.arrange() }
    }

    /// Moves the object on the bed, keeping everything else where it is. Every
    /// argument of sp_set_transform is absolute, so anything not being changed has
    /// to be read back and passed through.
    func setPosition(x: Double, y: Double) async throws {
        try await perform { engine in
            let current = engine.transform() ?? [1, 0, 0, 0, 0, 0]
            try engine.setTransform(scale: current[0], rotateX: current[1],
                                    rotateY: current[2], rotateZ: current[3],
                                    translateX: x, translateY: y)
        }
    }

    /// Applies the two controls the app exposes, keeping the X and Y rotation
    /// auto-orient chose and the position the object sits at — same reason.
    func setScaleAndRotation(scale: Double, rotateZ: Double) async throws {
        try await perform { engine in
            let current = engine.transform() ?? [1, 0, 0, 0, 0, 0]
            try engine.setTransform(scale: scale, rotateX: current[1], rotateY: current[2],
                                    rotateZ: rotateZ, translateX: current[4],
                                    translateY: current[5])
        }
    }

    func slice(overrides: Overrides, to url: URL,
               onProgress: @Sendable @escaping (Int, String) -> Bool) async throws -> SliceStats? {
        try await perform { engine in
            try engine.setOverrides(overrides)
            try engine.slice(to: url, onProgress: onProgress)
            return engine.stats
        }
    }

    /// One call for everything the view draws, so a redraw cannot mix geometry from
    /// two different engine states.
    func geometry(includeToolpath: Bool) async -> PlateGeometry {
        await perform { engine -> PlateGeometry in
            var geometry = PlateGeometry(
                bed: engine.bedOutline(),
                triangles: engine.meshTriangles(),
                toolpath: includeToolpath ? engine.toolpathSegments() : [],
                bounds: engine.objectCount > 0 ? engine.objectBounds() : nil
            )
            if includeToolpath {
                let described = engine.toolpathDescription()
                geometry.roles = described.roles
                geometry.layers = described.layers
                geometry.widths = described.widths
                geometry.heights = described.heights
                geometry.layerCount = described.layerCount
            }
            if let placement = engine.transform() {
                geometry.offset = SIMD2(Float(placement[4]), Float(placement[5]))
            }
            return geometry
        }
    }
}
