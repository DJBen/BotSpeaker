import SwiftUI

/// Host-side popover for speaking arbitrary text on this Mac or on any
/// paired attendee, outside the orchestrated script. The `botspeaker` CLI
/// drives the same queue.
struct AdHocSpeechPopover: View {
    let model: AppModel
    let orchestration: OrchestrationController

    @State private var text = ""
    @State private var targetID = "local"
    @State private var voiceID = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    private var attendees: [OrchestrationParticipant] {
        orchestration.participants.filter { $0.id != orchestration.localParticipantID }
    }

    private var recentRequests: [SpeechRequest] {
        Array(orchestration.speechRequests.suffix(6).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speak ad hoc text")
                .font(.headline)

            Picker("Play on", selection: $targetID) {
                Text("This Mac").tag("local")
                ForEach(attendees) { attendee in
                    Text(attendee.isRecentlyConnected ? attendee.displayName : "\(attendee.displayName) (offline)")
                        .tag(attendee.id)
                }
            }

            Picker("Voice", selection: $voiceID) {
                Text(targetID == "local" ? "Default (\(model.selectedVoiceName))" : "Attendee's voice").tag("")
                ForEach(model.voices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )

            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                if orchestration.speechRequests.contains(where: { !$0.status.isTerminal }) {
                    Button("Stop All") {
                        Task { await orchestration.cancelAllSpeech() }
                    }
                }
                Button(action: submit) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Speak", systemImage: "waveform")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !recentRequests.isEmpty {
                Divider()
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(recentRequests) { request in
                    HStack(alignment: .top, spacing: 8) {
                        statusDot(for: request.status)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(request.text)
                                .lineLimit(1)
                            Text("\(request.targetName) · \(request.status.displayName)\(request.error.map { " · \($0)" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if !request.status.isTerminal {
                            Button {
                                Task { try? await orchestration.cancelSpeech(id: request.id) }
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Cancel")
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .task { await model.loadVoicesIfNeeded() }
    }

    private func submit() {
        let target: SpeechTarget = targetID == "local" ? .local : .participant(targetID)
        let spokenText = text
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await orchestration.speak(
                    text: spokenText,
                    target: target,
                    voiceID: voiceID.isEmpty ? nil : voiceID
                )
                text = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func statusDot(for status: SpeechRequestStatus) -> some View {
        let color: Color = switch status {
        case .queued: .secondary
        case .preparing: .orange
        case .speaking: .green
        case .completed: .blue
        case .failed: .red
        case .cancelled: .gray
        }
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
