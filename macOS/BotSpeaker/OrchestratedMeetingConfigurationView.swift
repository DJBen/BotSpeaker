import SwiftUI

struct OrchestratedMeetingConfigurationView: View {
    let model: AppModel
    @Bindable var controller: OrchestrationController
    let onPrepareMeeting: () -> Void
    @State private var editingSpeakerSlot: Int?
    @State private var draftSpeakerName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.selectedTemplate.title)
                    .font(.headline)
                Text("Name the speakers and choose the ElevenLabs voice each paired client will use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Speakers") {
                VStack(spacing: 10) {
                    ForEach(controller.speakerConfigurations) { configuration in
                        speakerRow(configuration: configuration)
                        if configuration.id != controller.speakerConfigurations.last?.id { Divider() }
                    }
                }
                .padding(6)
            }

            GroupBox("Script preview") {
                ScrollView {
                    Text(controller.configuredScriptPreview)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 180)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
                .padding(6)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.isHost
                        ? "Use the active host group with this \(controller.selectedTemplate.speakerCount)-speaker script."
                        : "Start Host Meeting from the title bar before opening this script.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let error = controller.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button {
                    openHostedMeeting()
                } label: {
                    if controller.isBusy && controller.setupMode == .host {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            controller.isHost
                                ? controller.sessionStatus == .completed || controller.sessionStatus == .stopped
                                    ? "Use for Next Run"
                                    : "Use This Script"
                                : "Start Host Meeting First",
                            systemImage: "arrow.right.circle.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(controller.isBusy || !controller.isHost)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await model.loadVoicesIfNeeded()
            controller.applyDefaultTemplateVoices()
        }
        .alert("Edit Speaker Name", isPresented: isEditingSpeakerName) {
            TextField("Speaker name", text: $draftSpeakerName)
            Button("Cancel", role: .cancel) {
                editingSpeakerSlot = nil
            }
            Button("Save", action: saveSpeakerName)
                .disabled(draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Replaces the placeholder throughout the script.")
        }
    }

    private func speakerRow(configuration: OrchestratedSpeakerConfiguration) -> some View {
        let availableVoices: [ElevenLabsVoice] = model.voices
        return HStack(spacing: 12) {
            Button {
                draftSpeakerName = configuration.name
                editingSpeakerSlot = configuration.slot
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit speaker name")

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.name.isEmpty ? configuration.placeholder : configuration.name)
                    .font(configuration.name.isEmpty ? .body.monospaced() : .body.weight(.semibold))
                Text(configuration.role)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 160, idealWidth: 210, alignment: .leading)

            Spacer(minLength: 24)

            Picker(
                "Voice",
                selection: Binding<String>(
                    get: {
                        controller.speakerConfigurations.first(where: { $0.slot == configuration.slot })?.voiceID
                            ?? configuration.voiceID
                    },
                    set: { controller.updateConfiguredVoice(slot: configuration.slot, voiceID: $0) }
                )
            ) {
                if !availableVoices.contains(where: { $0.id == configuration.voiceID }) {
                    Text(configuration.voiceName).tag(configuration.voiceID)
                }
                ForEach(availableVoices) { voice in
                    Text(voice.detail.isEmpty ? voice.name : "\(voice.name) — \(voice.detail)")
                        .tag(voice.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 260, idealWidth: 480, maxWidth: 720, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isEditingSpeakerName: Binding<Bool> {
        Binding(
            get: { editingSpeakerSlot != nil },
            set: { isPresented in
                if !isPresented { editingSpeakerSlot = nil }
            }
        )
    }

    private func saveSpeakerName() {
        guard let slot = editingSpeakerSlot else { return }
        let name = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        controller.updateConfiguredSpeakerName(slot: slot, name: name)
        editingSpeakerSlot = nil
    }

    private func openHostedMeeting() {
        Task {
            await controller.useSelectedTemplateInHostedGroup()
            if controller.isActive { onPrepareMeeting() }
        }
    }
}
