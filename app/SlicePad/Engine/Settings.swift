import Foundation

// Split out from Engine.swift because none of it touches the engine: these are
// the values that cross between a profile, the controls and a slice. Keeping them
// free of the C module is what lets them be tested by running them — see
// app/Tests, which compiles this file natively and checks the parsing.

struct SliceStats: Decodable {
    let estimated_seconds: Double
    let filament_mm: Double
    let filament_grams: Double
    let layer_count: Int
    let travel_mm: Double
    let object_count: Int

    var formattedTime: String {
        let total = Int(estimated_seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? "\(h)h \(m)m" : (m > 0 ? "\(m)m \(s)s" : "\(s)s")
    }
}

/// The three things this app lets you change. Everything else comes from the
/// profile you authored in desktop Orca.
struct Overrides: Equatable {
    var wallLoops: Int = 2
    var infillPercent: Int = 15
    var supports: Bool = false

    /// Seeded from the loaded profile rather than from defaults of our own. These
    /// are sent on every slice, so a control sitting at a value the profile never
    /// asked for does not read as "unchanged" — it silently overrides.
    init(from config: [String: String] = [:]) {
        wallLoops = config["wall_loops"].flatMap(Int.init) ?? wallLoops
        infillPercent = config["sparse_infill_density"]
            .map { $0.replacingOccurrences(of: "%", with: "") }
            .flatMap { Int($0) ?? Double($0).map(Int.init) } ?? infillPercent
        supports = config["enable_support"].map { $0 == "1" || $0 == "true" } ?? supports
    }

    /// A fragment of an Orca preset, which is what `sp_set_overrides` consumes —
    /// so these keys are Orca's own names, not an encoding of ours.
    var json: String {
        """
        {"wall_loops": "\(wallLoops)", \
        "sparse_infill_density": "\(infillPercent)%", \
        "enable_support": "\(supports ? 1 : 0)"}
        """
    }
}
