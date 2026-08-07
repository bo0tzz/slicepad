import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var importing: ImportKind?

    /// Setting the profile and opening a model are separate actions on purpose:
    /// both arrive as .3mf, and guessing which one you meant from the file would be
    /// wrong exactly when it matters.
    enum ImportKind: Identifiable {
        case profile, model
        var id: Int { self == .profile ? 0 : 1 }

        var types: [UTType] {
            switch self {
            case .profile: return [UTType(filenameExtension: "3mf") ?? .data]
            case .model: return [UTType(filenameExtension: "3mf") ?? .data,
                                 UTType(filenameExtension: "stl") ?? .data,
                                 UTType(filenameExtension: "obj") ?? .data]
            }
        }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                plate
                Divider()
                Inspector(model: model, importing: $importing)
                    .frame(width: 320)
            }
            .navigationTitle("SlicePad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Profile", systemImage: "slider.horizontal.3") { importing = .profile }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Open Model", systemImage: "cube") { importing = .model }
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
        .fileImporter(isPresented: Binding(get: { importing != nil },
                                          set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing?.types ?? [.data]) { result in
            let kind = importing
            importing = nil
            guard case let .success(url) = result else { return }
            if kind == .profile { model.loadProfile(url) } else { model.loadModel(url) }
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
