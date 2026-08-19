import AppKit
import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class OrchestrationController: ObservableObject {
    @Published var setupMode: OrchestrationMode = .host
    @Published var speakerName: String
    @Published var pairingCodeInput = ""
    @Published private(set) var activeMode: OrchestrationMode?
    @Published private(set) var sessionID: String?
    @Published private(set) var pairingCode = ""
    @Published private(set) var sessionStatus: OrchestrationSessionStatus = .lobby
    @Published private(set) var pairingOpen = false
    @Published private(set) var participants: [OrchestrationParticipant] = []
    @Published private(set) var participantOrder: [String] = []
    @Published private(set) var turns: [OrchestrationTurn] = []
    @Published private(set) var activeTurnIndex = -1
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private weak var model: AppModel?
    private let database: Firestore
    private var userID: String?
    private var hostUID: String?
    private var localSegments: [String] = []
    private var localScriptTitle = ""
    private var localVoiceName = ""
    private var activeExecutionTurnID: String?
    private var hasReportedPlaybackStart = false
    private var isAdvancing = false
    private var previousSessionStatus: OrchestrationSessionStatus = .lobby
    private var roomListener: ListenerRegistration?
    private var participantsListener: ListenerRegistration?
    private var turnsListener: ListenerRegistration?
    private var heartbeatTimer: AnyCancellable?
    private var playbackObservation: AnyCancellable?
    private var turnExecutionTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        speakerName = UserDefaults.standard.string(forKey: "orchestrationSpeakerName")
            ?? Host.current().localizedName
            ?? "Speaker"

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        database = Firestore.firestore()

        playbackObservation = model.player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self, isPlaying else { return }
                self.playbackDidStart()
            }
        model.player.onPlaybackFinished = { [weak self] in
            self?.playbackDidFinish()
        }
    }

    var isActive: Bool { activeMode != nil }
    var isHost: Bool { activeMode == .host }
    var localParticipantID: String? { userID }

    var activeTurn: OrchestrationTurn? {
        guard turns.indices.contains(activeTurnIndex) else { return nil }
        return turns[activeTurnIndex]
    }

    var canStartMeeting: Bool {
        isHost
            && sessionStatus == .lobby
            && !participants.filter(\.isRecentlyConnected).isEmpty
            && !isBusy
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
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
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
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: self.roomReference(sessionID))
            batch.updateData(["isOpen": isOpen], forDocument: self.pairingReference(self.pairingCode))
            try await batch.commit()
        }
    }

    func moveParticipant(id: String, by offset: Int) {
        guard let source = participantOrder.firstIndex(of: id) else { return }
        let destination = source + offset
        guard participantOrder.indices.contains(destination) else { return }
        participantOrder.swapAt(source, destination)
    }

    func startMeeting() async {
        guard isHost, let sessionID else { return }
        await performBusyOperation {
            let connectedByID = Dictionary(
                uniqueKeysWithValues: self.participants
                    .filter(\.isRecentlyConnected)
                    .map { ($0.id, $0) }
            )
            let ordered = self.participantOrder.compactMap { connectedByID[$0] }
            guard !ordered.isEmpty else { throw AppError("Pair at least one ready speaker.") }

            var plan: [(OrchestrationParticipant, Int)] = []
            let maximumSegments = ordered.map(\.segmentCount).max() ?? 0
            for segmentIndex in 0..<maximumSegments {
                for participant in ordered where segmentIndex < participant.segmentCount {
                    plan.append((participant, segmentIndex))
                }
            }
            guard !plan.isEmpty else { throw AppError("The paired speakers have no script turns.") }
            guard plan.count <= 450 else {
                throw AppError("This session has \(plan.count) turns. Shorten the scripts to 450 turns or fewer.")
            }

            let batch = self.database.batch()
            for (index, item) in plan.enumerated() {
                let turnID = String(format: "%05d", index)
                batch.setData([
                    "index": index,
                    "participantUID": item.0.id,
                    "speakerName": item.0.displayName,
                    "scriptTitle": item.0.scriptTitle,
                    "segmentIndex": item.1,
                    "status": index == 0
                        ? OrchestrationTurnStatus.assigned.rawValue
                        : OrchestrationTurnStatus.queued.rawValue,
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: self.turnReference(roomID: sessionID, turnID: turnID))
            }
            batch.updateData([
                "status": OrchestrationSessionStatus.running.rawValue,
                "pairingOpen": false,
                "activeTurnIndex": 0,
                "totalTurns": plan.count,
                "orderedParticipantIDs": ordered.map(\.id),
                "startedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: self.roomReference(sessionID))
            batch.updateData(["isOpen": false], forDocument: self.pairingReference(self.pairingCode))
            try await batch.commit()
        }
    }

    func pauseMeeting() async {
        guard isHost, let sessionID, sessionStatus == .running else { return }
        await updateRoom(sessionID, data: [
            "status": OrchestrationSessionStatus.paused.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func resumeMeeting() async {
        guard isHost, let sessionID, sessionStatus == .paused else { return }
        await updateRoom(sessionID, data: [
            "status": OrchestrationSessionStatus.running.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func skipCurrentTurn() async {
        guard isHost, let sessionID, let turn = activeTurn, !turn.status.isTerminal else { return }
        await performBusyOperation {
            try await self.turnReference(roomID: sessionID, turnID: turn.id).updateData([
                "status": OrchestrationTurnStatus.skipped.rawValue,
                "endedAtServer": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
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
                "updatedAt": FieldValue.serverTimestamp()
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
            try await participantReference(roomID: sessionID, uid: uid).updateData([
                "status": "left",
                "isConnected": false,
                "lastSeenAt": FieldValue.serverTimestamp()
            ])
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
            schemaVersion: 1,
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
        guard model.selectedScript.isCustom else {
            throw AppError("Choose or replicate a playable script before joining orchestration.")
        }
        let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError("Enter this speaker’s name.") }
        let segments = OrchestrationScriptSegmenter.segments(for: model.text)
        guard !segments.isEmpty else { throw AppError("The selected script is empty.") }
        UserDefaults.standard.set(name, forKey: "orchestrationSpeakerName")
        return LocalSpeaker(
            name: name,
            scriptTitle: model.selectedScript.title,
            voiceName: model.selectedVoiceName,
            segments: segments
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
        try await participantReference(roomID: roomID, uid: uid).setData([
            "uid": uid,
            "roomID": roomID,
            "pairingCode": code,
            "displayName": local.name,
            "scriptTitle": local.scriptTitle,
            "voiceName": local.voiceName,
            "segmentCount": local.segments.count,
            "status": "ready",
            "isConnected": true,
            "joinedAt": FieldValue.serverTimestamp(),
            "lastSeenAt": FieldValue.serverTimestamp()
        ])
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
        localSegments = local.segments
        localScriptTitle = local.scriptTitle
        localVoiceName = local.voiceName
        participantOrder = []
        sessionStatus = .lobby
        previousSessionStatus = .lobby
        pairingOpen = true
        errorMessage = nil
        model?.activateRemoteControl(status: "Paired and waiting for the host")
        attachListeners(roomID: roomID)
        startHeartbeat(roomID: roomID)
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
            model?.updateRemoteControlStatus("Meeting completed")
        case .stopped:
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
        if isHost, let active = activeTurn, active.status.isTerminal {
            Task { await advanceAfterTerminalTurn(active) }
        }
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
                try await self.model?.playOrchestratedTurn(
                    text: text,
                    cacheNamespace: "orchestration:\(self.localScriptTitle):\(turn.segmentIndex)"
                )
            } catch is CancellationError {
                return
            } catch {
                await reportTurnFailure(turnID: turn.id, message: error.localizedDescription)
            }
        }
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
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: roomReference(sessionID))
            } else {
                batch.updateData([
                    "status": OrchestrationSessionStatus.completed.rawValue,
                    "activeTurnIndex": turns.count,
                    "endedAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
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
        try await turnReference(roomID: roomID, turnID: turnID).updateData(data)
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
                        "status": "ready",
                        "isConnected": true,
                        "lastSeenAt": FieldValue.serverTimestamp()
                    ])
                }
            }
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
        let scriptTitle: String
        let voiceName: String
        let segments: [String]
    }
}
