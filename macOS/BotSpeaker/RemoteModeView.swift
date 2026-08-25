import SwiftUI

struct RemoteModeView: View {
    let model: AppModel
    @Bindable var controller: OrchestrationController

    var body: some View {
        Group {
            if controller.activeMode == .remote {
                OrchestrationView(model: model, controller: controller, onExit: {})
            } else {
                setup
            }
        }
        .task { await model.loadVoicesIfNeeded() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Remote Mode", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.title2.bold())
                Text("Pair this Mac once, then leave it available while the host runs different meeting scripts.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("This speaker") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Name") {
                        TextField("Speaker name", text: $controller.speakerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }
                    LabeledContent("Output") {
                        Text(selectedDeviceName)
                            .foregroundStyle(selectedDeviceAvailable ? Color.primary : Color.orange)
                    }
                }
                .padding(8)
            }

            GroupBox("Pair with a host") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enter the six-character code once. BotSpeaker remembers this group across network interruptions and app relaunches until you disconnect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("Pairing code", text: $controller.pairingCodeInput)
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit(join)
                        Button(action: join) {
                            if controller.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Join Remote Group", systemImage: "link")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canJoin)
                    }

                    if let error = controller.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var canJoin: Bool {
        !controller.isBusy
            && controller.pairingCodeInput.count == 6
            && !controller.speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedDeviceName: String {
        model.devices.outputDevices.first(where: { $0.uid == model.selectedDeviceUID })?.name
            ?? "Output unavailable"
    }

    private var selectedDeviceAvailable: Bool {
        model.devices.outputDevices.contains(where: { $0.uid == model.selectedDeviceUID })
    }

    private func join() {
        guard canJoin else { return }
        controller.prepareRemoteSetup(preservePairingCode: true)
        Task { await controller.joinMeeting() }
    }
}
