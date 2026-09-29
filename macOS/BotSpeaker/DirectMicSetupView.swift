import AppKit
import SwiftUI

struct DirectMicSetupView: View {
    @State private var installed = AudioDeviceManager.deviceID(forUID: DirectMicPlayer.deviceUID) != nil
    @State private var message = ""

    private var installerURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("DirectMic Installer.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(installed ? "DirectMic is installed. Select DirectMic as the microphone in your meeting app." : "Install the bundled DirectMic driver, then select DirectMic as the microphone in your meeting app.")
                .font(.caption)
            HStack {
                Button(installed ? "Reinstall DirectMic…" : "Install DirectMic…") { install() }
                    .disabled(installerURL == nil)
                Button("Refresh status") { refresh() }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        installed = AudioDeviceManager.deviceID(forUID: DirectMicPlayer.deviceUID) != nil
    }

    private func install() {
        guard let url = installerURL else { return }
        message = "Follow the DirectMic installer’s instructions, then refresh status."
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in message = "Could not open the installer: \(error.localizedDescription)" }
            }
        }
    }
}
