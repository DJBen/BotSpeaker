import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OrchestratedMeetingConfigurationView: View {
    let model: AppModel
    @Bindable var controller: OrchestrationController
    let onPrepareMeeting: () -> Void
    @State private var editingSpeakerSlot: Int?
    @State private var draftSpeakerName = ""
    @State private var draggedAttendeeID: String?
    @State private var attendeeDropTarget: AttendeeDropTarget?

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
                VStack(spacing: 2) {
                    ForEach(Array(controller.speakerConfigurations.enumerated()), id: \.element.id) { index, configuration in
                        speakerRow(configuration: configuration, seatIndex: index)
                        if configuration.id != controller.speakerConfigurations.last?.id { Divider() }
                    }
                    if !benchedAttendees.isEmpty {
                        benchSection
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
                        : "A reusable host code will be created before opening this \(controller.selectedTemplate.speakerCount)-speaker script.")
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
                                : "Host & Use This Script",
                            systemImage: "arrow.right.circle.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(controller.isBusy)
            }
        }
        .padding(22)
        .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func speakerRow(configuration: OrchestratedSpeakerConfiguration, seatIndex: Int) -> some View {
        let availableVoices: [ElevenLabsVoice] = model.voices
        return HStack(spacing: 12) {
            Button {
                draftSpeakerName = configuration.name
                editingSpeakerSlot = configuration.slot
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .frame(width: 20)
            .help("Edit speaker name")

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.name.isEmpty ? configuration.placeholder : configuration.name)
                    .font(configuration.name.isEmpty ? .body.monospaced() : .body.weight(.semibold))
                Text(configuration.role)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 110, idealWidth: 210, maxWidth: 210, alignment: .leading)

            Menu {
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
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(selectedVoiceName(for: configuration), systemImage: "person.wave.2")
                    .lineLimit(1)
            }
            .fixedSize()

            Spacer(minLength: 12)

            seatOccupantView(seatIndex: seatIndex)
                .frame(minWidth: 100, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            attendeeDropTarget == .seat(seatIndex) ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .animation(.easeOut(duration: 0.1), value: attendeeDropTarget)
        .onDrop(
            of: [.text],
            delegate: AttendeeAssignmentDropDelegate(
                target: .seat(seatIndex),
                isEnabled: canArrangeAttendees,
                draggedAttendeeID: $draggedAttendeeID,
                dropTarget: $attendeeDropTarget,
                onAssign: { attendeeID, target in assign(attendeeID: attendeeID, to: target) }
            )
        )
    }

    @ViewBuilder
    private func seatOccupantView(seatIndex: Int) -> some View {
        if let occupant = attendee(inSeat: seatIndex) {
            attendeeChip(occupant)
        } else {
            Text("Vacant seat")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(
                    Capsule().strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .help("Waiting for a paired attendee to fill this seat")
        }
    }

    private func attendeeChip(_ attendee: OrchestrationParticipant) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(attendee.isRecentlyConnected ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(attendeeChipName(attendee))
                .lineLimit(1)
            if canArrangeAttendees {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .onDrag {
            guard canArrangeAttendees else { return NSItemProvider() }
            draggedAttendeeID = attendee.id
            return NSItemProvider(object: attendee.id as NSString)
        } preview: {
            Label(attendee.displayName, systemImage: "person.fill")
                .padding(8)
        }
    }

    private var benchSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                Text("Not in this meeting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
            }
            ForEach(benchedAttendees) { attendee in
                HStack(spacing: 10) {
                    attendeeChip(attendee)
                    Text("Drag onto a speaker seat to include")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            attendeeDropTarget == .bench ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .animation(.easeOut(duration: 0.1), value: attendeeDropTarget)
        .onDrop(
            of: [.text],
            delegate: AttendeeAssignmentDropDelegate(
                target: .bench,
                isEnabled: canArrangeAttendees,
                draggedAttendeeID: $draggedAttendeeID,
                dropTarget: $attendeeDropTarget,
                onAssign: { attendeeID, target in assign(attendeeID: attendeeID, to: target) }
            )
        )
    }

    private var orderedAttendees: [OrchestrationParticipant] {
        let byID = Dictionary(uniqueKeysWithValues: controller.participants.map { ($0.id, $0) })
        return controller.participantOrder.compactMap { byID[$0] }
    }

    private func attendee(inSeat seat: Int) -> OrchestrationParticipant? {
        guard let id = controller.seatAssignments.first(where: { $0.value == seat })?.key else { return nil }
        return controller.participants.first { $0.id == id }
    }

    private var benchedAttendees: [OrchestrationParticipant] {
        orderedAttendees.filter { controller.seatAssignments[$0.id] == nil }
    }

    private var canArrangeAttendees: Bool {
        controller.isHost && controller.sessionStatus == .lobby && controller.turns.isEmpty
    }

    private func selectedVoiceName(for configuration: OrchestratedSpeakerConfiguration) -> String {
        let current = controller.speakerConfigurations.first(where: { $0.slot == configuration.slot }) ?? configuration
        let fullName = model.voices.first(where: { $0.id == current.voiceID })?.name ?? current.voiceName
        return fullName
            .components(separatedBy: " — ").first?
            .components(separatedBy: " - ").first ?? fullName
    }

    private func attendeeChipName(_ attendee: OrchestrationParticipant) -> String {
        attendee.id == controller.localParticipantID
            ? "\(attendee.displayName) (this Mac)"
            : attendee.displayName
    }

    private func assign(attendeeID: String, to target: AttendeeDropTarget) {
        switch target {
        case .seat(let seatIndex):
            controller.assignParticipant(id: attendeeID, toSeat: seatIndex)
        case .bench:
            controller.benchParticipant(id: attendeeID)
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

    private func openHostedMeeting() {
        Task {
            if controller.isHost {
                await controller.useSelectedTemplateInHostedGroup()
            } else {
                controller.prepareHostSetup()
                await controller.startHosting()
            }
            if controller.isHost { onPrepareMeeting() }
        }
    }
}

private enum AttendeeDropTarget: Equatable {
    case seat(Int)
    case bench
}

private struct AttendeeAssignmentDropDelegate: DropDelegate {
    let target: AttendeeDropTarget
    let isEnabled: Bool
    @Binding var draggedAttendeeID: String?
    @Binding var dropTarget: AttendeeDropTarget?
    let onAssign: (String, AttendeeDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && draggedAttendeeID != nil
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled, draggedAttendeeID != nil else { return }
        dropTarget = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isEnabled, draggedAttendeeID != nil else { return DropProposal(operation: .forbidden) }
        dropTarget = target
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedAttendeeID = nil
            dropTarget = nil
        }
        guard isEnabled, let attendeeID = draggedAttendeeID else { return false }
        onAssign(attendeeID, target)
        return true
    }
}
