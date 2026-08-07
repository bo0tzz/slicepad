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
    private var modelGeneration = 0
    private var transformToken = 0

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
            let profile = try await host.loadProfile(at: url)
            let version = profile.version
            self.overrides = profile.settings
            if profile.placedModel { self.modelGeneration += 1 }
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
            self.modelGeneration += 1
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
            // Auto-orient rewrites the rotation entirely, so the Z control has to
            // follow it rather than assert a value of its own.
            self.rotateZ = await host.rotationZ()
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
        // Each tap of a stepper starts a Task, and Tasks are not guaranteed to run
        // in the order they were created — so a slower one carrying an older scale
        // could land after a newer one and leave the model at a value the controls
        // no longer show. Only the most recent request is worth performing.
        transformToken += 1
        let token = transformToken

        run { host in
            guard token == self.transformToken else { return }
            try await host.setScaleAndRotation(scale: self.scale / 100, rotateZ: self.rotateZ)
            await self.refreshGeometry()
        }
    }

    func slice() {
        guard canSlice else { return }
        progress = 0
        stage = "Starting"
        cancelFlag = CancelFlag()
        stats = nil

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("slicepad.gcode")
        let overrides = overrides
        let cancelFlag = cancelFlag

        // Raised here rather than before the call: creating the engine can fail, and
        // that path never enters this closure — which would leave the button
        // spinning on a slice that never started.
        run { host in
            self.isSlicing = true
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
            } catch let error as EngineError where error.isCancellation {
                self.stage = "Cancelled"
            }
        }
    }

    func cancelSlice() { cancelFlag.isSet = true }

    // MARK: Printer

    @Published var sendState: String?
    @Published var isSending = false

    func send(to address: String, apiKey: String, startPrint: Bool) {
        guard let gcode = gcodeURL else { return }
        guard let url = Moonraker.address(from: address) else {
            error = "\"\(address)\" is not an address I can reach."
            return
        }

        let name = (modelName.map { ($0 as NSString).deletingPathExtension } ?? "slicepad") + ".gcode"
        let printer = Moonraker(host: url, apiKey: apiKey.isEmpty ? nil : apiKey)

        isSending = true
        sendState = "Connecting"
        Task {
            defer { isSending = false }
            guard await printer.reachable() else {
                isSending = false
                error = "Could not reach the printer at \(address)."
                sendState = nil
                return
            }
            do {
                sendState = "Uploading"
                let result = try await printer.upload(gcode, as: name)
                if startPrint {
                    try await printer.startPrint(path: result.path)
                    sendState = "Printing \(result.path)"
                } else {
                    sendState = "Uploaded \(result.path)"
                }
            } catch {
                self.error = error.localizedDescription
                sendState = nil
            }
        }
    }

    private func refreshGeometry() async {
        guard let host else { return }
        var fresh = await host.geometry(includeToolpath: display == .layers)
        fresh.revision = geometry.revision + 1
        fresh.modelGeneration = modelGeneration
        geometry = fresh
    }

    func displayChanged() {
        Task { await refreshGeometry() }
    }
}
