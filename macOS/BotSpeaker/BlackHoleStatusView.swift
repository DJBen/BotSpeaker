import AppKit
import SwiftUI

/// Install/diagnose UI for BlackHole, shared by first run and Settings.
///
/// The common failure it exists for: the user installs BlackHole (often via
/// `brew install --cask blackhole-2ch`), the driver lands in the HAL folder, but
/// `coreaudiod` does not rescan that folder until it restarts — so no device ever
/// appears and the install looks like it silently failed.
struct BlackHoleStatusView: View {
    @ObservedObject var model: AppModel
    @State private var didCopyCommand = false

    private static let downloadURL = URL(string: "https://existential.audio/blackhole/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status and the refresh control share a row; any extra guidance stacks beneath.
            HStack(alignment: .firstTextBaseline) {
                statusLabel
                Spacer(minLength: 12)
                Button("Refresh Audio Devices") { refresh() }
            }

            if let message = model.deviceRefreshFeedback {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch model.devices.blackHoleStatus {
            case .active:
                EmptyView()

            case .installedButNotLoaded:
                Text("The driver is in the HAL plug-ins folder, but Core Audio only scans it at startup. Restart the audio daemon in Terminal, then refresh:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(AudioDeviceManager.coreAudioRestartCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Button(didCopyCommand ? "Copied" : "Copy") { copyCommand() }
                        .buttonStyle(.link)
                }
                Text("Audio drops out for a moment and apps reconnect to their devices. Restarting your Mac works too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .notInstalled(let driverFolderReadable):
                Link("Download BlackHole…", destination: Self.downloadURL)
                Text(driverFolderReadable
                     ? "Install BlackHole 2ch, then hit Refresh Audio Devices — no relaunch needed."
                     : "If you already installed it, hit Refresh Audio Devices for the exact next step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.devices.blackHoleStatus {
        case .active:
            Label("BlackHole detected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installedButNotLoaded:
            Label("Installed, but Core Audio hasn't loaded it", systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notInstalled(let driverFolderReadable):
            Label(
                driverFolderReadable ? "BlackHole is not installed" : "BlackHole not found",
                systemImage: "exclamationmark.circle"
            )
            .foregroundStyle(.orange)
        }
    }

    private func refresh() {
        didCopyCommand = false
        model.refreshAudioDevices()
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AudioDeviceManager.coreAudioRestartCommand, forType: .string)
        didCopyCommand = true
    }
}
