import FirebaseFirestore
import Foundation
import OSLog

/// Ad hoc speech: play arbitrary text on this Mac or on a paired attendee,
/// independent of the orchestrated meeting script.
///
/// Local requests never touch Firestore. Remote requests are written by the
/// host to `orchestrationRooms/{roomID}/speechRequests/{id}`, claimed and
/// executed by the targeted attendee, and mirrored back to the host through
/// the collection listener. A scripted meeting turn always preempts ad hoc
/// speech on the same output.
extension OrchestrationController {
    static let speechRequestHistoryLimit = 50

    // MARK: Public API

    func speechRequest(id: String) -> SpeechRequest? {
        speechRequestsByID[id]
    }

    /// Queues text for playback and returns the request ID. Remote targets
    /// require a hosted session; the host's own UID is treated as local.
    @discardableResult
    func speak(text: String, target: SpeechTarget, voiceID: String? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError("Nothing to speak: the text is empty.") }
        guard let model else { throw AppError("The app is not ready.") }

        var resolvedTarget = target
        if case .participant(let uid) = target, uid == userID {
            resolvedTarget = .local
        }

        let normalizedVoiceID = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveVoiceID = normalizedVoiceID?.isEmpty == false ? normalizedVoiceID : nil

        switch resolvedTarget {
        case .local:
            guard model.hasAPIKey else { throw AppError("Add your ElevenLabs API key in Settings.") }
            guard !model.selectedDeviceUID.isEmpty else { throw AppError("Choose an audio output in Settings.") }
            let id = "local-" + UUID().uuidString.lowercased()
            let request = SpeechRequest(
                id: id,
                target: .local,
                targetName: "This Mac",
                text: trimmed,
                voiceID: effectiveVoiceID,
                voiceName: voiceName(for: effectiveVoiceID) ?? model.selectedVoiceName,
                requestedBy: userID ?? "local",
                status: .queued,
                createdAt: Date()
            )
            storeSpeechRequest(request)
            log.notice("Queued local speech request \(id, privacy: .public) (\(trimmed.count) chars)")
            pumpSpeechRequestQueue()
            return id

        case .participant(let uid):
            guard isHost, let sessionID else {
                throw AppError("Remote speech needs a hosted meeting. Start hosting and pair the target Mac first.")
            }
            guard let participant = participants.first(where: { $0.id == uid }) else {
                throw AppError("No attendee with ID \(uid) is in this meeting.")
            }
            guard participant.isRecentlyConnected else {
                throw AppError("\(participant.displayName) is not connected right now.")
            }
            let hostUID = try await ensureSignedIn()
            let reference = roomReference(sessionID).collection("speechRequests").document()
            let now = Date()
            var data: [String: Any] = [
                "targetUID": uid,
                "targetName": participant.displayName,
                "text": trimmed,
                "requestedBy": hostUID,
                "status": SpeechRequestStatus.queued.rawValue,
                "createdAt": Timestamp(date: now),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let effectiveVoiceID {
                data["voiceID"] = effectiveVoiceID
                data["voiceName"] = voiceName(for: effectiveVoiceID) ?? effectiveVoiceID
            }
            let batch = database.batch()
            batch.setData(data, forDocument: reference)
            addRoomActivityBump(to: batch, roomID: sessionID)
            try await batch.commit()

            let request = SpeechRequest(
                id: reference.documentID,
                target: .participant(uid),
                targetName: participant.displayName,
                text: trimmed,
                voiceID: effectiveVoiceID,
                voiceName: effectiveVoiceID.map { voiceName(for: $0) ?? $0 },
                requestedBy: hostUID,
                status: .queued,
                createdAt: now
            )
            // The listener will overwrite this with the server copy.
            storeSpeechRequest(request)
            log.notice("Queued remote speech request \(reference.documentID, privacy: .public) for \(participant.displayName, privacy: .public)")
            return reference.documentID
        }
    }

