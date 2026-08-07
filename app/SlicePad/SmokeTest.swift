import Foundation

/// Drives one slice through the app's own engine wiring and exits.
///
/// This exists because launching the app proves less than it appears to: the
/// engine is created lazily, on the first profile or model load, so an app that
/// starts cleanly says nothing about `sp_engine_create`, the resources directory
/// inside the bundle, or the writable path under Application Support. Those are
/// exactly the parts that differ on iOS and cannot be checked anywhere else.
///
/// It runs only when SLICEPAD_SMOKE names a directory of fixtures, which a
/// sandboxed app has no way to set for itself — on a device this code is
/// unreachable. The alternative was a UI test, which would be slower, flakier,
/// and would still not say whether a slice came out right.
enum SmokeTest {
    static func runIfRequested() {
        guard let fixtures = ProcessInfo.processInfo.environment["SLICEPAD_SMOKE"] else { return }
        let directory = URL(fileURLWithPath: fixtures)

        do {
            let engine = try Engine()
            try engine.loadProfile(at: directory.appendingPathComponent("model.3mf"))
            // The raw export, so this covers the placement the app does on import
            // rather than a project that arrives already positioned.
            try engine.loadModel(at: directory.appendingPathComponent("model-shapr3d.3mf"))
            try engine.arrange()
            try engine.setOverrides(Overrides())

            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("smoke.gcode")
            var lastPercent = -1
            try engine.slice(to: output) { percent, _ in
                lastPercent = percent
                return true
            }

            guard let stats = engine.stats else {
                print("SMOKE FAIL: sliced but reported no statistics")
                exit(1)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
            let size = (attributes?[.size] as? Int) ?? 0

            print("SMOKE OK: \(stats.layer_count) layers, "
                  + "\(String(format: "%.1f", stats.filament_mm))mm filament, "
                  + "\(stats.formattedTime), \(size) bytes of G-code, "
                  + "last progress \(lastPercent)%")
            exit(0)
        } catch {
            print("SMOKE FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
