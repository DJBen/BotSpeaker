import Foundation

/// Routes control-server requests to the app model and orchestration
/// controller. Every response is JSON; agents drive this through the
/// `botspeaker` CLI or plain `curl`.
@MainActor
final class ControlAPI {
    private let model: AppModel
    private let orchestration: OrchestrationController

    /// Uploaded audio files are staged here inside the sandbox container,
    /// because the app cannot read arbitrary paths the CLI names.
    static var audioDirectory: URL? {
        ControlServer.discoveryDirectory?.appendingPathComponent("adhoc-audio", isDirectory: true)
    }

    static let maximumAudioBytes = 48 * 1024 * 1024
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac", "ogg", "opus"]

    init(model: AppModel, orchestration: OrchestrationController) {
        self.model = model
        self.orchestration = orchestration
        // Anything left over belongs to a request from a previous launch.
        if let directory = Self.audioDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func handle(_ request: ControlServer.Request) async -> ControlServer.Response {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.first == "v1" else {
            return .error(404, "Unknown path \(request.path). All routes live under /v1.", code: "not_found")
        }
        let route = Array(segments.dropFirst())
        do {
            switch (request.method, route) {
            case ("GET", ["status"]):
                return .ok(statusPayload())
            case ("GET", ["targets"]):
                return .ok(["ok": true, "targets": targetsPayload()])
            case ("GET", ["outputs"]):
                model.refreshAudioDevices()
                return .ok(["ok": true, "outputs": outputsPayload(), "selected": model.selectedDeviceUID])
            case ("POST", ["outputs", "select"]):
                return try selectOutput(request)
            case ("GET", ["voices"]):
                return try await voices(request)
            case ("POST", ["voices", "select"]):
                return try await selectVoice(request)
            case ("POST", ["speak"]):
                return try await speak(request)
            case ("POST", ["play-audio"]), ("POST", ["audio"]):
                return try await playAudio(request)
            case ("GET", ["speech"]):
                return .ok(["ok": true, "requests": orchestration.speechRequests.map(payload(for:))])
            case ("POST", ["speech", "cancel-all"]), ("POST", ["stop"]):
                await orchestration.cancelAllSpeech()
                return .ok(["ok": true, "requests": orchestration.speechRequests.map(payload(for:))])
            case ("GET", _) where route.count == 2 && route[0] == "speech":
                return await speechStatus(id: route[1], request: request)
            case ("POST", _) where route.count == 3 && route[0] == "speech" && route[2] == "cancel":
                let id = route[1]
                try await orchestration.cancelSpeech(id: id)
                guard let updated = orchestration.speechRequest(id: id) else {
                    return .error(404, "Unknown speech request \(id).", code: "not_found")
                }
                return .ok(["ok": true, "request": payload(for: updated)])
            case ("POST", ["session", "host"]):
                return try await host(request)
            case ("POST", ["session", "join"]):
                return try await join(request)
            case ("POST", ["session", "leave"]):
                await orchestration.leaveSession()
                return .ok(["ok": true, "session": orNull(sessionPayload())])
            case ("GET", ["session"]):
                return .ok(["ok": true, "session": orNull(sessionPayload())])
            default:
                return .error(404, "No route for \(request.method) \(request.path).", code: "not_found")
            }
        } catch let error as ControlError {
            return .error(error.status, error.message, code: error.code)
        } catch {
            return .error(400, error.localizedDescription, code: "failed")
        }
    }

    // MARK: Routes

    private func speak(_ request: ControlServer.Request) async throws -> ControlServer.Response {
        guard let body = request.json() else {
            throw ControlError(400, "Send a JSON body with at least a \"text\" field.", code: "bad_request")
        }
        guard let text = body["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError(400, "\"text\" is required and must be non-empty.", code: "bad_request")
        }
        let target = try resolveTarget(body["target"] as? String)
        let voiceID = try await resolveVoiceID(body["voice"] as? String)
        let cycles = try resolveCycles(loop: body["loop"], repeatCount: body["repeat"] ?? body["cycles"])
        let id = try await orchestration.speak(text: text, target: target, voiceID: voiceID, cycles: cycles)
        return try await respond(toRequest: id, body: body)
    }

