import SwiftUI

struct Inspector: View {
    @ObservedObject var model: AppModel
    @Binding var importing: ContentView.ImportKind?

    var body: some View {
        Form {
            Section("Profile") {
                if let name = model.profileName {
                    LabeledContent("Loaded", value: name)
                    if let note = model.profileVersionNote {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Set profile…") { importing = .profile }
                }
            }

            if model.modelName != nil {
                Section("Model") {
                    LabeledContent("File", value: model.modelName ?? "")
                    if model.repairedErrors > 0 {
                        Label("Repaired \(model.repairedErrors) mesh defects",
                              systemImage: "bandage")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Scale") {
                        Stepper("\(Int(model.scale))%", value: $model.scale, in: 10 ... 500, step: 5)
                            .onChange(of: model.scale) { model.applyTransform() }
                    }
                    LabeledContent("Rotate Z") {
                        Stepper("\(Int(model.rotateZ))°", value: $model.rotateZ, in: -180 ... 180, step: 15)
                            .onChange(of: model.rotateZ) { model.applyTransform() }
                    }

                    HStack {
                        Button("Auto-orient") { model.autoOrient() }
                        Spacer()
                        Button("Arrange") { model.arrange() }
                    }
                    .buttonStyle(.bordered)
                }

                Section("Settings") {
                    LabeledContent("Walls") {
                        Stepper("\(model.overrides.wallLoops)",
                                value: $model.overrides.wallLoops, in: 1 ... 10)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Infill", value: "\(model.overrides.infillPercent)%")
                        Slider(value: Binding(
                            get: { Double(model.overrides.infillPercent) },
                            set: { model.overrides.infillPercent = Int($0) }
                        ), in: 0 ... 100, step: 5)
                    }
                    Toggle("Supports", isOn: $model.overrides.supports)
                }

                Section {
                    if model.isSlicing {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: model.progress) {
                                Text(model.stage).font(.footnote)
                            }
                            Button("Cancel", role: .destructive) { model.cancelSlice() }
                        }
                    } else {
                        Button("Slice") { model.slice() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canSlice)
                    }
                }

                if let stats = model.stats {
                    Section("Result") {
                        LabeledContent("Time", value: stats.formattedTime)
                        LabeledContent("Filament",
                                       value: String(format: "%.2f m · %.1f g",
                                                     stats.filament_mm / 1000, stats.filament_grams))
                        LabeledContent("Layers", value: "\(stats.layer_count)")
                        if let url = model.gcodeURL {
                            ShareLink("Export G-code", item: url)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Engine", value: "OrcaSlicer \(model.engineVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
