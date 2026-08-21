import SwiftUI

struct OrchestratedMeetingConfigurationView: View {
    let model: AppModel
    let controller: OrchestrationController
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
                Text("You’ll pair and assign \(controller.selectedTemplate.speakerCount) clients in the setup window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.prepareHostSetup()
                    onPrepareMeeting()
                } label: {
                    Label("Prepare Meeting", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
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
                    .font(configuration.name.isEmpty ? .caption.monospaced() : .caption)
                Text(configuration.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 130, idealWidth: 170, alignment: .leading)

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
            .frame(minWidth: 170, idealWidth: 260, maxWidth: .infinity)
        }
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
}
