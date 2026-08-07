import Foundation

/// Geometry snapshot for the plate view. Copied out of the engine's buffers, which
/// are only valid until the next call — so the view never holds engine memory.
struct PlateGeometry {
    var bed: [SIMD2<Float>] = []
    var triangles: [SIMD3<Float>] = []
    var toolpath: [SIMD3<Float>] = []
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

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
actor EngineHost {
    private let engine: Engine

    init() throws { engine = try Engine() }

    struct LoadedProfile {
        let version: String
        /// What the profile already says, so the controls start where it left off.
        let settings: Overrides
    }

    func loadProfile(at url: URL) throws -> LoadedProfile {
        try engine.loadProfile(at: url)
        return LoadedProfile(version: engine.profileVersion,
                             settings: Overrides(from: engine.resolvedConfig()))
    }

    func loadModel(at url: URL) throws -> Int {
        try engine.loadModel(at: url)
        return engine.repairedErrors
    }

    func autoOrient() throws { try engine.autoOrient() }

    /// What the Z control should read after the engine has placed the object itself.
    func rotationZ() -> Double { engine.transform()?[3] ?? 0 }
    func arrange() throws { try engine.arrange() }

    /// Applies just the two controls the app exposes, keeping everything else where
    /// the engine already has it: the X and Y rotation auto-orient chose, and the
    /// position the object was placed at. sp_set_transform is absolute in every
    /// argument, so passing zeros for those would silently undo both.
    func setScaleAndRotation(scale: Double, rotateZ: Double) throws {
        let current = engine.transform() ?? [1, 0, 0, 0, 0, 0]
        try engine.setTransform(scale: scale, rotateX: current[1], rotateY: current[2],
                                rotateZ: rotateZ, translateX: current[4],
                                translateY: current[5])
    }

    func slice(overrides: Overrides, to url: URL,
               onProgress: @Sendable @escaping (Int, String) -> Bool) throws -> SliceStats? {
        try engine.setOverrides(overrides)
        try engine.slice(to: url, onProgress: onProgress)
        return engine.stats
    }

    /// One call for everything the view draws, so a redraw cannot mix geometry from
    /// two different engine states.
    func geometry(includeToolpath: Bool) -> PlateGeometry {
        PlateGeometry(
            bed: engine.bedOutline(),
            triangles: engine.meshTriangles(),
            toolpath: includeToolpath ? engine.toolpathSegments() : [],
            bounds: engine.objectCount > 0 ? engine.objectBounds() : nil
        )
    }

    var hasModel: Bool { engine.objectCount > 0 }
}
