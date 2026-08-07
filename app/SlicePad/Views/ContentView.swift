import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()

    /// Setting the profile and opening a model are separate actions on purpose:
    /// both arrive as .3mf, and guessing which one you meant from the file would be
    /// wrong exactly when it matters. Two flags rather than one enum, so the
    /// completion handler cannot read a selection that dismissal has already
    /// cleared.
    @State private var importingProfile = false
    @State private var importingModel = false

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
                Inspector(model: model, importingProfile: $importingProfile)
                    .frame(width: 320)
            }
            .navigationTitle("SlicePad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Profile", systemImage: "slider.horizontal.3") { importingProfile = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Open Model", systemImage: "cube") { importingModel = true }
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
        .fileImporter(isPresented: $importingProfile,
                      allowedContentTypes: [Self.threeMF]) { result in
            if case let .success(url) = result { model.loadProfile(url) }
        }
        .fileImporter(isPresented: $importingModel,
                      allowedContentTypes: Self.modelTypes) { result in
            if case let .success(url) = result { model.loadModel(url) }
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
