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

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                plate
                Divider()
                Inspector(model: model, setProfile: { startImport(.profile) })
                    .frame(width: 320)
            }
            .navigationTitle("SlicePad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Profile", systemImage: "slider.horizontal.3") { startImport(.profile) }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Open Model", systemImage: "cube") { startImport(.model) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $model.display) {
                        ForEach(AppModel.Display.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.modelName == nil)
                    .onChange(of: model.display) { model.displayChanged() }
                }
            }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: importKind.types) { result in
            guard case let .success(url) = result else { return }
            switch importKind {
            case .profile: model.loadProfile(url)
            case .model: model.loadModel(url)
            }
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
            PlateView(geometry: model.geometry, display: model.display)
        }
    }
}