    /// `{audio: <base64>, filename, target?, loop?, repeat?, wait?, timeout?}`.
    /// The bytes are staged in the app container and played through the same
    /// queue as text, so `wait`, `stop`, and preemption by a meeting turn all
    /// apply. Audio files play on this Mac only.
    private func playAudio(_ request: ControlServer.Request) async throws -> ControlServer.Response {
        guard let body = request.json() else {
            throw ControlError(400, "Send a JSON body with \"audio\" (base64) and \"filename\".", code: "bad_request")
        }
        guard let encoded = body["audio"] as? String, !encoded.isEmpty else {
            throw ControlError(400, "\"audio\" is required: the file contents encoded as base64.", code: "bad_request")
        }
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            throw ControlError(400, "\"audio\" is not valid base64.", code: "bad_request")
        }
        guard data.count <= Self.maximumAudioBytes else {
            throw ControlError(413, "The audio file is larger than \(Self.maximumAudioBytes / (1024 * 1024)) MB.", code: "too_large")
        }
        let filename = ((body["filename"] as? String) ?? "audio")
            .components(separatedBy: "/").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "audio"
        let ext = (filename as NSString).pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) else {
            throw ControlError(
                400,
                "\"\(filename)\" is not a supported audio file. Use one of: \(Self.audioExtensions.sorted().joined(separator: ", ")).",
                code: "unsupported_format"
            )
        }
        let target = try resolveTarget(body["target"] as? String)
        guard target == .local else {
            throw ControlError(400, "Audio files play on this Mac only. Use target \"local\", or speak text to reach an attendee.", code: "local_only")
        }
        let cycles = try resolveCycles(loop: body["loop"], repeatCount: body["repeat"] ?? body["cycles"])

        guard let directory = Self.audioDirectory else {
            throw ControlError(500, "The app has no writable Application Support directory.", code: "storage_unavailable")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
        try data.write(to: staged, options: .atomic)

        let id: String
        do {
            id = try await orchestration.speak(
                text: "♪ \(filename.isEmpty ? staged.lastPathComponent : filename)",
                target: .local,
                cycles: cycles,
                audioURL: staged
            )
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return try await respond(toRequest: id, body: body)
    }

    /// Shared tail of `speak` and `playAudio`: either long-poll for the final
    /// state or return the queued request immediately.
    private func respond(toRequest id: String, body: [String: Any]) async throws -> ControlServer.Response {
        let shouldWait = boolean(body["wait"]) ?? false
        let timeout = (body["timeout"] as? Double) ?? Double(body["timeout"] as? Int ?? 0)
        if shouldWait {
            let waited = await orchestration.waitForSpeechRequest(id: id, timeout: timeout > 0 ? timeout : 600)
            guard let waited else { throw ControlError(500, "The request vanished while waiting.", code: "lost") }
            return .ok(["ok": waited.status == .completed, "request": payload(for: waited), "timedOut": !waited.status.isTerminal])
        }
        guard let created = orchestration.speechRequest(id: id) else {
            throw ControlError(500, "The request was not recorded.", code: "lost")
        }
        return ControlServer.Response(status: 202, body: ["ok": true, "request": payload(for: created)])
    }

    /// `loop: true` repeats until cancelled; `repeat: n` plays n times.
    private func resolveCycles(loop: Any?, repeatCount: Any?) throws -> Int? {
        let wantsLoop = boolean(loop) ?? false
        let count: Int? = switch repeatCount {
        case nil, is NSNull: nil
        case let number as Int: number
        case let number as Double: Int(number)
        case let number as NSNumber: number.intValue
        case let string as String: Int(string.trimmingCharacters(in: .whitespaces))
        default: -1
        }
        if wantsLoop {
            guard count == nil else { throw ControlError(400, "Use either \"loop\" or \"repeat\", not both.", code: "bad_request") }
            return nil
        }
        guard let count else { return 1 }
        guard count >= 1 else { throw ControlError(400, "\"repeat\" must be a whole number of at least 1.", code: "bad_request") }
        return count
    }

    private func speechStatus(id: String, request: ControlServer.Request) async -> ControlServer.Response {
        guard var current = orchestration.speechRequest(id: id) else {
            return .error(404, "Unknown speech request \(id).", code: "not_found")
        }
        if boolean(request.query["wait"]) == true, !current.status.isTerminal {
            let timeout = Double(request.query["timeout"] ?? "") ?? 600
            if let waited = await orchestration.waitForSpeechRequest(id: id, timeout: timeout) {
                current = waited
            }
        }
        return .ok(["ok": true, "request": payload(for: current), "timedOut": !current.status.isTerminal])
    }

    private func selectOutput(_ request: ControlServer.Request) throws -> ControlServer.Response {
        let body = request.json() ?? [:]
        let wanted = ((body["uid"] ?? body["name"] ?? body["output"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wanted.isEmpty else { throw ControlError(400, "Send {\"uid\": ...} or {\"name\": ...}.", code: "bad_request") }
        model.refreshAudioDevices()
        let devices = model.devices.outputDevices
        guard let match = devices.first(where: { $0.uid == wanted })
                ?? devices.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
                ?? devices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
            throw ControlError(404, "No output device matches \"\(wanted)\".", code: "not_found")
        }
        model.selectedDeviceUID = match.uid
        return .ok(["ok": true, "selected": ["uid": match.uid, "name": match.name]])
    }

    private func voices(_ request: ControlServer.Request) async throws -> ControlServer.Response {
        if boolean(request.query["refresh"]) == true {
            await model.refreshVoices()
        } else {
            await model.loadVoicesIfNeeded()
        }
        if let error = model.voiceLoadError, model.voices.isEmpty {
            throw ControlError(502, error, code: "voices_unavailable")
        }
        return .ok([
            "ok": true,
            "selected": model.voiceID,
            "voices": model.voices.map { voice in
                [
                    "id": voice.id,
                    "name": voice.name,
                    "category": voice.category ?? "",
                    "detail": voice.detail
                ]
            }
        ])
    }

    private func selectVoice(_ request: ControlServer.Request) async throws -> ControlServer.Response {
        let body = request.json() ?? [:]
        let wanted = ((body["id"] ?? body["name"] ?? body["voice"]) as? String) ?? ""
        guard let voiceID = try await resolveVoiceID(wanted) else {
            throw ControlError(400, "Send {\"id\": ...} or {\"name\": ...}.", code: "bad_request")
        }
        model.voiceID = voiceID
        return .ok(["ok": true, "selected": ["id": voiceID, "name": model.selectedVoiceName]])
    }

    private func host(_ request: ControlServer.Request) async throws -> ControlServer.Response {
        let body = request.json() ?? [:]
        if let name = body["speakerName"] as? String, !name.isEmpty {
            orchestration.speakerName = name
        }
        if orchestration.isActive, !orchestration.isHost {
            throw ControlError(409, "This Mac is joined to a meeting as an attendee. Leave it before hosting.", code: "conflict")
        }
        if !orchestration.isActive {
            await orchestration.startHosting()
        }
        if let error = orchestration.errorMessage, !orchestration.isActive {
            throw ControlError(500, error, code: "host_failed")
        }
        return .ok(["ok": true, "session": orNull(sessionPayload())])
    }

    private func join(_ request: ControlServer.Request) async throws -> ControlServer.Response {
        let body = request.json() ?? [:]
        guard let code = body["code"] as? String, !code.isEmpty else {
            throw ControlError(400, "Send {\"code\": \"ABC123\"}.", code: "bad_request")
        }
        if let name = body["speakerName"] as? String, !name.isEmpty {
            orchestration.speakerName = name
        }
        if orchestration.isActive {
            throw ControlError(409, "This Mac is already in a meeting. Leave it before joining another.", code: "conflict")
        }
        orchestration.pairingCodeInput = code
        await orchestration.joinMeeting()
        if !orchestration.isActive {
            throw ControlError(500, orchestration.errorMessage ?? "Joining failed.", code: "join_failed")
        }
        return .ok(["ok": true, "session": orNull(sessionPayload())])
    }

    // MARK: Resolution

    private func resolveTarget(_ raw: String?) throws -> SpeechTarget {
        let wanted = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty || ["local", "this", "self", "here"].contains(wanted.lowercased()) {
            return .local
        }
        if let local = orchestration.localParticipantID, wanted == local {
            return .local
        }
        let participants = orchestration.participants.filter { $0.id != orchestration.localParticipantID }
        if let match = participants.first(where: { $0.id == wanted })
            ?? participants.first(where: { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? participants.first(where: { $0.displayName.localizedCaseInsensitiveContains(wanted) }) {
            return .participant(match.id)
        }
        if !orchestration.isHost {
            throw ControlError(409, "Remote targets are only available while this Mac hosts a meeting. Use target \"local\" or host first.", code: "not_hosting")
        }
        let names = participants.map(\.displayName).joined(separator: ", ")
        throw ControlError(404, "No attendee matches \"\(wanted)\". Connected attendees: \(names.isEmpty ? "none" : names).", code: "not_found")
    }

    private func resolveVoiceID(_ raw: String?) async throws -> String? {
        let wanted = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wanted.isEmpty else { return nil }
        if wanted.lowercased() == "default" { return nil }
        await model.loadVoicesIfNeeded()
        if model.voices.contains(where: { $0.id == wanted }) { return wanted }
        if let match = model.voices.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? model.voices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) {
            return match.id
        }
        // Not in this account's library; pass it through as a raw ElevenLabs voice ID.
        if wanted.count >= 16, wanted.allSatisfy({ $0.isLetter || $0.isNumber }) { return wanted }
        let names = model.voices.prefix(12).map(\.name).joined(separator: ", ")
        throw ControlError(404, "No voice matches \"\(wanted)\". Try one of: \(names).", code: "not_found")
    }

    // MARK: Payloads

    private func statusPayload() -> [String: Any] {
        let output = model.devices.outputDevices.first { $0.uid == model.selectedDeviceUID }
        let active = orchestration.speechRequests.last { !$0.status.isTerminal }
        return [
            "ok": true,
            "app": [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "pid": Int(ProcessInfo.processInfo.processIdentifier)
            ],
            "apiKeyConfigured": model.hasAPIKey,
            "output": orNull(output.map { ["uid": $0.uid, "name": $0.name] }),
            "voice": ["id": model.voiceID, "name": model.selectedVoiceName],
            "player": [
                "isPlaying": model.player.isPlaying,
                "isGenerating": model.isGenerating,
                "isRemoteControlled": model.isRemoteControlled,
                "remoteControlStatus": model.remoteControlStatus
            ],
            "session": orNull(sessionPayload()),
            "activeSpeech": orNull(active.map(payload(for:))),
            "pendingSpeechCount": orchestration.speechRequests.filter { !$0.status.isTerminal }.count
        ]
    }

    private func sessionPayload() -> [String: Any]? {
        guard let mode = orchestration.activeMode else { return nil }
        return [
            "mode": mode.rawValue,
            "roomID": orchestration.sessionID ?? "",
            "code": orchestration.pairingCode,
            "status": orchestration.sessionStatus.rawValue,
            "isHost": orchestration.isHost,
            "localUID": orchestration.localParticipantID ?? "",
            "speakerName": orchestration.speakerName,
            "attendees": attendeesPayload()
        ]
    }

    private func attendeesPayload() -> [[String: Any]] {
        orchestration.participants.map { participant in
            [
                "id": participant.id,
                "name": participant.displayName,
                "voiceName": participant.voiceName,
                "connected": participant.isRecentlyConnected,
                "isThisMac": participant.id == orchestration.localParticipantID
            ]
        }
    }

    private func targetsPayload() -> [[String: Any]] {
        var targets: [[String: Any]] = [[
            "id": "local",
            "name": "This Mac",
            "kind": "local",
            "connected": true,
            "output": model.devices.outputDevices.first { $0.uid == model.selectedDeviceUID }?.name ?? ""
        ]]
        guard orchestration.isHost else { return targets }
        for participant in orchestration.participants where participant.id != orchestration.localParticipantID {
            targets.append([
                "id": participant.id,
                "name": participant.displayName,
                "kind": "attendee",
                "connected": participant.isRecentlyConnected,
                "voiceName": participant.voiceName
            ])
        }
        return targets
    }

    private func outputsPayload() -> [[String: Any]] {
        model.devices.outputDevices.map { ["uid": $0.uid, "name": $0.name, "selected": $0.uid == model.selectedDeviceUID] }
    }

    private func payload(for request: SpeechRequest) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": request.id,
            "target": request.target.participantUID ?? "local",
            "targetName": request.targetName,
            "remote": request.isRemote,
            "text": request.text,
            "status": request.status.rawValue,
            "createdAt": formatter.string(from: request.createdAt)
        ]
        payload["voiceID"] = orNull(request.voiceID)
        payload["voiceName"] = orNull(request.voiceName)
        payload["startedAt"] = orNull(request.startedAt.map(formatter.string(from:)))
        payload["endedAt"] = orNull(request.endedAt.map(formatter.string(from:)))
        payload["error"] = orNull(request.error)
        payload["loop"] = request.cycles == nil
        payload["cycles"] = orNull(request.cycles)
        payload["completedCycles"] = request.completedCycles
        payload["kind"] = request.isAudioFile ? "audio" : "text"
        payload["audioFile"] = orNull(request.isAudioFile ? String(request.text.drop(while: { $0 == "♪" || $0 == " " })) : nil)
        return payload
    }

    private func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private func boolean(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off", "": return false
            default: return nil
            }
        default: return nil
        }
    }
}

struct ControlError: Error {
    let status: Int
    let message: String
    let code: String

    init(_ status: Int, _ message: String, code: String) {
        self.status = status
        self.message = message
        self.code = code
    }
}
