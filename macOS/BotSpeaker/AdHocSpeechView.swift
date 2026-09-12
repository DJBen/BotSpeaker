import SwiftUI

/// Full-pane "Speak" surface: type text and play it on this Mac or, while
/// hosting, on any paired attendee. The `botspeaker` CLI drives the same queue.
struct SpeakView: View {
    let model: AppModel
    let orchestration: OrchestrationController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Speak", systemImage: "waveform.badge.mic")
                    .font(.title2.bold())
                // No `.fixedSize(horizontal: false, vertical: true)` here: inside the
                // split view detail it makes the whole window content lay out off-screen.
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            SpeechComposer(model: model, orchestration: orchestration, layout: .page)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.loadVoicesIfNeeded() }
    }

    private var subtitle: String {
        if orchestration.isHost {
            return "Play ad hoc text through this Mac's output or send it to a paired attendee. Scripted meeting turns always take priority."
        }
        return "Play ad hoc text through this Mac's output, outside any script. Host a meeting to speak on paired attendees too."
    }
}

/// The text box, target and voice pickers, Speak control, and request log.
/// `page` fills the main detail pane; `compact` fits inside the paired
/// attendee's session view.
struct SpeechComposer: View {
    enum Layout {
        case page
        case compact
    }

    let model: AppModel
    let orchestration: OrchestrationController
    var layout: Layout = .page

    @State private var text = ""
    @State private var targetID = SpeechComposer.localTargetID
    @State private var voiceID = ""
    @State private var loop = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    static let localTargetID = "local"

    private var attendees: [OrchestrationParticipant] {
        guard orchestration.isHost else { return [] }
        return orchestration.participants.filter { $0.id != orchestration.localParticipantID }
    }

    private var canTargetAttendees: Bool { orchestration.isHost }

    private var requests: [SpeechRequest] {
        let limit = layout == .page ? 12 : 4
        return Array(orchestration.speechRequests.suffix(limit).reversed())
    }

    private var hasPendingRequests: Bool {
        orchestration.speechRequests.contains { !$0.status.isTerminal }
    }

    private var selectedAttendee: OrchestrationParticipant? {
        attendees.first { $0.id == targetID }
    }

    private var targetLabel: String {
        selectedAttendee?.displayName ?? "This Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .page ? 14 : 10) {
            if canTargetAttendees {
                targetPicker
            }

            HStack(spacing: 8) {
                Label("Voice", systemImage: "person.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Voice", selection: $voiceID) {
                    Text(defaultVoiceLabel).tag("")
                    ForEach(model.voices) { voice in
                        Text(voice.detail.isEmpty ? voice.name : "\(voice.name) — \(voice.detail)")
                            .tag(voice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
                Toggle(isOn: $loop) {
                    Label("Loop until stopped", systemImage: "repeat")
                }
                .toggleStyle(.checkbox)
                .help("Play the text on a cycle until you stop it")
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .frame(minHeight: layout == .page ? 140 : 72, maxHeight: layout == .page ? 260 : 120)
                .accessibilityLabel("Text to speak")

            HStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(loop ? "\(wordCount) words · loops until stopped · ⌘↩ to speak" : "\(wordCount) words · ⌘↩ to speak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hasPendingRequests {
                    Button("Stop All") {
                        Task { await orchestration.cancelAllSpeech() }
                    }
                }
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: selectedAttendee == nil ? "waveform" : "antenna.radiowaves.left.and.right")
                        }
                        Text(selectedAttendee == nil ? "Speak" : "Speak on \(targetLabel)")
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !requests.isEmpty {
                Divider()
                Text(layout == .page ? "Recent requests" : "Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(requests) { request in
                        SpeechRequestRow(request: request) {
                            Task { try? await orchestration.cancelSpeech(id: request.id) }
                        }
                    }
                }
            }
        }
        .onChange(of: attendees.map(\.id)) { _, ids in
            if targetID != Self.localTargetID, !ids.contains(targetID) {
                targetID = Self.localTargetID
            }
        }
    }

    private var targetPicker: some View {
        HStack(spacing: 8) {
            Label("Play on", systemImage: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            if attendees.count <= 3 {
                targetChoices.pickerStyle(.segmented).fixedSize()
            } else {
                targetChoices.pickerStyle(.menu).fixedSize()
            }
            if attendees.isEmpty {
                Text("No attendees paired yet · share code \(orchestration.pairingCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetChoices: some View {
        Picker("Play on", selection: $targetID) {
            Text("This Mac").tag(Self.localTargetID)
            ForEach(attendees) { attendee in
                Text(attendee.isRecentlyConnected ? attendee.displayName : "\(attendee.displayName) (offline)")
                    .tag(attendee.id)
            }
        }
        .labelsHidden()
    }

    private var defaultVoiceLabel: String {
        if selectedAttendee != nil {
            return "Attendee's own voice"
        }
        return "Default (\(model.selectedVoiceName))"
    }

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func submit() {
        let target: SpeechTarget = targetID == Self.localTargetID ? .local : .participant(targetID)
        let spokenText = text
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await orchestration.speak(
                    text: spokenText,
                    target: target,
                    voiceID: voiceID.isEmpty ? nil : voiceID,
                    cycles: loop ? nil : 1
                )
                text = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SpeechRequestRow: View {
    let request: SpeechRequest
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.text)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !request.status.isTerminal {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        }
    }

    private var detail: String {
        var parts = [request.targetName, request.status.displayName]
        if let cycles = request.cyclesDescription { parts.append("pass \(cycles)") }
        if let voiceName = request.voiceName, !voiceName.isEmpty { parts.append(voiceName) }
        if let error = request.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch request.status {
        case .queued: .secondary
        case .preparing: .orange
        case .speaking: .green
        case .completed: .blue
        case .failed: .red
        case .cancelled: .gray
        }
    }
}
