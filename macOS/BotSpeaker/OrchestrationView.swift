import AppKit
import SwiftUI

struct OrchestrationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: OrchestrationController
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if controller.isActive {
                    activeSession
                } else {
                    setup
                }
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 620)
        .task { await model.loadVoicesIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Orchestrator")
                    .font(.title2.bold())
                Text("Pair laptops, alternate speakers automatically, and export exact timestamps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isActive {
                statusPill
            }
        }
        .padding(20)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Mode", selection: $controller.setupMode) {
                ForEach(OrchestrationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("This Mac’s speaker", systemImage: "laptopcomputer")
                        .font(.headline)
                    TextField("Speaker name", text: $controller.speakerName)
                        .textFieldStyle(.roundedBorder)

                    LabeledContent("Script") {
                        Text(model.selectedScript.title)
                            .lineLimit(1)
                    }
                    LabeledContent("Voice") {
                        Text(model.selectedVoiceName)
                            .lineLimit(1)
                    }
                    LabeledContent("Turns") {
                        Text("\(OrchestrationScriptSegmenter.segments(for: model.text).count) paragraphs")
                    }

                    if !model.selectedScript.isCustom {
                        Label("Choose or replicate a playable script in the main window first.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            if controller.setupMode == .remote {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Pairing code")
                        .font(.headline)
                    TextField("ABC234", text: $controller.pairingCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.monospaced())
                        .textCase(.uppercase)
                        .onSubmit(performSetupAction)
                    Text("Enter the six-character code shown on the host Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Text("Cloud coordination: Firebase project bot-speaker-1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: performSetupAction) {
                    if controller.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            controller.setupMode == .host ? "Host Meeting" : "Join Meeting",
                            systemImage: controller.setupMode == .host ? "dot.radiowaves.left.and.right" : "link"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSetupActionDisabled)
            }
        }
    }

    private var isSetupActionDisabled: Bool {
        controller.isBusy
            || controller.speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.selectedScript.isCustom
    }

    private func performSetupAction() {
        guard !isSetupActionDisabled else { return }
        Task {
            if controller.setupMode == .host {
                await controller.startHosting()
            } else {
                await controller.joinMeeting()
            }
        }
    }

    @ViewBuilder
    private var activeSession: some View {
        if controller.isHost {
            hostSession
        } else {
            remoteSession
        }
    }

    private var hostSession: some View {
        VStack(spacing: 16) {
            pairingCard

            HSplitView {
                participantsPanel
                    .frame(minWidth: 300)
                timelinePanel
                    .frame(minWidth: 330)
            }

            if let error = controller.errorMessage ?? exportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            hostControls
        }
    }

    private var pairingCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pairing code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.pairingCode)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.pairingCode, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy pairing code")
            Spacer()
            if controller.sessionStatus == .lobby {
                Toggle(
                    "Allow pairing",
                    isOn: Binding(
                        get: { controller.pairingOpen },
                        set: { value in Task { await controller.setPairingOpen(value) } }
                    )
                )
                .toggleStyle(.switch)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var participantsPanel: some View {
        GroupBox("Speakers") {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(orderedParticipants.enumerated()), id: \.element.id) { index, participant in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(participant.isRecentlyConnected ? .green : .orange)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(participant.displayName)
                                    .fontWeight(.medium)
                                Text("\(participant.scriptTitle) · \(participant.segmentCount) turns")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Label(
                                    participantPreparationText(participant),
                                    systemImage: participant.isFirstTurnPrepared
                                        ? "checkmark.circle.fill"
                                        : participant.preparationError == nil
                                            ? "arrow.down.circle"
                                            : "exclamationmark.triangle.fill"
                                )
                                .font(.caption2)
                                .foregroundStyle(
                                    participant.preparationError != nil
                                        ? Color.red
                                        : participant.isFirstTurnPrepared
                                            ? Color.green
                                            : Color.secondary
                                )
                                .lineLimit(1)
                            }
                            Spacer()
                            if controller.sessionStatus == .lobby {
                                VStack(spacing: 2) {
                                    Button { controller.moveParticipant(id: participant.id, by: -1) } label: {
                                        Image(systemName: "chevron.up")
                                    }
                                    .disabled(index == 0)
                                    Button { controller.moveParticipant(id: participant.id, by: 1) } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .disabled(index == orderedParticipants.count - 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(9)
                        .background(
                            controller.activeTurn?.participantUID == participant.id
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
                .padding(6)
            }
        }
    }

    private var timelinePanel: some View {
        GroupBox("Turn timeline") {
            VStack(alignment: .leading, spacing: 10) {
                if let turn = controller.activeTurn, controller.sessionStatus != .completed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now: \(turn.speakerName)")
                            .font(.headline)
                        Text("Turn \(turn.index + 1) of \(controller.turns.count) · paragraph \(turn.segmentIndex + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if controller.turns.isEmpty {
                    ContentUnavailableView(
                        "No turns yet",
                        systemImage: "list.number",
                        description: Text("Pair speakers, arrange them, then start the meeting.")
                    )
                }

                if !controller.turns.isEmpty {
                    ProgressView(
                        value: Double(max(controller.activeTurnIndex, 0)),
                        total: Double(max(controller.turns.count, 1))
                    )
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(controller.turns) { turn in
                                HStack {
                                    Image(systemName: turnIcon(turn.status))
                                        .foregroundStyle(turnColor(turn.status))
                                        .frame(width: 18)
                                    Text("\(turn.index + 1). \(turn.speakerName)")
                                        .lineLimit(1)
                                    Spacer()
                                    Text(turn.status.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var hostControls: some View {
        HStack {
            Button("Leave") { Task { await controller.leaveSession() } }
            Spacer()
            if controller.canExportTranscript {
                Button {
                    do {
                        try controller.exportTranscript()
                        exportError = nil
                    } catch {
                        exportError = error.localizedDescription
                    }
                } label: {
                    Label("Export Timestamped JSON…", systemImage: "curlybraces")
                }
            }

            switch controller.sessionStatus {
            case .lobby:
                Button {
                    Task { await controller.startMeeting() }
                } label: {
                    Label("Start Meeting", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canStartMeeting)
            case .running:
                Button("Skip Turn") { Task { await controller.skipCurrentTurn() } }
                Button("Pause") { Task { await controller.pauseMeeting() } }
                Button("Stop", role: .destructive) { Task { await controller.stopMeeting() } }
            case .paused:
                Button("Skip Turn") { Task { await controller.skipCurrentTurn() } }
                Button("Resume") { Task { await controller.resumeMeeting() } }
                    .buttonStyle(.borderedProminent)
                Button("Stop", role: .destructive) { Task { await controller.stopMeeting() } }
            case .completed, .stopped:
                Button("Done") { Task { await controller.leaveSession() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var remoteSession: some View {
        VStack(spacing: 20) {
            Image(systemName: remoteStatusIcon)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: controller.sessionStatus == .running)

            VStack(spacing: 6) {
                Text(controller.sessionStatus.displayName)
                    .font(.title.bold())
                Text(model.remoteControlStatus)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 10) {
                    LabeledContent("Room", value: controller.pairingCode)
                    LabeledContent("Speaker", value: controller.speakerName)
                    LabeledContent("Script", value: model.selectedScript.title)
                    LabeledContent("Voice", value: model.selectedVoiceName)
                    LabeledContent(
                        "Prepared paragraphs",
                        value: "\(controller.preparedLocalSegmentCount) of \(OrchestrationScriptSegmenter.segments(for: model.selectedScript.text).count)"
                    )
                    LabeledContent("Preparation", value: controller.preparationStatus)
                }
                .padding(8)
            }
            .frame(maxWidth: 480)

            if let turn = controller.activeTurn {
                Text("Current meeting turn: \(turn.index + 1) of \(controller.turns.count) — \(turn.speakerName)")
                    .font(.callout.monospacedDigit())
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = controller.preparationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Text("Local playback controls are locked while this Mac is paired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Disconnect") { Task { await controller.leaveSession() } }
            }
        }
    }

    private var orderedParticipants: [OrchestrationParticipant] {
        let byID = Dictionary(uniqueKeysWithValues: controller.participants.map { ($0.id, $0) })
        return controller.participantOrder.compactMap { byID[$0] }
    }

    private func participantPreparationText(_ participant: OrchestrationParticipant) -> String {
        if let error = participant.preparationError { return "Preparation failed: \(error)" }
        if participant.isFirstTurnPrepared {
            return "\(participant.preparedSegmentCount) of \(participant.segmentCount) prepared"
        }
        return "Preparing first turn…"
    }

    private var statusPill: some View {
        Text(controller.sessionStatus.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private var remoteStatusIcon: String {
        switch controller.sessionStatus {
        case .lobby: "hourglass"
        case .running: model.player.isPlaying ? "waveform.circle.fill" : "antenna.radiowaves.left.and.right"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    private func turnIcon(_ status: OrchestrationTurnStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .speaking: "waveform.circle.fill"
        case .preparing: "ellipsis.circle.fill"
        case .assigned: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .skipped, .stopped: "forward.end.circle.fill"
        case .queued: "circle"
        }
    }

    private func turnColor(_ status: OrchestrationTurnStatus) -> Color {
        switch status {
        case .completed: .green
        case .speaking: .accentColor
        case .failed: .red
        case .skipped, .stopped: .orange
        default: .secondary
        }
    }
}
