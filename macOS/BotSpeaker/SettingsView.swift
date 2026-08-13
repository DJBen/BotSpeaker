import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var feedback: String?
    @State private var keyEditorError: String?
    @State private var isSaving = false
    @State private var isShowingKeyEditor = false
    @FocusState private var isKeyFieldFocused: Bool

    var body: some View {
        Form {
            Section("ElevenLabs") {
                HStack {
                    if model.hasAPIKey {
                        Label("Saved in Keychain", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("API key not configured", systemImage: "key.slash")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.hasAPIKey ? "Replace API Key…" : "Add API Key…") {
                        key = ""
                        keyEditorError = nil
                        isShowingKeyEditor = true
                    }
                    .popover(isPresented: $isShowingKeyEditor, arrowEdge: .trailing) {
                        apiKeyEditor
                    }
                }
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
                BlackHoleStatusView(model: model)
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

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.hasAPIKey ? "Replace ElevenLabs API Key" : "Add ElevenLabs API Key")
                .font(.headline)
            Text("The key is validated with ElevenLabs, then stored securely in your macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Paste API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($isKeyFieldFocused)
                .onSubmit(saveKey)

            if let keyEditorError {
                Label(keyEditorError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.hasAPIKey {
                    Button("Remove Key", role: .destructive) { removeKey() }
                }
                Spacer()
                Button("Cancel") {
                    isShowingKeyEditor = false
                    key = ""
                }
                Button(isSaving ? "Validating…" : "Save Key") { saveKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { isKeyFieldFocused = true }
    }

    private func saveKey() {
        guard !isSaving else { return }
        isSaving = true
        keyEditorError = nil
        Task {
            do {
                try await model.validateAndSaveAPIKey(key)
                key = ""
                feedback = "API key validated and saved."
                isShowingKeyEditor = false
            } catch {
                keyEditorError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func removeKey() {
        do {
            try model.removeAPIKey()
            feedback = "API key removed."
            key = ""
            isShowingKeyEditor = false
        } catch {
            keyEditorError = error.localizedDescription
        }
    }
}
