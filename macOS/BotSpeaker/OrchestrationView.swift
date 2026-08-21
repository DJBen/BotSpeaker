import AppKit
import SwiftUI

struct OrchestrationView: View {
    let model: AppModel
    @Bindable var controller: OrchestrationController
    let onExit: () -> Void
    @State private var exportError: String?

    var body: some View {
        Group {
            if controller.isActive {
                activeSession
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.loadVoicesIfNeeded() }
        .onDisappear {
            guard controller.isActive else { return }
            Task { await controller.leaveSession() }
        }
        .onKeyPress(.space) {
            guard controller.isHost else { return .ignored }
            switch controller.sessionStatus {
            case .running:
                Task { await controller.pauseMeeting() }
                return .handled
            case .paused:
                Task { await controller.resumeMeeting() }
                return .handled
            default:
                return .ignored
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
            scriptPlanCard

            HSplitView {
                participantsPanel
                    .frame(minWidth: 260, idealWidth: 300)
                timelinePanel
                    .frame(minWidth: 290, idealWidth: 360)
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

    private var scriptPlanCard: some View {
        GroupBox("Orchestrated meeting") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.selectedTemplate.title).fontWeight(.semibold)
                        Text("Reorder paired clients to assign \(configuredSpeakerNames).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(controller.turns.isEmpty ? "Draft" : "Prepared")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                ScrollView {
                    Text(controller.configuredScriptPreview)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                }
                .frame(minHeight: 110, maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
            }
            .padding(6)
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
            statusPill
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var participantsPanel: some View {
        GroupBox("Speakers") {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(orderedParticipants.enumerated()), id: \.element.id) { index, participant in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(participant.isRecentlyConnected ? .green : .orange)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(participant.displayName)
                                    .fontWeight(.medium)
                                Text(participantAssignmentText(index: index, participant: participant))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: participantPreparationIcon(participant))
                                .foregroundStyle(participantPreparationColor(participant))
                                .help(participantPreparationText(participant))
                            if controller.sessionStatus == .lobby && controller.turns.isEmpty {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .help("Drag to change this client’s speaker assignment")
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(
                            controller.activeTurn?.participantUID == participant.id
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .draggable(participant.id) {
                            Label(participant.displayName, systemImage: "person.fill")
                                .padding(8)
                        }
                        .dropDestination(for: String.self) { participantIDs, _ in
                            guard let participantID = participantIDs.first else { return false }
                            controller.moveParticipant(id: participantID, before: participant.id)
                            return true
                        }
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
                        description: Text("Pair \(controller.selectedTemplate.speakerCount) speakers, arrange their roles, then prepare the host script.")
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
            Button("Leave", action: leaveFlow)
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
                if controller.turns.isEmpty {
                    Button {
                        Task { await controller.prepareMeeting() }
                    } label: {
                        Label("Prepare Speakers", systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canPrepareMeeting)
                } else {
                    Button {
                        Task { await controller.startMeeting() }
                    } label: {
                        Label("Start Meeting", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStartMeeting)
                }
            case .running:
                Button("Skip Turn") { Task { await controller.skipCurrentTurn() } }
                Button {
                    Task { await controller.pauseMeeting() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Stop", role: .destructive) { Task { await controller.stopMeeting() } }
            case .paused:
                Button("Skip Turn") { Task { await controller.skipCurrentTurn() } }
                Button {
                    Task { await controller.resumeMeeting() }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                    .buttonStyle(.borderedProminent)
                Button("Stop", role: .destructive) { Task { await controller.stopMeeting() } }
            case .completed, .stopped:
                Button("Done", action: leaveFlow)
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
                    LabeledContent("Script", value: controller.meetingScriptTitle)
                    LabeledContent("Voice", value: model.selectedVoiceName)
                    LabeledContent(
                        "Prepared paragraphs",
                        value: "\(controller.preparedLocalSegmentCount) of \(controller.localAssignedSegmentCount)"
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
                Button("Disconnect", action: leaveFlow)
            }
        }
    }

    private func leaveFlow() {
        Task {
            if controller.isActive {
                await controller.leaveSession()
            }
            onExit()
        }
    }

    private var orderedParticipants: [OrchestrationParticipant] {
        let byID = Dictionary(uniqueKeysWithValues: controller.participants.map { ($0.id, $0) })
        return controller.participantOrder.compactMap { byID[$0] }
    }

    private func participantAssignmentText(index: Int, participant: OrchestrationParticipant) -> String {
        let template = controller.selectedTemplate
        guard index < template.speakerRoles.count else { return "Unassigned client · \(participant.voiceName)" }
        let configuredName = controller.speakerConfigurations.indices.contains(index)
            ? controller.speakerConfigurations[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let displayName = configuredName.isEmpty ? "Speaker \(index + 1)" : configuredName
        return "\(displayName) · \(template.speakerRoles[index]) · \(participant.segmentCount) turns"
    }

    private var configuredSpeakerNames: String {
        controller.speakerConfigurations.map { configuration in
            let name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Speaker \(configuration.slot)" : name
        }.joined(separator: ", ")
    }

    private func participantPreparationText(_ participant: OrchestrationParticipant) -> String {
        if let error = participant.preparationError { return "Preparation failed: \(error)" }
        guard participant.segmentCount > 0 else { return "Waiting for script assignment" }
        return "\(participant.preparedSegmentCount) of \(participant.segmentCount) prepared"
    }

    private func participantPreparationIcon(_ participant: OrchestrationParticipant) -> String {
        if participant.preparationError != nil { return "exclamationmark.triangle.fill" }
        return participant.segmentCount > 0 && participant.preparedSegmentCount == participant.segmentCount
            ? "checkmark.circle.fill"
            : "arrow.down.circle"
    }

    private func participantPreparationColor(_ participant: OrchestrationParticipant) -> Color {
        if participant.preparationError != nil { return .red }
        return participant.segmentCount > 0 && participant.preparedSegmentCount == participant.segmentCount
            ? .green
            : .secondary
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
