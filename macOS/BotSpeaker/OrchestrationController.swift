import AppKit
import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation
import UniformTypeIdentifiers

private struct PersistedOrchestratedSpeakerConfiguration: Codable {
    let slot: Int
    let name: String
    let voiceID: String
    let voiceName: String
}

@MainActor
@Observable
final class OrchestrationController {
    private static let speakerConfigurationDefaultsKey = "orchestratedMeetingSpeakerConfigurations"
    var setupMode: OrchestrationMode = .host
    var speakerName: String
    var pairingCodeInput = ""
    var meetingScriptText = OrchestratedMeetingTemplate.launchReadiness.text
    private(set) var selectedTemplate = OrchestratedMeetingTemplate.launchReadiness
    var speakerConfigurations: [OrchestratedSpeakerConfiguration]
    private(set) var activeMode: OrchestrationMode?
    private(set) var sessionID: String?
    private(set) var pairingCode = ""
    private(set) var sessionStatus: OrchestrationSessionStatus = .lobby
    private(set) var pairingOpen = false
    private(set) var participants: [OrchestrationParticipant] = []
    private(set) var participantOrder: [String] = []
    private(set) var turns: [OrchestrationTurn] = []
    private(set) var activeTurnIndex = -1
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var preparedLocalSegmentCount = 0
    private(set) var preparationStatus = "Not prepared"
    private(set) var preparationError: String?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var meetingScriptTitle = OrchestratedMeetingTemplate.launchReadiness.title

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let database: Firestore
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var hostUID: String?
    @ObservationIgnored private var localSegments: [String] = []
    @ObservationIgnored private var localScriptTitle = ""
    @ObservationIgnored private var localVoiceName = ""
    @ObservationIgnored private var activeExecutionTurnID: String?
    @ObservationIgnored private var hasReportedPlaybackStart = false
    @ObservationIgnored private var isAdvancing = false
    @ObservationIgnored private var previousSessionStatus: OrchestrationSessionStatus = .lobby
    @ObservationIgnored private var roomListener: ListenerRegistration?
    @ObservationIgnored private var participantsListener: ListenerRegistration?
    @ObservationIgnored private var turnsListener: ListenerRegistration?
    @ObservationIgnored private var heartbeatTimer: AnyCancellable?
    @ObservationIgnored private var executionWatchdogTimer: AnyCancellable?
    @ObservationIgnored private var orchestrationActivity: NSObjectProtocol?
    @ObservationIgnored private var turnExecutionTask: Task<Void, Never>?
    @ObservationIgnored private var preparedLocalSegments: Set<Int> = []
    @ObservationIgnored private var prefetchSegmentIndex: Int?
    @ObservationIgnored private var prefetchTask: Task<Void, Error>?
    @ObservationIgnored private var prefetchObserverTask: Task<Void, Never>?
    @ObservationIgnored private var defaultVoicesAppliedForTemplateID: String?

    init(model: AppModel) {
        self.model = model
        let restoredConfiguration = Self.loadSpeakerConfigurations(
            for: OrchestratedMeetingTemplate.launchReadiness,
            model: model
        )
        speakerConfigurations = restoredConfiguration.configurations
        defaultVoicesAppliedForTemplateID = restoredConfiguration.wasRestored
            ? OrchestratedMeetingTemplate.launchReadiness.id
            : nil
        speakerName = UserDefaults.standard.string(forKey: "orchestrationSpeakerName")
            ?? Host.current().localizedName
            ?? "Speaker"

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        database = Firestore.firestore()

        model.player.onPlaybackStarted = { [weak self] in
            self?.playbackDidStart()
        }
        model.player.onPlaybackFinished = { [weak self] in
            self?.playbackDidFinish()
        }
    }

    var isActive: Bool { activeMode != nil }
    var isHost: Bool { activeMode == .host }
    var localParticipantID: String? { userID }
    var localAssignedSegmentCount: Int { localSegments.count }

    var activeTurn: OrchestrationTurn? {
        guard turns.indices.contains(activeTurnIndex) else { return nil }
        return turns[activeTurnIndex]
    }

    var canStartMeeting: Bool {
        let connected = participants.filter(\.isRecentlyConnected)
        let assignedIDs = Set(turns.map(\.participantUID))
        return isHost
            && sessionStatus == .lobby
            && !turns.isEmpty
            && assignedIDs.allSatisfy { id in
                connected.first(where: { $0.id == id })?.isFirstTurnPrepared == true
            }
            && !isBusy
    }

    var canPrepareMeeting: Bool {
        isHost
            && sessionStatus == .lobby
            && turns.isEmpty
            && participants.filter(\.isRecentlyConnected).count >= selectedTemplate.speakerCount
            && !isBusy
    }

