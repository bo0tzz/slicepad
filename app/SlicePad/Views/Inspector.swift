import SwiftUI

struct Inspector: View {
    @ObservedObject var model: AppModel
    /// Closures rather than bindings: one view owns the file importer, and these
    /// are just other ways to ask it for something.
    let setProfile: () -> Void
    let openModel: () -> Void

    @AppStorage("printerAddress") private var printerAddress = ""
    @AppStorage("startAfterUpload") private var startAfterUpload = false
    // Not in the keychain: Moonraker on a LAN, and a key that only reaches the
    // printer. Worth revisiting if this ever speaks to anything routable.
    @AppStorage("printerKey") private var printerKey = ""

    var body: some View {
        Form {
            // Both files are asked for here, and separately: they are different
            // things that arrive in the same format, so the app never guesses which
            // one you meant from what you picked.
            Section("Profile") {
                if let name = model.profileName {
                    LabeledContent("Loaded", value: name)
                    if let note = model.profileVersionNote {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Change profile…") { setProfile() }
                } else {
                    Button("Set profile…") { setProfile() }
                    Text("A project saved from desktop Orca — File → Save Project As.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if model.modelName == nil {
                Section("Model") {
                    Button("Open model…") { openModel() }
                    Text("A .3mf, .stl or .obj — a Shapr3D export works directly.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if model.modelName != nil {
                Section("Model") {
                    LabeledContent("File", value: model.modelName ?? "")
                    Button("Open another…") { openModel() }
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

                    Toggle("Settle on a flat face", isOn: $model.snapToFace)
                    if model.snapToFace {
                        Text("Turn the part roughly; it drops onto the nearest flat "
                             + "face when you let go.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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

            // Shown before there is anything to send, so the address can be
            // typed once rather than discovered as a missing step after the
            // first slice.
            Section("Printer") {
                TextField("http://printer.local", text: $printerAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("API key (optional)", text: $printerKey)
                Toggle("Start printing after upload", isOn: $startAfterUpload)

                if model.isSending {
                    HStack {
                        ProgressView()
                        Text(model.sendState ?? "").font(.footnote)
                    }
                } else {
                    Button("Send to printer") {
                        model.send(to: printerAddress, apiKey: printerKey,
                                   startPrint: startAfterUpload)
                    }
                    .disabled(printerAddress.isEmpty || model.gcodeURL == nil)
                    // A greyed-out button with nothing beside it is a dead end,
                    // and this section is visible before there is anything to
                    // send — so it says which of the two is missing.
                    if let state = model.sendState {
                        Text(state).font(.footnote).foregroundStyle(.secondary)
                    } else if model.gcodeURL == nil {
                        Text("Slice first — there is nothing to send yet.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if printerAddress.isEmpty {
                        Text("Enter your printer's address above.")
                            .font(.footnote).foregroundStyle(.secondary)
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
