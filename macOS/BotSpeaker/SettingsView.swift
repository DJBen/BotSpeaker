import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var feedback: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("ElevenLabs") {
                SecureField(model.hasAPIKey ? "Enter a replacement key" : "Paste API key", text: $key)
                HStack {
                    Button(model.hasAPIKey ? "Replace Key" : "Save Key") { saveKey() }
                        .disabled(key.isEmpty || isSaving)
                    if model.hasAPIKey {
                        Label("Saved in Keychain", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            do { try model.removeAPIKey(); feedback = "API key removed." }
                            catch { feedback = error.localizedDescription }
                        }
                    }
                }
                VoicePicker(model: model)
                DisclosureGroup("Advanced voice settings") {
                    TextField("Voice ID", text: Binding(get: { model.voiceID }, set: { model.voiceID = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                TextField("Model ID", text: Binding(get: { model.modelID }, set: { model.modelID = $0 }))
            }

            Section("Audio routing") {
                Picker("Output device", selection: Binding(get: { model.selectedDeviceUID }, set: { model.selectedDeviceUID = $0 })) {
                    Text("Choose an output…").tag("")
                    ForEach(model.devices.outputDevices) { device in
                        Text(device.isBlackHole ? "\(device.name) — recommended" : device.name).tag(device.uid)
                    }
                }
                Picker("Interruption input", selection: Binding(get: { model.interruptionInputUID }, set: { model.interruptionInputUID = $0 })) {
                    ForEach(model.devices.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                HStack {
                    Button("Refresh Devices") { model.devices.refresh() }
                    Spacer()
                    Button("Install BlackHole…") {
                        NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!)
                    }
                }
                Text("In Zoom, Meet, or Teams, select the same BlackHole device as your microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Interruption detection learns the ambient level, pauses immediately after 0.4 seconds of elevated input, and resumes after 0.75 seconds back at ambient. Direct BlackHole output or headphones prevent Bot Speaker from detecting its own voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.interruptionMonitor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 390)
        .padding()
        .task { await model.loadVoicesIfNeeded() }
    }

    private func saveKey() {
        isSaving = true
        feedback = nil
        Task {
            do {
                try await model.validateAndSaveAPIKey(key)
                key = ""
                feedback = "API key validated and saved."
            } catch {
                feedback = error.localizedDescription
            }
            isSaving = false
        }
    }
}
