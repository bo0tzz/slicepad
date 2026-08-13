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

    /// The refresh belongs to the model rather than to whichever view flipped the
    /// switch. It used to hang off an .onChange attached to a Picker inside a
    /// ToolbarItem — toolbar content is a separate hierarchy, and a modifier that
    /// quietly never fires is exactly how the Profile button came to do nothing.
    @Published var display: Display = .model {
        didSet {
            guard oldValue != display else { return }
            Task { await refreshGeometry() }
        }
    }
    @Published var geometry = PlateGeometry()

    /// The topmost layer the layer view draws. Everything below it is shown, which
    /// is what makes scrubbing look like watching the print go down rather than
    /// like inspecting one slice in isolation.
    @Published var topLayer: UInt32 = 0

    /// Whether a rotation settles onto the nearest flat face when the finger lifts.
    /// While it is on the rings do not snap to 15°: the target is a face, and a
    /// grid of angles only fights it.
    /// Written through by hand rather than with @AppStorage, which is built for
    /// views: inside an observable object it stores the value but publishes
    /// nothing, so the control would not follow its own state.
    @Published var snapToFace = UserDefaults.standard.bool(forKey: "snapToFace") {
        didSet { UserDefaults.standard.set(snapToFace, forKey: "snapToFace") }
    }

    var layerCount: Int { geometry.layerCount }
    var visibleLayers: ClosedRange<UInt32>? {
        guard display == .layers, geometry.layerCount > 0 else { return nil }
        return 0 ... topLayer
    }

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
    private var sliceGeneration = 0
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

    /// Called once when the app appears.
    func restoreProfile() {
        guard profileName == nil else { return }
        run { host in
            guard let profile = await host.restoreProfile() else { return }
            self.overrides = profile.settings
            self.profileName = ProfileStore.name
            self.profileVersionNote = Self.versionNote(profile.version)
            if profile.placedModel { self.modelGeneration += 1 }
            await self.refreshGeometry()
        }
    }

    private static func versionNote(_ version: String) -> String? {
        // A mismatch is normal — libslic3r migrates older profiles — so this is
        // worth showing but not worth blocking on.
        (version.isEmpty || version == Engine.configVersion)
            ? nil
            : "Saved by config \(version); engine uses \(Engine.configVersion)."
    }

    func loadProfile(_ url: URL) {
        run { host in
            let profile = try await host.loadProfile(at: url)
            let version = profile.version
            self.overrides = profile.settings
            if profile.placedModel { self.modelGeneration += 1 }
            self.profileName = url.deletingPathExtension().lastPathComponent
            self.profileVersionNote = Self.versionNote(version)
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

    /// Called when a drag on the plate finishes, with the object's new position in
    /// bed millimetres. Nothing is sent while the finger moves: the view slides the
    /// object itself, and the engine hears about it once.
    func moveObject(x: Double, y: Double) {
        run { host in
            try await host.setPosition(x: x, y: y)
            await self.refreshGeometry()
        }
    }

    /// Called when a rotation ring is released, with all three angles in degrees.
    /// The gizmo turns one axis at a time, but every argument of the engine's
    /// transform is absolute, so it sends the whole set.
    func rotateObject(x: Double, y: Double, z: Double) {
        // The inspector's stepper and the ring are two views of the same number.
        rotateZ = z
        run { host in
            try await host.setRotation(x: x, y: y, z: z)
            // Turned roughly by hand, then settled onto the face it was nearly on.
            // Done here rather than in the view because it changes all three angles,
            // and the engine is where they live.
            if self.snapToFace {
                await host.settleOnNearestFace()
                self.rotateZ = await host.rotationZ()
            }
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

        // Named after the model: an export lands in Files or a printer's queue
        // beside other jobs, where "slicepad.gcode" says nothing about which part
        // it is.
        let stem = modelName.map { ($0 as NSString).deletingPathExtension } ?? "slicepad"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(stem).appendingPathExtension("gcode")
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
                self.sliceGeneration += 1
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
        fresh.sliceGeneration = sliceGeneration
        geometry = fresh
        // A fresh slice shows the whole print; the control starts at the top and is
        // pulled down, rather than starting at nothing.
        if fresh.layerCount > 0 {
            topLayer = UInt32(fresh.layerCount - 1)
        }
    }

}
