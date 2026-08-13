import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()

    /// Setting the profile and opening a model are separate actions on purpose:
    /// both arrive as .3mf, and guessing which one you meant from the file would be
    /// wrong exactly when it matters.
    ///
    /// One importer, though, not two. SwiftUI keeps a single file-importer
    /// presentation per view, so attaching two puts the second in the first's
    /// place — the Profile button set a flag nothing was listening to, and did
    /// visibly nothing. The kind lives in its own state rather than in the
    /// presentation binding, so the completion handler can still read it after
    /// dismissal has torn the presentation down.
    @State private var isImporting = false
    @State private var importKind: ImportKind = .profile

    /// A file handed to us by another app. A .3mf could be either thing, and the
    /// app does not guess between them anywhere else, so it asks here too.
    @State private var offered: URL?

    enum ImportKind {
        case profile, model

        var types: [UTType] {
            switch self {
            case .profile: return [ContentView.threeMF]
            case .model: return ContentView.modelTypes
            }
        }
    }

    private func startImport(_ kind: ImportKind) {
        importKind = kind
        isImporting = true
    }

    private static let threeMF = UTType(filenameExtension: "3mf") ?? .data
    private static let modelTypes = [
        threeMF,
        UTType(filenameExtension: "stl") ?? .data,
        UTType(filenameExtension: "obj") ?? .data,
    ]

    // No NavigationStack and no toolbar. This is one screen that never navigates,
    // so a navigation bar only contributed a second bar behind the controls — and
    // toolbar content is a separate view hierarchy, which is what made the Profile
    // button do nothing and would have stopped the Model/Layers switch redrawing.
    // Ordinary views in the layout cannot fail either way.
    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                plate
                if model.modelName != nil {
                    Picker("View", selection: $model.display) {
                        ForEach(AppModel.Display.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .padding(.top, 12)
                }
            }
            Divider()
            Inspector(model: model,
                      setProfile: { startImport(.profile) },
                      openModel: { startImport(.model) })
                .frame(width: 320)
        }
        .onOpenURL { url in
            // Only .3mf is ambiguous; a mesh format can only be a model.
            if url.pathExtension.lowercased() == "3mf" {
                offered = url
            } else {
                model.loadModel(url)
            }
        }
        .confirmationDialog("Open \(offered?.lastPathComponent ?? "")",
                            isPresented: Binding(get: { offered != nil },
                                                 set: { if !$0 { offered = nil } }),
                            titleVisibility: .visible) {
            Button("Open as a model") {
                if let offered { model.loadModel(offered) }
            }
            Button("Use as the profile") {
                if let offered { model.loadProfile(offered) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A project saved by Orca sets the profile. Anything else is a model.")
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: importKind.types) { result in
            guard case let .success(url) = result else { return }
            switch importKind {
            case .profile: model.loadProfile(url)
            case .model: model.loadModel(url)
            }
        }
        // Same hook as the smoke test, for the same reason and with the same
        // reach: a sandboxed app cannot set its own environment, so this is dead
        // code on a device. It exists so a screenshot can show the plate with a
        // model on it — the 3D view is the one part nothing else can check.
        .task {
            model.restoreProfile()

            guard let fixtures = ProcessInfo.processInfo.environment["SLICEPAD_PRELOAD"] else { return }
            let directory = URL(fileURLWithPath: fixtures)
            model.loadProfile(directory.appendingPathComponent("model.3mf"))
            model.loadModel(directory.appendingPathComponent("model-shapr3d.3mf"))

            // And slice, when asked, so a screenshot can show the layer view. Both
            // loads are asynchronous, so this waits for them rather than assuming
            // they have landed.
            guard ProcessInfo.processInfo.environment["SLICEPAD_PRELOAD_SLICE"] != nil else { return }
            for _ in 0 ..< 100 {
                if model.canSlice { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            model.slice()
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil },
                                                            set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder private var plate: some View {
        if model.modelName == nil {
            ContentUnavailableView {
                Label("Nothing on the plate", systemImage: "cube.transparent")
            } description: {
                Text(model.profileName == nil
                     ? "Set a profile exported from desktop Orca, then open a model."
                     : "Open a model to slice.")
            }
        } else {
            PlateView(geometry: model.geometry, display: model.display,
                      visibleLayers: model.visibleLayers,
                      onMove: { x, y in model.moveObject(x: x, y: y) },
                      rotationDegrees: model.rotateZ,
                      onRotate: { degrees in
                          model.rotateZ = degrees
                          model.applyTransform()
                      })
        }
    }
}
