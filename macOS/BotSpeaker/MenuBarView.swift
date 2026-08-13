import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.hasAPIKey {
                ComposerView(model: model, player: model.player)
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

    var body: some View {
        Group {
            if model.hasAPIKey {
                ComposerView(model: model, player: model.player)
            } else {
                FirstRunView(model: model)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { await model.loadVoicesIfNeeded() }
    }
}

struct ComposerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: AudioPlaybackController
    @Environment(\.openWindow) private var openWindow
    @State private var sliderValue = 0.0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Bot Speaker", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Settings")
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedScript.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(model.selectedScript.detail) · \(model.selectedScript.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if model.selectedScript.isCustom {
                        Label("Custom script", systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Section("Built-in examples") {
                        ForEach(model.bundledScripts) { script in
                            Button {
                                model.selectScript(id: script.id)
                            } label: {
                                if script.id == model.selectedScriptID {
                                    Label("\(script.title) — \(script.detail)", systemImage: "checkmark")
                                } else {
                                    Text("\(script.title) — \(script.detail)")
                                }
                            }
                        }
                    }

                    if !model.customScripts.isEmpty {
                        Section("Custom scripts") {
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
                    }
                } label: {
                    Label("Choose", systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .help("Choose a named script")

                Button {
                    model.prepareScriptEditor()
                    openWindow(id: "script-editor")
                } label: {
                    Label(model.selectedScript.isCustom ? "Edit" : "Add Text", systemImage: "square.and.pencil")
                }
                .help(model.selectedScript.isCustom ? "Edit this custom script in a separate window" : "Create a named custom script")
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

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

            HStack(spacing: 12) {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
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
                .disabled(
                    (model.isGenerating && !player.hasAudio) ||
                    model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .opacity(
                    (model.isGenerating && !player.hasAudio) ||
                    model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? 0.45 : 1
                )

                Button {
                    Task { await model.regenerate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Regenerate audio")
                .disabled(model.text.isEmpty)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: volumeIcon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Slider(
                        value: Binding(
                            get: { model.outputVolume },
                            set: { model.outputVolume = $0 }
                        ),
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
        }
        .padding(16)
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

struct CustomScriptEditorWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
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

                Button("Cancel") {
                    dismissWindow(id: "script-editor")
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Script") {
                    do {
                        try model.saveScriptDraft()
                        saveError = nil
                        dismissWindow(id: "script-editor")
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
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

            Button {
                Task { await model.refreshVoices() }
            } label: {
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