    /// Cancels a queued or in-flight request. Remote requests are cancelled by
    /// marking the document; the attendee stops playback when it sees the change.
    func cancelSpeech(id: String) async throws {
        guard let request = speechRequestsByID[id] else { throw AppError("Unknown speech request \(id).") }
        guard !request.status.isTerminal else { return }

        switch request.target {
        case .local:
            finalizeLocalSpeechRequest(id: id, status: .cancelled, error: nil, stopPlayback: true)
        case .participant:
            if isHost, let sessionID {
                try await roomReference(sessionID).collection("speechRequests").document(id).updateData([
                    "status": SpeechRequestStatus.cancelled.rawValue,
                    "endedAtClient": Timestamp(date: Date()),
                    "endedAtServer": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            } else if activeSpeechRequestID == id {
                // An attendee cancelling what it is currently speaking.
                await finishRemoteSpeechRequest(id: id, status: .cancelled, error: nil, stopPlayback: true)
            } else {
                throw AppError("Only the host can cancel a remote speech request.")
            }
        }
    }

    /// Cancels everything that is queued or playing.
    func cancelAllSpeech() async {
        for request in speechRequests where !request.status.isTerminal {
            try? await cancelSpeech(id: request.id)
        }
    }

    /// Suspends until the request reaches a terminal state or the timeout
    /// elapses. Returns the latest snapshot either way.
    func waitForSpeechRequest(id: String, timeout: TimeInterval) async -> SpeechRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let request = speechRequestsByID[id] else { return nil }
            if request.status.isTerminal || Date() >= deadline || Task.isCancelled {
                return request
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: Queue

    /// Starts the oldest runnable request when the output is free. Safe to call
    /// often; the watchdog, listener, and completions all pump it.
    func pumpSpeechRequestQueue() {
        guard activeSpeechRequestID == nil,
              activeExecutionTurnID == nil,
              model != nil else { return }
        let runnable = speechRequests.first { request in
            guard request.status == .queued else { return false }
            switch request.target {
            case .local: return true
            case .participant(let uid): return !isHost && uid == userID
            }
        }
        guard let next = runnable else { return }
        switch next.target {
        case .local: executeLocalSpeechRequest(next)
        case .participant: executeRemoteSpeechRequest(next)
        }
    }

    /// Cancels the active request so a scripted turn can take the output.
    func preemptActiveSpeechRequest(reason: String) {
        guard let id = activeSpeechRequestID, let request = speechRequestsByID[id] else { return }
        log.notice("Preempting speech request \(id, privacy: .public): \(reason, privacy: .public)")
        switch request.target {
        case .local:
            finalizeLocalSpeechRequest(id: id, status: .cancelled, error: reason, stopPlayback: true)
        case .participant:
            Task { await finishRemoteSpeechRequest(id: id, status: .cancelled, error: reason, stopPlayback: true) }
        }
    }

    /// Drops mirrored remote requests when a session ends. Any active request,
    /// local or remote, is cancelled because the player is about to reset.
    func clearRemoteSpeechRequests() {
        if let id = activeSpeechRequestID, let request = speechRequestsByID[id] {
            speechExecutionTask?.cancel()
            speechExecutionTask = nil
            activeSpeechRequestID = nil
            hasReportedSpeechStart = false
            var updated = request
            updated.status = .cancelled
            updated.error = "The meeting session ended."
            updated.endedAt = Date()
            speechRequestsByID[id] = updated
        }
        for (id, request) in speechRequestsByID where request.isRemote {
            speechRequestsByID.removeValue(forKey: id)
        }
    }

    // MARK: Local execution

    private func executeLocalSpeechRequest(_ request: SpeechRequest) {
        guard let model else { return }
        activeSpeechRequestID = request.id
        hasReportedSpeechStart = false
        updateSpeechRequest(id: request.id) { $0.status = .preparing }
        setSpeechControlStatus("Preparing ad hoc speech")

        speechExecutionTask?.cancel()
        speechExecutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await model.playOrchestratedTurn(
                    text: request.text,
                    cacheNamespace: "adhoc",
                    voiceID: request.voiceID
                )
                // Playback continues; `speechPlaybackDidFinish` completes the request.
                if self.activeSpeechRequestID == request.id, !model.player.hasAudio {
                    self.finalizeLocalSpeechRequest(id: request.id, status: .failed, error: "No audio was produced.", stopPlayback: false)
                }
            } catch is CancellationError {
                // Cancelled by the queue; state already finalized.
            } catch {
                guard self.activeSpeechRequestID == request.id else { return }
                self.finalizeLocalSpeechRequest(id: request.id, status: .failed, error: error.localizedDescription, stopPlayback: false)
            }
        }
    }

    private func finalizeLocalSpeechRequest(id: String, status: SpeechRequestStatus, error: String?, stopPlayback: Bool) {
        let wasActive = activeSpeechRequestID == id
        if wasActive {
            speechExecutionTask?.cancel()
            speechExecutionTask = nil
            activeSpeechRequestID = nil
            hasReportedSpeechStart = false
        }
        updateSpeechRequest(id: id) {
            $0.status = status
            $0.error = error
            $0.endedAt = Date()
        }
        if wasActive {
            if stopPlayback {
                model?.stopOrchestratedTurn()
            }
            restoreSpeechControlStatus()
            model?.finishAdHocSpeech()
        }
        pumpSpeechRequestQueue()
    }

    // MARK: Remote execution (attendee side)

    private func executeRemoteSpeechRequest(_ request: SpeechRequest) {
        guard let model, let sessionID else { return }
        activeSpeechRequestID = request.id
        hasReportedSpeechStart = false
        let reference = roomReference(sessionID).collection("speechRequests").document(request.id)

        speechExecutionTask?.cancel()
        speechExecutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let claimed = try await self.claimSpeechRequest(reference)
                guard claimed, self.activeSpeechRequestID == request.id else {
                    if self.activeSpeechRequestID == request.id {
                        self.activeSpeechRequestID = nil
                        self.pumpSpeechRequestQueue()
                    }
                    return
                }
                self.updateSpeechRequest(id: request.id) { $0.status = .preparing }
                self.setSpeechControlStatus("Preparing speech from the host")
                try Task.checkCancellation()
                try await model.playOrchestratedTurn(
                    text: request.text,
                    cacheNamespace: "adhoc",
                    voiceID: self.resolveLocalVoiceID(request.voiceID)
                )
                if self.activeSpeechRequestID == request.id, !model.player.hasAudio {
                    await self.finishRemoteSpeechRequest(id: request.id, status: .failed, error: "No audio was produced.", stopPlayback: false)
                }
            } catch is CancellationError {
            } catch {
                guard self.activeSpeechRequestID == request.id else { return }
                await self.finishRemoteSpeechRequest(id: request.id, status: .failed, error: error.localizedDescription, stopPlayback: false)
            }
        }
    }

    private func claimSpeechRequest(_ reference: DocumentReference) async throws -> Bool {
        let uid = userID
        let result = try await database.runTransaction { transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(reference)
                guard let data = snapshot.data(),
                      data["status"] as? String == SpeechRequestStatus.queued.rawValue,
                      data["targetUID"] as? String == uid else { return false }
                transaction.updateData([
                    "status": SpeechRequestStatus.preparing.rawValue,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: reference)
                return true
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
        }
        return result as? Bool ?? false
    }

    private func finishRemoteSpeechRequest(id: String, status: SpeechRequestStatus, error: String?, stopPlayback: Bool) async {
        let wasActive = activeSpeechRequestID == id
        if wasActive {
            speechExecutionTask?.cancel()
            speechExecutionTask = nil
            activeSpeechRequestID = nil
            hasReportedSpeechStart = false
            if stopPlayback { model?.stopOrchestratedTurn() }
            restoreSpeechControlStatus()
        }
        updateSpeechRequest(id: id) {
            $0.status = status
            $0.error = error
            $0.endedAt = Date()
        }
        pumpSpeechRequestQueue()

        guard let sessionID else { return }
        var data: [String: Any] = [
            "status": status.rawValue,
            "endedAtClient": Timestamp(date: Date()),
            "endedAtServer": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let error { data["error"] = error }
        do {
            let batch = database.batch()
            batch.updateData(data, forDocument: roomReference(sessionID).collection("speechRequests").document(id))
            addRoomActivityBump(to: batch, roomID: sessionID)
            try await batch.commit()
        } catch {
            if !isStaleTurnWrite(error) {
                log.error("Failed to report speech request \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Playback callbacks

    func speechPlaybackDidStart() {
        guard let id = activeSpeechRequestID,
              !hasReportedSpeechStart,
              let request = speechRequestsByID[id] else { return }
        hasReportedSpeechStart = true
        let clientTime = Date()
        updateSpeechRequest(id: id) {
            $0.status = .speaking
            $0.startedAt = clientTime
        }
        setSpeechControlStatus(request.isRemote ? "Speaking for the host" : "Speaking ad hoc text")

        guard request.isRemote, let sessionID else { return }
        Task {
            do {
                try await roomReference(sessionID).collection("speechRequests").document(id).updateData([
                    "status": SpeechRequestStatus.speaking.rawValue,
                    "startedAtClient": Timestamp(date: clientTime),
                    "startedAtServer": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            } catch {
                if isStaleTurnWrite(error) {
                    // The host cancelled before we started; the listener will stop us.
                } else {
                    log.error("Failed to mark speech request speaking: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func speechPlaybackDidFinish() {
        guard let id = activeSpeechRequestID, let request = speechRequestsByID[id] else { return }
        switch request.target {
        case .local:
            finalizeLocalSpeechRequest(id: id, status: .completed, error: nil, stopPlayback: false)
        case .participant:
            Task { await finishRemoteSpeechRequest(id: id, status: .completed, error: nil, stopPlayback: false) }
        }
    }

    /// The user stopped or replaced playback from the app itself.
    func speechPlaybackWasTakenOver() {
        guard let id = activeSpeechRequestID, let request = speechRequestsByID[id] else { return }
        let reason = "Playback was stopped in the app."
        switch request.target {
        case .local:
            finalizeLocalSpeechRequest(id: id, status: .cancelled, error: reason, stopPlayback: false)
        case .participant:
            Task { await finishRemoteSpeechRequest(id: id, status: .cancelled, error: reason, stopPlayback: false) }
        }
    }

    // MARK: Firestore mirror

    func attachSpeechRequestsListener(roomID: String) {
        speechRequestsListener?.remove()
        speechRequestsListener = roomReference(roomID)
            .collection("speechRequests")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    self.log.error("speechRequests listener: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let snapshot else { return }
                self.applySpeechRequestSnapshot(snapshot.documents)
            }
    }

    private func applySpeechRequestSnapshot(_ documents: [QueryDocumentSnapshot]) {
        var merged = speechRequestsByID.filter { !$0.value.isRemote }
        for document in documents {
            let data = document.data()
            guard let targetUID = data["targetUID"] as? String,
                  let text = data["text"] as? String else { continue }
            let statusRaw = data["status"] as? String ?? SpeechRequestStatus.queued.rawValue
            let status = SpeechRequestStatus(rawValue: statusRaw) ?? .queued
            let existing = speechRequestsByID[document.documentID]
            merged[document.documentID] = SpeechRequest(
                id: document.documentID,
                target: .participant(targetUID),
                targetName: data["targetName"] as? String ?? existing?.targetName ?? "Attendee",
                text: text,
                voiceID: data["voiceID"] as? String,
                voiceName: data["voiceName"] as? String,
                requestedBy: data["requestedBy"] as? String ?? "",
                status: status,
                createdAt: Self.date(from: data["createdAt"]) ?? existing?.createdAt ?? Date(),
                startedAt: Self.date(from: data["startedAtClient"]) ?? Self.date(from: data["startedAtServer"]),
                endedAt: Self.date(from: data["endedAtClient"]) ?? Self.date(from: data["endedAtServer"]),
                error: (data["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        speechRequestsByID = merged
        trimSpeechRequestHistory()

        // The host cancelled the request this attendee is playing.
        if let id = activeSpeechRequestID,
           let request = speechRequestsByID[id],
           request.isRemote,
           request.status == .cancelled {
            log.notice("Host cancelled speech request \(id, privacy: .public)")
            speechExecutionTask?.cancel()
            speechExecutionTask = nil
            activeSpeechRequestID = nil
            hasReportedSpeechStart = false
            model?.stopOrchestratedTurn()
            restoreSpeechControlStatus()
        }
        pumpSpeechRequestQueue()
    }

    // MARK: Helpers

    private func storeSpeechRequest(_ request: SpeechRequest) {
        speechRequestsByID[request.id] = request
        trimSpeechRequestHistory()
    }

    private func updateSpeechRequest(id: String, _ mutate: (inout SpeechRequest) -> Void) {
        guard var request = speechRequestsByID[id] else { return }
        mutate(&request)
        speechRequestsByID[id] = request
    }

    private func trimSpeechRequestHistory() {
        let terminal = speechRequests.filter { $0.status.isTerminal }
        let overflow = terminal.count - Self.speechRequestHistoryLimit
        guard overflow > 0 else { return }
        for request in terminal.prefix(overflow) {
            speechRequestsByID.removeValue(forKey: request.id)
        }
    }

    private func voiceName(for voiceID: String?) -> String? {
        guard let voiceID, let model else { return nil }
        return model.voices.first(where: { $0.id == voiceID })?.name
    }

    /// Attendees may receive a voice name instead of an ID when the host does
    /// not share the same voice library; map it against the local list.
    private func resolveLocalVoiceID(_ requested: String?) -> String? {
        guard let requested, let model else { return requested }
        if model.voices.contains(where: { $0.id == requested }) { return requested }
        if let match = model.voices.first(where: { $0.name.caseInsensitiveCompare(requested) == .orderedSame }) {
            return match.id
        }
        return requested
    }

    private func setSpeechControlStatus(_ status: String) {
        guard let model, model.isRemoteControlled else { return }
        if remoteControlStatusBeforeSpeech == nil {
            remoteControlStatusBeforeSpeech = model.remoteControlStatus
        }
        model.updateRemoteControlStatus(status)
    }

    private func restoreSpeechControlStatus() {
        guard let model else { return }
        if let previous = remoteControlStatusBeforeSpeech {
            remoteControlStatusBeforeSpeech = nil
            model.updateRemoteControlStatus(previous)
        }
    }
}