    var isSpeakerConfigurationComplete: Bool {
        speakerConfigurations.count == selectedTemplate.speakerCount
            && speakerConfigurations.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.voiceID.isEmpty
            }
    }

    var configuredScriptPreview: String {
        speakerConfigurations.reduce(meetingScriptText) { preview, configuration in
            let replacement = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.replacingOccurrences(
                of: configuration.placeholder,
                with: replacement.isEmpty ? configuration.placeholder : replacement
            )
        }
    }

    func prepareHostSetup() {
        setupMode = .host
        errorMessage = nil
    }

    func selectTemplate(_ template: OrchestratedMeetingTemplate) {
        guard !isActive, template.id != selectedTemplate.id else { return }
        selectedTemplate = template
        meetingScriptText = template.text
        meetingScriptTitle = template.title
        let restoredConfiguration = Self.loadSpeakerConfigurations(for: template, model: model)
        speakerConfigurations = restoredConfiguration.configurations
        defaultVoicesAppliedForTemplateID = restoredConfiguration.wasRestored ? template.id : nil
        applyDefaultTemplateVoices()
    }

    func applyDefaultTemplateVoices() {
        guard defaultVoicesAppliedForTemplateID != selectedTemplate.id,
              let voices = model?.voices,
              !voices.isEmpty else { return }
        var usedVoiceIDs: Set<String> = []
        for index in speakerConfigurations.indices {
            let preferredGender = selectedTemplate.defaultVoiceGenders.indices.contains(index)
                ? selectedTemplate.defaultVoiceGenders[index].lowercased()
                : nil
            let matchingUnused = voices.first {
                preferredGender != nil
                    && !usedVoiceIDs.contains($0.id)
                    && $0.labels["gender"]?.lowercased() == preferredGender
            }
            let matching = voices.first {
                preferredGender != nil && $0.labels["gender"]?.lowercased() == preferredGender
            }
            let fallback = voices.first { !usedVoiceIDs.contains($0.id) } ?? voices[0]
            let voice = matchingUnused ?? matching ?? fallback
            speakerConfigurations[index].voiceID = voice.id
            speakerConfigurations[index].voiceName = voice.name
            usedVoiceIDs.insert(voice.id)
        }
        defaultVoicesAppliedForTemplateID = selectedTemplate.id
        persistSpeakerConfigurations()
    }

    func updateConfiguredVoice(slot: Int, voiceID: String) {
        guard let index = speakerConfigurations.firstIndex(where: { $0.slot == slot }) else { return }
        speakerConfigurations[index].voiceID = voiceID
        speakerConfigurations[index].voiceName = model?.voices.first(where: { $0.id == voiceID })?.name
            ?? "Voice ID \(voiceID.prefix(8))…"
        persistSpeakerConfigurations()
    }

    func updateConfiguredSpeakerName(slot: Int, name: String) {
        guard let index = speakerConfigurations.firstIndex(where: { $0.slot == slot }) else { return }
        speakerConfigurations[index].name = name
        persistSpeakerConfigurations()
    }

    private func persistSpeakerConfigurations() {
        var saved = Self.savedSpeakerConfigurations()
        saved[selectedTemplate.id] = speakerConfigurations.map {
            PersistedOrchestratedSpeakerConfiguration(
                slot: $0.slot,
                name: $0.name,
                voiceID: $0.voiceID,
                voiceName: $0.voiceName
            )
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.speakerConfigurationDefaultsKey)
    }

    private static func loadSpeakerConfigurations(
        for template: OrchestratedMeetingTemplate,
        model: AppModel?
    ) -> (configurations: [OrchestratedSpeakerConfiguration], wasRestored: Bool) {
        let savedBySlot = Dictionary(
            uniqueKeysWithValues: (savedSpeakerConfigurations()[template.id] ?? []).map { ($0.slot, $0) }
        )
        let configurations = template.speakerRoles.enumerated().map { index, role in
            let slot = index + 1
            let saved = savedBySlot[slot]
            return OrchestratedSpeakerConfiguration(
                slot: slot,
                role: role,
                name: saved?.name ?? "",
                voiceID: saved?.voiceID ?? model?.voiceID ?? "",
                voiceName: saved?.voiceName ?? model?.selectedVoiceName ?? "Choose a voice"
            )
        }
        return (configurations, !savedBySlot.isEmpty)
    }

    private static func savedSpeakerConfigurations() -> [String: [PersistedOrchestratedSpeakerConfiguration]] {
        guard let data = UserDefaults.standard.data(forKey: speakerConfigurationDefaultsKey),
              let saved = try? JSONDecoder().decode(
                  [String: [PersistedOrchestratedSpeakerConfiguration]].self,
                  from: data
              ) else { return [:] }
        return saved
    }

    var canExportTranscript: Bool {
        isHost && (sessionStatus == .completed || sessionStatus == .stopped) && !turns.isEmpty
    }

    func startHosting() async {
        await performBusyOperation {
            let local = try self.prepareLocalSpeaker()
            let uid = try await self.ensureSignedIn()
            let roomID = UUID().uuidString.lowercased()
            let code = Self.makePairingCode()
            let roomReference = self.roomReference(roomID)

            try await roomReference.setData([
                "hostUID": uid,
                "pairingCode": code,
                "pairingOpen": true,
                "status": OrchestrationSessionStatus.lobby.rawValue,
                "activeTurnIndex": -1,
                "totalTurns": 0,
                "scriptTemplateID": self.selectedTemplate.id,
                "scriptTitle": self.selectedTemplate.title,
                "scriptText": self.meetingScriptText,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
                "activityAt": FieldValue.serverTimestamp()
            ])

            try await self.pairingReference(code).setData([
                "code": code,
                "roomID": roomID,
                "hostUID": uid,
                "isOpen": true,
                "createdAt": FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(date: Date().addingTimeInterval(4 * 60 * 60))
            ])

            try await self.writeLocalParticipant(
                roomID: roomID,
                code: code,
                uid: uid,
                local: local
            )
            self.activateSession(roomID: roomID, code: code, mode: .host, hostUID: uid, local: local)
        }
    }

    func joinMeeting() async {
        await performBusyOperation {
            let local = try self.prepareLocalSpeaker()
            let uid = try await self.ensureSignedIn()
            let code = self.pairingCodeInput
                .uppercased()
                .filter { $0.isLetter || $0.isNumber }
            guard code.count == 6 else { throw AppError("Enter the six-character pairing code.") }

            let pairingSnapshot = try await self.pairingReference(code).getDocument()
            guard let pairing = pairingSnapshot.data(),
                  pairing["isOpen"] as? Bool == true,
                  let roomID = pairing["roomID"] as? String,
                  let hostUID = pairing["hostUID"] as? String else {
                throw AppError("That pairing code is not active.")
            }

            try await self.writeLocalParticipant(
                roomID: roomID,
                code: code,
                uid: uid,
                local: local
            )
            self.activateSession(roomID: roomID, code: code, mode: .remote, hostUID: hostUID, local: local)
        }
    }

    func setPairingOpen(_ isOpen: Bool) async {
        guard isHost, let sessionID else { return }
        await performBusyOperation {
            let batch = self.database.batch()
            batch.updateData([
                "pairingOpen": isOpen,
                "updatedAt": FieldValue.serverTimestamp(),
                "activityAt": FieldValue.serverTimestamp()
            ], forDocument: self.roomReference(sessionID))
            batch.updateData(["isOpen": isOpen], forDocument: self.pairingReference(self.pairingCode))
            try await batch.commit()
        }
    }

    func moveParticipant(id: String, by offset: Int) {
        guard turns.isEmpty else { return }
        guard let source = participantOrder.firstIndex(of: id) else { return }
        let destination = source + offset
        guard participantOrder.indices.contains(destination) else { return }
        participantOrder.swapAt(source, destination)
    }

    func prepareMeeting() async {
        guard isHost, let sessionID else { return }
        await performBusyOperation {
            let template = self.selectedTemplate
            let parsedTurns = try OrchestratedScriptParser.parse(
                self.meetingScriptText,
                speakerCount: template.speakerCount
            )
            guard parsedTurns.count <= 450 else {
                throw AppError("This script has \(parsedTurns.count) turns. Shorten it to 450 turns or fewer.")
            }
            let connectedByID = Dictionary(
                uniqueKeysWithValues: self.participants
                    .filter(\.isRecentlyConnected)
                    .map { ($0.id, $0) }
            )
            let ordered = self.participantOrder.compactMap { connectedByID[$0] }
            guard ordered.count >= template.speakerCount else {
                throw AppError("Pair \(template.speakerCount) speakers before preparing this meeting.")
            }
            let assigned = Array(ordered.prefix(template.speakerCount))
            guard self.isSpeakerConfigurationComplete else {
                throw AppError("Configure all speaker names and voices in the main window first.")
            }
            var segmentCounts = Array(repeating: 0, count: template.speakerCount)
            let batch = self.database.batch()
            for (index, parsedTurn) in parsedTurns.enumerated() {
                let participant = assigned[parsedTurn.speakerIndex]
                let speakerConfiguration = self.speakerConfigurations[parsedTurn.speakerIndex]
                let segmentIndex = segmentCounts[parsedTurn.speakerIndex]
                segmentCounts[parsedTurn.speakerIndex] += 1
                var resolvedText = parsedTurn.text
                for configuration in self.speakerConfigurations {
                    resolvedText = resolvedText.replacingOccurrences(
                        of: configuration.placeholder,
                        with: configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                let turnID = String(format: "%05d", index)
                batch.setData([
                    "index": index,
                    "participantUID": participant.id,
                    "speakerName": speakerConfiguration.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "speakerSlot": parsedTurn.speakerIndex + 1,
                    "voiceID": speakerConfiguration.voiceID,
                    "voiceName": speakerConfiguration.voiceName,
                    "scriptTitle": template.title,
                    "segmentIndex": segmentIndex,
                    "text": resolvedText,
                    "status": OrchestrationTurnStatus.queued.rawValue,
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: self.turnReference(roomID: sessionID, turnID: turnID))
            }
            for (speakerIndex, participant) in assigned.enumerated() {
                let configuration = self.speakerConfigurations[speakerIndex]
                batch.updateData([
                    "displayName": configuration.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "scriptTitle": template.title,
                    "voiceName": configuration.voiceName,
                    "segmentCount": segmentCounts[speakerIndex],
                    "preparedSegmentCount": 0,
                    "preparationError": "",
                    "status": "preparing"
                ], forDocument: self.participantReference(roomID: sessionID, uid: participant.id))
            }
            batch.updateData([
                "scriptTemplateID": template.id,
                "scriptTitle": template.title,
                "scriptText": self.meetingScriptText,
                "totalTurns": parsedTurns.count,
                "orderedParticipantIDs": assigned.map(\.id),
                "planRevision": UUID().uuidString,
                "updatedAt": FieldValue.serverTimestamp(),
                "activityAt": FieldValue.serverTimestamp()
            ], forDocument: self.roomReference(sessionID))
            try await batch.commit()
        }
    }

    func startMeeting() async {
        guard isHost, let sessionID else { return }
        await performBusyOperation {
            guard !self.turns.isEmpty else { throw AppError("Prepare the orchestrated script first.") }
            let connected = self.participants.filter(\.isRecentlyConnected)
            let assignedIDs = Set(self.turns.map(\.participantUID))
            guard assignedIDs.allSatisfy({ id in
                connected.first(where: { $0.id == id })?.isFirstTurnPrepared == true
            }) else { throw AppError("Wait until every assigned speaker has prepared a first turn.") }
            let batch = self.database.batch()
            batch.updateData([
                "status": OrchestrationTurnStatus.assigned.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: self.turnReference(roomID: sessionID, turnID: self.turns[0].id))
            batch.updateData([
                "status": OrchestrationSessionStatus.running.rawValue,
                "pairingOpen": false,
                "activeTurnIndex": 0,
                "totalTurns": self.turns.count,
                "startedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
                "activityAt": FieldValue.serverTimestamp()
            ], forDocument: self.roomReference(sessionID))
            batch.updateData(["isOpen": false], forDocument: self.pairingReference(self.pairingCode))
            try await batch.commit()
        }
    }

    func pauseMeeting() async {
        guard isHost, let sessionID, sessionStatus == .running else { return }
        await updateRoom(sessionID, data: [
            "status": OrchestrationSessionStatus.paused.rawValue,
            "updatedAt": FieldValue.serverTimestamp(),
            "activityAt": FieldValue.serverTimestamp()
        ])
    }

    func resumeMeeting() async {
        guard isHost, let sessionID, sessionStatus == .paused else { return }
        await updateRoom(sessionID, data: [
            "status": OrchestrationSessionStatus.running.rawValue,
            "updatedAt": FieldValue.serverTimestamp(),
            "activityAt": FieldValue.serverTimestamp()
        ])
    }

    func skipCurrentTurn() async {
        guard isHost, let sessionID, let turn = activeTurn, !turn.status.isTerminal else { return }
        await performBusyOperation {
            let batch = self.database.batch()
            batch.updateData([
                "status": OrchestrationTurnStatus.skipped.rawValue,
                "endedAtServer": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: self.turnReference(roomID: sessionID, turnID: turn.id))
            self.addRoomActivityBump(to: batch, roomID: sessionID)
            try await batch.commit()
        }
    }

    func stopMeeting() async {
        guard isHost, let sessionID else { return }
        await performBusyOperation {
            let batch = self.database.batch()
            batch.updateData([
                "status": OrchestrationSessionStatus.stopped.rawValue,
                "pairingOpen": false,
                "endedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
                "activityAt": FieldValue.serverTimestamp()
            ], forDocument: self.roomReference(sessionID))
            batch.updateData(["isOpen": false], forDocument: self.pairingReference(self.pairingCode))
            if let turn = self.activeTurn, !turn.status.isTerminal {
                batch.updateData([
                    "status": OrchestrationTurnStatus.stopped.rawValue,
                    "endedAtServer": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: self.turnReference(roomID: sessionID, turnID: turn.id))
            }
            try await batch.commit()
        }
    }

    func leaveSession() async {
        guard let sessionID, let uid = userID else {
            resetLocalSession()
            return
        }

        if isHost, sessionStatus == .running || sessionStatus == .paused {
            await stopMeeting()
        }
        do {
            let batch = database.batch()
            batch.updateData([
                "status": "left",
                "isConnected": false,
                "lastSeenAt": FieldValue.serverTimestamp()
            ], forDocument: participantReference(roomID: sessionID, uid: uid))
            addRoomActivityBump(to: batch, roomID: sessionID)
            try await batch.commit()
            if isHost {
                try await pairingReference(pairingCode).updateData(["isOpen": false])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        resetLocalSession()
    }

    func exportTranscript() throws {
        guard let sessionID else { throw AppError("There is no meeting to export.") }
        let participantByID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        let speakers = participants.map {
            OrchestrationTranscript.Speaker(
                id: $0.id,
                name: $0.displayName,
                scriptTitle: $0.scriptTitle,
                voiceName: $0.voiceName
            )
        }
        let exportedTurns = turns.map { turn in
            let start = turn.startedAtClient ?? turn.startedAtServer
            let end = turn.endedAtClient ?? turn.endedAtServer
            let duration = start.flatMap { start in
                end.map { max(Int($0.timeIntervalSince(start) * 1_000), 0) }
            }
            return OrchestrationTranscript.Turn(
                index: turn.index,
                speakerID: turn.participantUID,
                speakerName: participantByID[turn.participantUID]?.displayName ?? turn.speakerName,
                scriptTitle: turn.scriptTitle,
                speakerSlot: turn.speakerSlot,
                segmentIndex: turn.segmentIndex,
                text: turn.text,
                status: turn.status.rawValue,
                startedAt: start,
                endedAt: end,
                serverReceivedStartedAt: turn.startedAtServer,
                serverReceivedEndedAt: turn.endedAtServer,
                durationMilliseconds: duration,
                error: turn.error
            )
        }
        let transcript = OrchestrationTranscript(
            schemaVersion: 2,
            sessionID: sessionID,
            pairingCode: pairingCode,
            status: sessionStatus.rawValue,
            startedAt: startedAt,
            endedAt: endedAt,
            exportedAt: Date(),
            speakers: speakers,
            turns: exportedTurns
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcript)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "BotSpeaker-\(pairingCode)-transcript.json"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private func prepareLocalSpeaker() throws -> LocalSpeaker {
        guard let model else { throw AppError("The local BotSpeaker session is unavailable.") }
        guard model.hasAPIKey else { throw AppError("Add an ElevenLabs API key before pairing this Mac.") }
        let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError("Enter this speaker’s name.") }
        UserDefaults.standard.set(name, forKey: "orchestrationSpeakerName")
        return LocalSpeaker(
            name: name,
            voiceName: model.selectedVoiceName
        )
    }

    private func ensureSignedIn() async throws -> String {
        if let uid = Auth.auth().currentUser?.uid {
            userID = uid
            return uid
        }
        let result = try await Auth.auth().signInAnonymously()
        userID = result.user.uid
        return result.user.uid
    }

    private func writeLocalParticipant(
        roomID: String,
        code: String,
        uid: String,
        local: LocalSpeaker
    ) async throws {
        let batch = database.batch()
        batch.setData([
            "uid": uid,
            "roomID": roomID,
            "pairingCode": code,
            "displayName": local.name,
            "scriptTitle": "Waiting for host script",
            "voiceName": local.voiceName,
            "segmentCount": 0,
            "preparedSegmentCount": 0,
            "preparationError": "",
            "status": "waiting",
            "isConnected": true,
            "joinedAt": FieldValue.serverTimestamp(),
            "lastSeenAt": FieldValue.serverTimestamp()
        ], forDocument: participantReference(roomID: roomID, uid: uid))
        addRoomActivityBump(to: batch, roomID: roomID)
        try await batch.commit()
    }

    private func activateSession(
        roomID: String,
        code: String,
        mode: OrchestrationMode,
        hostUID: String,
        local: LocalSpeaker
    ) {
        activeMode = mode
        sessionID = roomID
        pairingCode = code
        pairingCodeInput = code
        self.hostUID = hostUID
        localSegments = []
        localScriptTitle = meetingScriptTitle
        localVoiceName = local.voiceName
        preparedLocalSegments = []
        preparedLocalSegmentCount = 0
        preparationStatus = "Waiting for the host script"
        preparationError = nil
        participantOrder = []
        sessionStatus = .lobby
        previousSessionStatus = .lobby
        pairingOpen = true
        errorMessage = nil
        model?.activateRemoteControl(status: "Paired and waiting for the host")
        beginOrchestrationActivity()
        attachListeners(roomID: roomID)
        startHeartbeat(roomID: roomID)
        startExecutionWatchdog()
    }

    private func attachListeners(roomID: String) {
        removeListeners()
        roomListener = roomReference(roomID).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.errorMessage = error.localizedDescription; return }
                guard let data = snapshot?.data() else { return }
                self.applyRoom(data)
            }
        }
        participantsListener = roomReference(roomID)
            .collection("participants")
            .order(by: "joinedAt")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.errorMessage = error.localizedDescription; return }
                    self.applyParticipants(snapshot?.documents ?? [])
                }
            }
        turnsListener = roomReference(roomID)
            .collection("turns")
            .order(by: "index")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.errorMessage = error.localizedDescription; return }
                    self.applyTurns(snapshot?.documents ?? [])
                }
            }
    }

    private func applyRoom(_ data: [String: Any]) {
        previousSessionStatus = sessionStatus
        sessionStatus = OrchestrationSessionStatus(rawValue: data["status"] as? String ?? "") ?? .lobby
        pairingOpen = data["pairingOpen"] as? Bool ?? false
        activeTurnIndex = data["activeTurnIndex"] as? Int ?? -1
        startedAt = Self.date(from: data["startedAt"])
        endedAt = Self.date(from: data["endedAt"])
        meetingScriptTitle = data["scriptTitle"] as? String ?? meetingScriptTitle
        if let scriptText = data["scriptText"] as? String, activeMode == .remote {
            meetingScriptText = scriptText
        }

        switch sessionStatus {
        case .lobby:
            model?.updateRemoteControlStatus("Paired and waiting for the host")
        case .running:
            model?.updateRemoteControlStatus("Remote control active")
            if previousSessionStatus == .paused,
               activeTurn?.participantUID == userID {
                model?.resumeOrchestratedTurn()
            }
        case .paused:
            model?.updateRemoteControlStatus("Paused by the host")
            if activeTurn?.participantUID == userID {
                model?.pauseOrchestratedTurn()
            }
        case .completed:
            cancelPrefetch()
            stopExecutionWatchdog()
            endOrchestrationActivity()
            model?.updateRemoteControlStatus("Meeting completed")
        case .stopped:
            cancelPrefetch()
            stopExecutionWatchdog()
            endOrchestrationActivity()
            model?.updateRemoteControlStatus("Meeting stopped by the host")
            turnExecutionTask?.cancel()
            turnExecutionTask = nil
            activeExecutionTurnID = nil
            hasReportedPlaybackStart = false
            model?.stopOrchestratedTurn()
        }
        maybeExecuteActiveTurn()
    }

    private func applyParticipants(_ documents: [QueryDocumentSnapshot]) {
        participants = documents.compactMap { document in
            let data = document.data()
            guard let displayName = data["displayName"] as? String,
                  let scriptTitle = data["scriptTitle"] as? String else { return nil }
            return OrchestrationParticipant(
                id: document.documentID,
                displayName: displayName,
                scriptTitle: scriptTitle,
                voiceName: data["voiceName"] as? String ?? "Unknown voice",
                segmentCount: data["segmentCount"] as? Int ?? 0,
                preparedSegmentCount: data["preparedSegmentCount"] as? Int ?? 0,
                preparationError: (data["preparationError"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                status: data["status"] as? String ?? "unknown",
                isConnected: data["isConnected"] as? Bool ?? false,
                lastSeenAt: Self.date(from: data["lastSeenAt"])
            )
        }
        let validIDs = Set(participants.map(\.id))
        participantOrder = participantOrder.filter(validIDs.contains)
        for participant in participants where !participantOrder.contains(participant.id) {
            participantOrder.append(participant.id)
        }
    }

    private func applyTurns(_ documents: [QueryDocumentSnapshot]) {
        turns = documents.compactMap { document in
            let data = document.data()
            guard let participantUID = data["participantUID"] as? String,
                  let statusValue = data["status"] as? String,
                  let status = OrchestrationTurnStatus(rawValue: statusValue) else { return nil }
            return OrchestrationTurn(
                id: document.documentID,
                index: data["index"] as? Int ?? 0,
                participantUID: participantUID,
                speakerName: data["speakerName"] as? String ?? "Speaker",
                scriptTitle: data["scriptTitle"] as? String ?? "Script",
                speakerSlot: data["speakerSlot"] as? Int ?? 0,
                voiceID: data["voiceID"] as? String,
                voiceName: data["voiceName"] as? String,
                segmentIndex: data["segmentIndex"] as? Int ?? 0,
                status: status,
                text: data["text"] as? String,
                startedAtClient: Self.date(from: data["startedAtClient"]),
                startedAtServer: Self.date(from: data["startedAtServer"]),
                endedAtClient: Self.date(from: data["endedAtClient"]),
                endedAtServer: Self.date(from: data["endedAtServer"]),
                error: data["error"] as? String
            )
        }
        configureLocalSegmentsFromTurns()
        if let executionTurnID = activeExecutionTurnID,
           let executionTurn = turns.first(where: { $0.id == executionTurnID }),
           executionTurn.status.isTerminal {
            turnExecutionTask?.cancel()
            turnExecutionTask = nil
            activeExecutionTurnID = nil
            hasReportedPlaybackStart = false
            model?.stopOrchestratedTurn()
            model?.updateRemoteControlStatus(
                executionTurn.status == .skipped
                    ? "Turn skipped by the host"
                    : "Turn ended; waiting for the host"
            )
        }
        maybeExecuteActiveTurn()
        scheduleNextPrefetch()
        if isHost, let active = activeTurn, active.status.isTerminal {
            Task { await advanceAfterTerminalTurn(active) }
        }
    }

    private func configureLocalSegmentsFromTurns() {
        guard let uid = userID else { return }
        let assignedTurns = turns
            .filter { $0.participantUID == uid }
            .sorted { $0.segmentIndex < $1.segmentIndex }
        guard !assignedTurns.isEmpty,
              assignedTurns.allSatisfy({ $0.text?.isEmpty == false }) else { return }
        let newSegments = assignedTurns.compactMap(\.text)
        guard newSegments != localSegments else { return }

        cancelPrefetch()
        localSegments = newSegments
        localScriptTitle = assignedTurns[0].scriptTitle
        if let assignedVoiceID = assignedTurns[0].voiceID, !assignedVoiceID.isEmpty {
            model?.voiceID = assignedVoiceID
        }
        localVoiceName = assignedTurns[0].voiceName ?? model?.selectedVoiceName ?? localVoiceName
        preparedLocalSegments = []
        preparedLocalSegmentCount = 0
        preparationError = nil
        preparationStatus = "Preparing first assigned turn…"
        scheduleNextPrefetch()
    }

    private func maybeExecuteActiveTurn() {
        guard sessionStatus == .running,
              let uid = userID,
              let turn = activeTurn,
              turn.participantUID == uid,
              turn.status == .assigned,
              activeExecutionTurnID != turn.id,
              localSegments.indices.contains(turn.segmentIndex),
              let sessionID else { return }

        activeExecutionTurnID = turn.id
        hasReportedPlaybackStart = false
        let text = localSegments[turn.segmentIndex]
        model?.updateRemoteControlStatus("Preparing turn \(turn.index + 1) of \(turns.count)")

        turnExecutionTask?.cancel()
        turnExecutionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeExecutionTurnID == turn.id {
                    self.turnExecutionTask = nil
                }
            }
            do {
                try await self.updateTurn(
                    roomID: sessionID,
                    turnID: turn.id,
                    data: [
                        "status": OrchestrationTurnStatus.preparing.rawValue,
                        "text": text,
                        "updatedAt": FieldValue.serverTimestamp()
                    ]
                )
                try await self.writeEvent(roomID: sessionID, turnID: turn.id, type: "preparing")
                try await self.ensureLocalSegmentPrepared(turn.segmentIndex)
                try Task.checkCancellation()
                try await self.model?.playOrchestratedTurn(
                    text: text,
                    cacheNamespace: self.cacheNamespace(for: turn.segmentIndex)
                )
            } catch is CancellationError {
                return
            } catch {
                await reportTurnFailure(turnID: turn.id, message: error.localizedDescription)
            }
        }
    }

    /// Makes paragraph zero ready in the lobby and immediately begins the next,
    /// then maintains one full local paragraph beyond this speaker's most
    /// recently finished turn. Prefetching
    /// only writes ElevenLabs results to the persistent cache; it never touches
    /// the audio player.
    private func scheduleNextPrefetch() {
        guard isActive, !localSegments.isEmpty, prefetchTask == nil else { return }

        let lookaheadLimit: Int
        if sessionStatus == .lobby || turns.isEmpty {
            lookaheadLimit = min(1, localSegments.count - 1)
        } else {
            let mostRecentTerminalSegment = turns
                .filter { $0.participantUID == userID && $0.status.isTerminal }
                .map(\.segmentIndex)
                .max() ?? -1
            lookaheadLimit = min(mostRecentTerminalSegment + 2, localSegments.count - 1)
        }

        guard lookaheadLimit >= 0,
              let segmentIndex = (0...lookaheadLimit).first(where: {
                  !preparedLocalSegments.contains($0)
              }) else { return }

        startBackgroundPrefetch(segmentIndex)
    }

    private func startBackgroundPrefetch(_ segmentIndex: Int) {
        guard localSegments.indices.contains(segmentIndex), prefetchTask == nil else { return }
        preparationError = nil
        preparationStatus = segmentIndex == 0
            ? "Preparing first turn…"
            : "Preloading paragraph \(segmentIndex + 1)…"
        if sessionStatus == .lobby {
            model?.updateRemoteControlStatus(preparationStatus)
        }

        let task = makePrefetchTask(segmentIndex: segmentIndex)
        prefetchSegmentIndex = segmentIndex
        prefetchTask = task
        prefetchObserverTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await task.value
                guard self.prefetchSegmentIndex == segmentIndex else { return }
                self.clearPrefetchTask()
                self.scheduleNextPrefetch()
            } catch is CancellationError {
                if self.prefetchSegmentIndex == segmentIndex {
                    self.clearPrefetchTask()
                }
            } catch {
                guard self.prefetchSegmentIndex == segmentIndex else { return }
                self.clearPrefetchTask()
                self.preparationError = error.localizedDescription
                self.preparationStatus = "Preparation failed; retrying…"
                await self.publishPreparationState(error: error.localizedDescription)
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, self.isActive else { return }
                self.scheduleNextPrefetch()
            }
        }
    }

    private func ensureLocalSegmentPrepared(_ segmentIndex: Int) async throws {
        guard localSegments.indices.contains(segmentIndex) else {
            throw AppError("The assigned paragraph is unavailable on this Mac.")
        }
        if preparedLocalSegments.contains(segmentIndex) { return }

        if prefetchSegmentIndex == segmentIndex, let prefetchTask {
            try await prefetchTask.value
            return
        }

        cancelPrefetch()
        preparationStatus = "Preparing paragraph \(segmentIndex + 1)…"
        let task = makePrefetchTask(segmentIndex: segmentIndex)
        prefetchSegmentIndex = segmentIndex
        prefetchTask = task
        do {
            try await task.value
            clearPrefetchTask()
            scheduleNextPrefetch()
        } catch {
            clearPrefetchTask()
            throw error
        }
    }

    private func makePrefetchTask(segmentIndex: Int) -> Task<Void, Error> {
        let text = localSegments[segmentIndex]
        let namespace = cacheNamespace(for: segmentIndex)
        return Task { [weak self] in
            guard let self, let model = self.model else { throw CancellationError() }
            try await model.prepareOrchestratedTurn(text: text, cacheNamespace: namespace)
            try Task.checkCancellation()
            self.markLocalSegmentPrepared(segmentIndex)
        }
    }

    private func markLocalSegmentPrepared(_ segmentIndex: Int) {
        preparedLocalSegments.insert(segmentIndex)
        var contiguousCount = 0
        while preparedLocalSegments.contains(contiguousCount) {
            contiguousCount += 1
        }
        preparedLocalSegmentCount = contiguousCount
        preparationError = nil
        preparationStatus = contiguousCount == localSegments.count
            ? "All paragraphs prepared"
            : "\(contiguousCount) paragraph\(contiguousCount == 1 ? "" : "s") prepared"
        if sessionStatus == .lobby {
            model?.updateRemoteControlStatus(
                contiguousCount > 0 ? "First turn ready; waiting for the host" : preparationStatus
            )
        }
        Task { await publishPreparationState(error: nil) }
    }

    private func publishPreparationState(error: String?) async {
        guard let sessionID, let uid = userID else { return }
        var data: [String: Any] = [
            "scriptTitle": localScriptTitle,
            "segmentCount": localSegments.count,
            "preparedSegmentCount": preparedLocalSegmentCount,
            "status": preparedLocalSegmentCount > 0 ? "ready" : "preparing",
            "lastSeenAt": FieldValue.serverTimestamp()
        ]
        data["preparationError"] = error ?? ""
        do {
            let batch = database.batch()
            batch.updateData(data, forDocument: participantReference(roomID: sessionID, uid: uid))
            addRoomActivityBump(to: batch, roomID: sessionID)
            try await batch.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cacheNamespace(for segmentIndex: Int) -> String {
        "orchestration:\(localScriptTitle):\(segmentIndex)"
    }

    private func clearPrefetchTask() {
        prefetchTask = nil
        prefetchSegmentIndex = nil
        prefetchObserverTask = nil
    }

    private func cancelPrefetch() {
        prefetchObserverTask?.cancel()
        prefetchTask?.cancel()
        clearPrefetchTask()
    }

    private func playbackDidStart() {
        guard let turnID = activeExecutionTurnID,
              !hasReportedPlaybackStart,
              let sessionID else { return }
        hasReportedPlaybackStart = true
        model?.updateRemoteControlStatus("Speaking now")
        let clientTime = Date()
        Task {
            do {
                try await updateTurn(
                    roomID: sessionID,
                    turnID: turnID,
                    data: [
                        "status": OrchestrationTurnStatus.speaking.rawValue,
                        "startedAtClient": Timestamp(date: clientTime),
                        "startedAtServer": FieldValue.serverTimestamp(),
                        "updatedAt": FieldValue.serverTimestamp()
                    ]
                )
                try await writeEvent(
                    roomID: sessionID,
                    turnID: turnID,
                    type: "started",
                    clientTimestamp: clientTime
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func playbackDidFinish() {
        guard let turnID = activeExecutionTurnID,
              let sessionID,
              hasReportedPlaybackStart else { return }
        activeExecutionTurnID = nil
        hasReportedPlaybackStart = false
        model?.updateRemoteControlStatus("Turn complete; waiting for the host")
        let clientTime = Date()
        Task {
            do {
                let batch = database.batch()
                batch.updateData([
                    "status": OrchestrationTurnStatus.completed.rawValue,
                    "endedAtClient": Timestamp(date: clientTime),
                    "endedAtServer": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: turnReference(roomID: sessionID, turnID: turnID))
                batch.setData([
                    "type": "completed",
                    "participantUID": userID ?? "",
                    "clientTimestamp": Timestamp(date: clientTime),
                    "timestamp": FieldValue.serverTimestamp()
                ], forDocument: eventReference(roomID: sessionID, turnID: turnID))
                addRoomActivityBump(to: batch, roomID: sessionID)
                try await batch.commit()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reportTurnFailure(turnID: String, message: String) async {
        guard let sessionID else { return }
        activeExecutionTurnID = nil
        hasReportedPlaybackStart = false
        do {
            try await updateTurn(
                roomID: sessionID,
                turnID: turnID,
                data: [
                    "status": OrchestrationTurnStatus.failed.rawValue,
                    "error": message,
                    "endedAtClient": Timestamp(date: Date()),
                    "endedAtServer": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ]
            )
            try await writeEvent(roomID: sessionID, turnID: turnID, type: "failed", error: message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advanceAfterTerminalTurn(_ terminalTurn: OrchestrationTurn) async {
        guard !isAdvancing,
              let sessionID,
              terminalTurn.index == activeTurnIndex else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        do {
            let nextIndex = terminalTurn.index + 1
            let batch = database.batch()
            if turns.indices.contains(nextIndex) {
                let next = turns[nextIndex]
                batch.updateData([
                    "status": OrchestrationTurnStatus.assigned.rawValue,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: turnReference(roomID: sessionID, turnID: next.id))
                batch.updateData([
                    "activeTurnIndex": nextIndex,
                    "updatedAt": FieldValue.serverTimestamp(),
                    "activityAt": FieldValue.serverTimestamp()
                ], forDocument: roomReference(sessionID))
            } else {
                batch.updateData([
                    "status": OrchestrationSessionStatus.completed.rawValue,
                    "activeTurnIndex": turns.count,
                    "endedAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "activityAt": FieldValue.serverTimestamp()
                ], forDocument: roomReference(sessionID))
            }
            try await batch.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func writeEvent(
        roomID: String,
        turnID: String,
        type: String,
        clientTimestamp: Date = Date(),
        error: String? = nil
    ) async throws {
        var data: [String: Any] = [
            "type": type,
            "participantUID": userID ?? "",
            "clientTimestamp": Timestamp(date: clientTimestamp),
            "timestamp": FieldValue.serverTimestamp()
        ]
        if let error { data["error"] = error }
        try await eventReference(roomID: roomID, turnID: turnID).setData(data)
    }

    private func updateTurn(roomID: String, turnID: String, data: [String: Any]) async throws {
        let batch = database.batch()
        batch.updateData(data, forDocument: turnReference(roomID: roomID, turnID: turnID))
        addRoomActivityBump(to: batch, roomID: roomID)
        try await batch.commit()
    }

    /// Touches the room's poll marker in the same batch as a state change so
    /// polling (Windows) clients re-list the participant and turn collections.
    /// This is the one room update the security rules allow participants to
    /// make; heartbeats intentionally skip it.
    private func addRoomActivityBump(to batch: WriteBatch, roomID: String) {
        batch.updateData(
            ["activityAt": FieldValue.serverTimestamp()],
            forDocument: roomReference(roomID)
        )
    }

    private func updateRoom(_ roomID: String, data: [String: Any]) async {
        await performBusyOperation {
            try await self.roomReference(roomID).updateData(data)
        }
    }

    private func startHeartbeat(roomID: String) {
        heartbeatTimer?.cancel()
        heartbeatTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let uid = self.userID else { return }
                Task {
                    try? await self.participantReference(roomID: roomID, uid: uid).updateData([
                        "status": self.localSegments.isEmpty
                            ? "waiting"
                            : self.preparedLocalSegmentCount > 0 ? "ready" : "preparing",
                        "preparedSegmentCount": self.preparedLocalSegmentCount,
                        "preparationError": self.preparationError ?? "",
                        "isConnected": true,
                        "lastSeenAt": FieldValue.serverTimestamp()
                    ])
                }
            }
    }

    /// A paired follower must continue reacting to Firestore assignments while
    /// all of its windows are inactive. This scoped activity prevents App Nap
    /// from suspending the listener and speech-preparation tasks mid-meeting.
    private func beginOrchestrationActivity() {
        endOrchestrationActivity()
        orchestrationActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep a paired BotSpeaker client responsive to meeting turns"
        )
    }

    private func endOrchestrationActivity() {
        guard let orchestrationActivity else { return }
        ProcessInfo.processInfo.endActivity(orchestrationActivity)
        self.orchestrationActivity = nil
    }

    /// Snapshot listeners normally trigger execution immediately. The common-
    /// mode timer also reconciles the local assignment state if a notification
    /// arrives during an AppKit mode transition or while the app is inactive.
    private func startExecutionWatchdog() {
        executionWatchdogTimer?.cancel()
        executionWatchdogTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.maybeExecuteActiveTurn()
                self.scheduleNextPrefetch()
            }
    }

    private func stopExecutionWatchdog() {
        executionWatchdogTimer?.cancel()
        executionWatchdogTimer = nil
    }

    private func performBusyOperation(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetLocalSession() {
        removeListeners()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        stopExecutionWatchdog()
        endOrchestrationActivity()
        model?.deactivateRemoteControl()
        activeMode = nil
        sessionID = nil
        pairingCode = ""
        sessionStatus = .lobby
        previousSessionStatus = .lobby
        pairingOpen = false
        participants = []
        participantOrder = []
        turns = []
        activeTurnIndex = -1
        startedAt = nil
        endedAt = nil
        localSegments = []
        cancelPrefetch()
        preparedLocalSegments = []
        preparedLocalSegmentCount = 0
        preparationStatus = "Not prepared"
        preparationError = nil
        turnExecutionTask?.cancel()
        turnExecutionTask = nil
        activeExecutionTurnID = nil
        hasReportedPlaybackStart = false
    }

    private func removeListeners() {
        roomListener?.remove()
        participantsListener?.remove()
        turnsListener?.remove()
        roomListener = nil
        participantsListener = nil
        turnsListener = nil
    }

    private func roomReference(_ roomID: String) -> DocumentReference {
        database.collection("orchestrationRooms").document(roomID)
    }

    private func pairingReference(_ code: String) -> DocumentReference {
        database.collection("orchestrationPairings").document(code)
    }

    private func participantReference(roomID: String, uid: String) -> DocumentReference {
        roomReference(roomID).collection("participants").document(uid)
    }

    private func turnReference(roomID: String, turnID: String) -> DocumentReference {
        roomReference(roomID).collection("turns").document(turnID)
    }

    private func eventReference(roomID: String, turnID: String) -> DocumentReference {
        turnReference(roomID: roomID, turnID: turnID)
            .collection("events")
            .document()
    }

    private static func date(from value: Any?) -> Date? {
        (value as? Timestamp)?.dateValue()
    }

    private static func makePairingCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return String((0..<6).compactMap { _ in alphabet.randomElement() })
    }

    private struct LocalSpeaker {
        let name: String
        let voiceName: String
    }
}
