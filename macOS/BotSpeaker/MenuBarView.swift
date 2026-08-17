import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.hasAPIKey {
                ComposerView(model: model, player: model.player, context: .menuBar)
            } else {
                FirstRunView(model: model)
            }
        }
        .frame(width: 440)
        .task { await model.loadVoicesIfNeeded() }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @State private var isShowingScriptEditor = false
    @State private var isSidebarVisible = true

    var body: some View {
        Group {
            if model.hasAPIKey {
                HStack(spacing: 0) {
                    if isSidebarVisible {
                        ScriptLibrarySidebar(
                            model: model,
                            onAdd: {
                                model.prepareNewScript()
                                isShowingScriptEditor = true
                            },
                            onEdit: {
                                model.prepareScriptEditor()
                                isShowingScriptEditor = true
                            },
                            onToggleSidebar: toggleSidebar
                        )
                        .frame(width: 310)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        Divider()
                    }

                    ComposerView(
                        model: model,
                        player: model.player,
                        context: .mainWindow,
                        onToggleSidebar: toggleSidebar,
                        showsSidebarToggle: !isSidebarVisible
                    )
                }
            } else {
                FirstRunView(model: model)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .task { await model.loadVoicesIfNeeded() }
        .sheet(isPresented: $isShowingScriptEditor) {
            CustomScriptEditorSheet(model: model)
        }
        .onKeyPress(.space) {
            guard model.hasAPIKey,
                  model.selectedScript.isCustom,
                  !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(model.isGenerating && !model.player.hasAudio) else {
                return .ignored
            }
            Task { await model.primaryAction() }
            return .handled
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isSidebarVisible.toggle()
        }
    }
}

private struct ScriptLibrarySidebar: View {
    @ObservedObject var model: AppModel
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onToggleSidebar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scripts")
                        .font(.title2.bold())
                    Text("Incident review cast")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add a custom script")
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .disabled(!model.selectedScript.isCustom)
                .help(model.selectedScript.isCustom ? "Edit selected script" : "Create a named copy before editing")
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("Hide scripts")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            List(selection: scriptSelection) {
                Section("Role templates") {
                    ForEach(model.bundledScripts) { script in
                        ScriptRow(script: script, icon: "person.text.rectangle")
                            .tag(script.id)
                    }
                }

                Section("My scripts") {
                    if model.customScripts.isEmpty {
                        Text("Create a named role or add your own script.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(model.availableScripts.filter(\.isCustom)) { script in
                            ScriptRow(script: script, icon: "waveform")
                                .tag(script.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(SidebarVisualEffect())
    }

    private var scriptSelection: Binding<String?> {
        Binding(
            get: { model.selectedScriptID },
            set: { id in
                guard let id else { return }
                model.selectScript(id: id)
            }
        )
    }
}

private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ScriptRow: View {
    let script: SpeechScript
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.title)
                    .lineLimit(1)
                Text("\(script.detail) · \(script.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: icon)
        }
        .padding(.vertical, 3)
    }
}

struct ComposerView: View {
    enum Context {
        case mainWindow
        case menuBar
    }

    @ObservedObject var model: AppModel
    @ObservedObject var player: AudioPlaybackController
    let context: Context
    var onToggleSidebar: (() -> Void)? = nil
    var showsSidebarToggle = false
    @Environment(\.openWindow) private var openWindow
    @State private var sliderValue = 0.0
    @State private var isScrubbing = false
    @State private var templateError: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                if showsSidebarToggle, let onToggleSidebar {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.plain)
                    .help("Show or hide scripts")
                }
                Label("Bot Speaker", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Settings")
            }

            scriptHeader

            if !model.selectedScript.isCustom {
                if context == .mainWindow {
                    templateNameEntry
                } else {
                    Label(
                        "Open the full app to create a named script before playback.",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VoicePicker(model: model)

            HighlightedTextEditor(
                text: .constant(model.text),
                playedTextLength: player.playedTextLength,
                activeTextRange: player.activeTextRange,
                isEditable: false
            )
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .frame(minHeight: 220)

            HStack(spacing: 12) {
                AnnotationKey(color: .green.opacity(0.35), label: "Spoken")
                AnnotationKey(color: .accentColor.opacity(0.55), label: "Speaking")
                Spacer()
                if model.isGenerating {
                    ProgressView(
                        value: Double(player.generatedChunkCount),
                        total: Double(max(player.totalChunkCount, 1))
                    )
                    .frame(width: 70)
                    Text("Generating \(player.generatedChunkCount)/\(player.totalChunkCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            timeline
            playbackControls

            if model.interruptionMonitor.isHearingAudio || player.isWaitingForInterruption {
                HStack(spacing: 6) {
                    Image(systemName: "ear.fill")
                    Text(player.isWaitingForInterruption ? "Paused for an interruption" : "Interruption detected")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Circle()
                    .fill(model.devices.outputDevices.contains(where: { $0.uid == model.selectedDeviceUID }) ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(selectedDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if context == .menuBar {
                    Button("Open Full App") { openWindow(id: "composer") }
                        .buttonStyle(.plain)
                        .font(.caption)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }
        }
        .padding(16)
    }

    private var templateNameEntry: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Speaker name", systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .leading)

                TextField("Enter a name", text: $model.templateSpeakerName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createNamedScript)

                Button("Create Script", action: createNamedScript)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.templateSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let templateError {
                    Label(templateError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("Replaces {{name}} once and creates an independent, playable copy.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.leading, 112)
        }
    }

    private func createNamedScript() {
        do {
            try model.createNamedScriptFromSelectedTemplate()
            templateError = nil
        } catch {
            templateError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var scriptHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedScript.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(model.selectedScript.detail) · \(model.selectedScript.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if context == .menuBar {
                Menu {
                    if model.customScripts.isEmpty {
                        Button("Create a named script in the full app") {
                            openWindow(id: "composer")
                        }
                    } else {
                        ForEach(model.availableScripts.filter(\.isCustom)) { script in
                            Button {
                                model.selectScript(id: script.id)
                            } label: {
                                if script.id == model.selectedScriptID {
                                    Label(script.title, systemImage: "checkmark")
                                } else {
                                    Text(script.title)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Choose", systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .help("Choose a saved script")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? sliderValue : player.currentTime },
                    set: { sliderValue = $0 }
                ),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { try? player.seek(to: sliderValue) }
                }
            )
            .disabled(!player.hasAudio)

            HStack {
                Text(TimeDisplay.format(isScrubbing ? sliderValue : player.currentTime))
                Spacer()
                Text("−" + TimeDisplay.format(max(player.duration - (isScrubbing ? sliderValue : player.currentTime), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button { model.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(!player.hasAudio && !model.isGenerating)

            Button {
                Task { await model.primaryAction() }
            } label: {
                HStack {
                    if model.isGenerating && !player.hasAudio { ProgressView().controlSize(.small) }
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    Text(primaryButtonTitle)
                }
                .frame(minWidth: 88)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Color(nsColor: .systemBlue), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(playbackDisabled)
            .opacity(playbackDisabled ? 0.45 : 1)

            Button { Task { await model.regenerate() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Regenerate audio")
            .disabled(playbackDisabled)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: volumeIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(
                    value: Binding(get: { model.outputVolume }, set: { model.outputVolume = $0 }),
                    in: 0...1
                )
                .frame(minWidth: 70, idealWidth: 90, maxWidth: 110)
                .help("Output volume sent to \(selectedDeviceName)")
                Text("\(Int((model.outputVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            Menu {
                Toggle(isOn: Binding(get: { model.loopEnabled }, set: { model.loopEnabled = $0 })) {
                    Label("Loop playback", systemImage: "repeat")
                }
                Toggle(isOn: Binding(get: { model.interruptionEnabled }, set: { model.interruptionEnabled = $0 })) {
                    Label("Pause for interruptions", systemImage: "ear")
                }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback options")
        }
    }

    private var playbackDisabled: Bool {
        !model.selectedScript.isCustom ||
        (model.isGenerating && !player.hasAudio) ||
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedDeviceName: String {
        model.devices.outputDevices.first(where: { $0.uid == model.selectedDeviceUID })?.name ?? "Output unavailable"
    }

    private var primaryButtonTitle: String {
        if model.isGenerating && !player.hasAudio { return "Preparing…" }
        if player.isBuffering { return "Buffering…" }
        return player.isPlaying ? "Pause" : "Play"
    }

    private var volumeIcon: String {
        switch model.outputVolume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

private struct CustomScriptEditorSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.editingCustomScriptID == nil ? "Add a custom script" : "Edit custom script")
                    .font(.title2.bold())
                Text("Give the text a recognizable name. Its generated ElevenLabs chunks will be cached separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Script name (for example, Weekly pipeline update)", text: $model.scriptDraftTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $model.scriptDraftText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            HStack {
                Text("\(model.scriptDraftText.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Script") {
                    do {
                        try model.saveScriptDraft()
                        saveError = nil
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }
}

private struct AnnotationKey: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct VoicePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Label("Voice", systemImage: "person.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isLoadingVoices {
                ProgressView().controlSize(.small)
                Text("Loading ElevenLabs voices…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Voice", selection: Binding(get: { model.voiceID }, set: { model.voiceID = $0 })) {
                    if !model.voices.contains(where: { $0.id == model.voiceID }) {
                        Text(model.selectedVoiceName).tag(model.voiceID)
                    }
                    ForEach(model.voices) { voice in
                        Text(voice.detail.isEmpty ? voice.name : "\(voice.name) — \(voice.detail)")
                            .tag(voice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button { Task { await model.refreshVoices() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh ElevenLabs voices")
            .disabled(model.isLoadingVoices)
        }

        if let error = model.voiceLoadError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum TimeDisplay {
    static func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
