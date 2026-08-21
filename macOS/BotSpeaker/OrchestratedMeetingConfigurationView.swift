import SwiftUI

struct OrchestratedMeetingConfigurationView: View {
    let model: AppModel
    let controller: OrchestrationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Orchestrated Meeting", systemImage: "person.3.sequence.fill")
                    .font(.title2.bold())
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Settings")
            }

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
                    openWindow(id: "orchestrator")
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
    }

    private func speakerRow(configuration: OrchestratedSpeakerConfiguration) -> some View {
        let availableVoices: [ElevenLabsVoice] = model.voices
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.placeholder).font(.caption.monospaced())
                Text(configuration.role).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)

            OrchestratedSpeakerNameEditor(
                name: configuration.name,
                onCommit: { controller.updateConfiguredSpeakerName(slot: configuration.slot, name: $0) }
            )
            .id("\(controller.selectedTemplate.id):\(configuration.slot)")
            .frame(minWidth: 100, idealWidth: 170, maxWidth: .infinity)

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
}

private struct OrchestratedSpeakerNameEditor: View {
    let name: String
    let onCommit: (String) -> Void
    @State private var draftName: String
    @FocusState private var isFocused: Bool

    init(name: String, onCommit: @escaping (String) -> Void) {
        self.name = name
        self.onCommit = onCommit
        _draftName = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Speaker name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(height: 28)
                .focused($isFocused)
                .onSubmit(commit)

            Button(action: commit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .background(hasPendingChange ? Color.accentColor : Color.secondary.opacity(0.35), in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help("Apply speaker name")
            .disabled(!hasPendingChange)
            .opacity(isFocused ? 1 : 0)
            .allowsHitTesting(isFocused)
            .accessibilityHidden(!isFocused)
        }
        .onChange(of: name) { _, newName in
            if !isFocused { draftName = newName }
        }
    }

    private var hasPendingChange: Bool {
        draftName != name
    }

    private func commit() {
        guard hasPendingChange else { return }
        onCommit(draftName)
        isFocused = false
    }
}
