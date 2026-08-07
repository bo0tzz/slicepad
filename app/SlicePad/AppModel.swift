import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Display: String, CaseIterable, Identifiable {
        case model = "Model"
        case layers = "Layers"
        var id: String { rawValue }
    }

    @Published var profileName: String?
    @Published var profileVersionNote: String?
    @Published var modelName: String?
    @Published var repairedErrors = 0

    @Published var overrides = Overrides()
    @Published var scale: Double = 100      // percent, as the desktop shows it
    @Published var rotateZ: Double = 0

    @Published var display: Display = .model
    @Published var geometry = PlateGeometry()

    @Published var isSlicing = false
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var stats: SliceStats?
    @Published var gcodeURL: URL?
    @Published var error: String?

    /// Written from the main actor, read from the slicing thread, so it cannot be
    /// ordinary actor-isolated state — the progress callback runs wherever the
    /// engine is slicing.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private var host: EngineHost?
    private var cancelFlag = CancelFlag()

    var canSlice: Bool { profileName != nil && modelName != nil && !isSlicing }
    var engineVersion: String { Engine.version }

    private func engine() throws -> EngineHost {
        if let host { return host }
        let created = try EngineHost()
        host = created
        return created
    }

    /// Every engine call goes through here so failures land in one place: the
    /// engine reports them as messages meant to be read, not codes to map.
    private func run(_ work: @escaping (EngineHost) async throws -> Void) {
        Task {
            do {
                try await work(try engine())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func loadProfile(_ url: URL) {
        run { host in
            let version = try await host.loadProfile(at: url)
            self.profileName = url.deletingPathExtension().lastPathComponent
            // A mismatch is normal — libslic3r migrates older profiles — so this is
            // worth showing but not worth blocking on.
            self.profileVersionNote = (version.isEmpty || version == Engine.configVersion)
                ? nil
                : "Saved by config \(version); engine uses \(Engine.configVersion)."
            await self.refreshGeometry()
        }
    }

    func loadModel(_ url: URL) {
        run { host in
            self.repairedErrors = try await host.loadModel(at: url)
            self.modelName = url.lastPathComponent
            self.scale = 100
            self.rotateZ = 0
            self.stats = nil
            self.gcodeURL = nil
            self.display = .model
            await self.refreshGeometry()
        }
    }

    func autoOrient() {
        run { host in
            try await host.autoOrient()
            self.rotateZ = 0
            await self.refreshGeometry()
        }
    }

    func arrange() {
        run { host in
            try await host.arrange()
            await self.refreshGeometry()
        }
    }

    func applyTransform() {
        run { host in
            try await host.setTransform(scale: self.scale / 100, rotateX: 0, rotateY: 0,
                                        rotateZ: self.rotateZ, translateX: 0, translateY: 0)
            await self.refreshGeometry()
        }
    }

    func slice() {
        guard canSlice else { return }
        isSlicing = true
        progress = 0
        stage = "Starting"
        cancelFlag = CancelFlag()
        stats = nil

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("slicepad.gcode")
        let overrides = overrides
        let cancelFlag = cancelFlag

        run { host in
            defer { self.isSlicing = false }
            do {
                let stats = try await host.slice(overrides: overrides, to: output) { percent, stage in
                    Task { @MainActor in
                        self.progress = Double(percent) / 100
                        self.stage = stage
                    }
                    return !cancelFlag.isSet
                }
                self.stats = stats
                self.gcodeURL = output
                self.display = .layers
                await self.refreshGeometry()
            } catch let error as EngineError where error.code == SP_ERR_CANCELLED {
                self.stage = "Cancelled"
            }
        }
    }

    func cancelSlice() { cancelFlag.isSet = true }

    private func refreshGeometry() async {
        guard let host else { return }
        geometry = await host.geometry(includeToolpath: display == .layers)
    }

    func displayChanged() {
        Task { await refreshGeometry() }
    }
}
