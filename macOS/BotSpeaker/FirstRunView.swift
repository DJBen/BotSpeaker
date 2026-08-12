import AppKit
import SwiftUI

struct FirstRunView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
            Text("Set up Bot Speaker")
                .font(.title2.bold())
            Text("Turn text into speech and send it directly to a virtual meeting microphone.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("1. ElevenLabs API key").font(.headline)
                SecureField("Paste API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Text("Stored securely in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("2. BlackHole").font(.headline)
                if model.devices.outputDevices.contains(where: \ .isBlackHole) {
                    Label("BlackHole detected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("BlackHole is not installed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Link("Download BlackHole…", destination: URL(string: "https://existential.audio/blackhole/")!)
                    Text("Install BlackHole 2ch, then relaunch Bot Speaker or refresh the audio devices in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
                Button {
                    isSaving = true
                    error = nil
                    Task {
                        do { try await model.validateAndSaveAPIKey(key) }
                        catch { self.error = error.localizedDescription }
                        isSaving = false
                    }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Validate & Continue") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(20)
    }
}
