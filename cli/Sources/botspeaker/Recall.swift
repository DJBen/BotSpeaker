import ArgumentParser
import Foundation
import Darwin

struct Recall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Control Recall meeting bots and schedule prerecorded speech.", discussion: "Actions: configure, status, list, add, remove, remove-all, speak, prepare, dispatch, cancel, wait, meeting-create, meeting-start, meeting-status, meeting-skip, meeting-stop, meeting-wait. Use --meeting for scoped list/removal, --file for invitations or JSON plans, and --wait for speech or meeting completion. Keep the app running and awake. Scheduling controls dispatch, not exact playback. Cancellation stops future dispatches only.")
    @OptionGroup var global: GlobalOptions
    @Argument var action: String = "status"
    @Argument var arguments: [String] = []
    @Option var region: String?
    @Option var name: String = "BotSpeaker"
    @Option(help: "ElevenLabs voice ID; defaults to the app's selected voice.") var voice: String?
    @Option(help: "now, +SECONDS, or ISO 8601 timestamp with timezone.") var at: String?
    @Option(help: "Extra gap between clips in seconds.") var interval: Double?
    @Option(name: [.customLong("repeat"), .customShort("r")]) var repeatCount: Int?
    @Flag(name: [.long, .customShort("l")]) var loop = false
    @Flag(help: "Read the Recall key from stdin rather than a hidden prompt.") var keyStdin = false
    @Option(name: [.short, .long]) var file: String?

    @Option(help: "Meeting URL or ID for list and remove-all.") var meeting: String?
    @Option(help: "Teams passcode when adding by meeting ID.") var passcode: String?
    @Flag(name: [.short, .long], help: "Wait for speak, prepare, dispatch, or meeting-start.") var wait = false
    @Option(help: "Maximum wait in seconds; work continues after timeout.") var timeout: Double = 3600

    func validate() throws {
        guard ["configure", "status", "list", "add", "remove", "remove-all", "speak", "prepare", "dispatch", "cancel", "wait", "meeting-create", "meeting-start", "meeting-status", "meeting-skip", "meeting-stop", "meeting-wait"].contains(action) else { throw ValidationError("Unknown Recall action.") }
        if loop && repeatCount != nil { throw ValidationError("Use --loop or --repeat, not both.") }
        if let repeatCount, repeatCount < 1 { throw ValidationError("--repeat must be positive.") }
        if let interval, !interval.isFinite || interval < 0 || interval > 86400 { throw ValidationError("--interval must be finite and between 0 and 86400 seconds.") }
        guard timeout.isFinite, timeout > 0 else { throw ValidationError("--timeout must be finite and positive.") }
        if wait && !["speak", "prepare", "dispatch", "meeting-start"].contains(action) { throw ValidationError("--wait is only supported for speak, prepare, dispatch, and meeting-start.") }
        if action != "speak" && (at != nil || loop || repeatCount != nil || interval != nil) { throw ValidationError("Scheduling and repeat options require speak.") }
        if file != nil && !["add", "speak", "prepare", "meeting-create"].contains(action) { throw ValidationError("--file requires add, speak, prepare, or meeting-create.") }
        if meeting != nil && !["list", "remove-all"].contains(action) { throw ValidationError("--meeting requires list or remove-all.") }
        if passcode != nil && action != "add" { throw ValidationError("--passcode requires add.") }
        if voice != nil && !["speak", "prepare"].contains(action) { throw ValidationError("--voice requires speak or prepare.") }
        if keyStdin && action != "configure" { throw ValidationError("--key-stdin requires configure.") }
        let needsID = ["remove", "speak", "prepare", "dispatch", "cancel", "wait", "meeting-start", "meeting-status", "meeting-skip", "meeting-stop", "meeting-wait"].contains(action)
        if needsID && arguments.isEmpty { throw ValidationError("An ID is required.") }
        if action == "add" && file == nil && arguments.isEmpty { throw ValidationError("A meeting invitation, URL, or ID is required.") }
        if action == "remove-all" && (meeting ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("--meeting is required for remove-all.") }
        if action == "meeting-create" && file == nil { throw ValidationError("--file is required for meeting-create.") }
        let maximum = ["speak", "prepare"].contains(action) ? Int.max : (needsID || action == "add" ? 1 : 0)
        if arguments.count > maximum { throw ValidationError("Unexpected positional arguments.") }
    }
    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let env = ProcessInfo.processInfo.environment
            var body: [String: Any] = [:]
            if action == "configure" {
                var key = env["RECALL_API_KEY"] ?? env["RECALL_AI_API_KEY"]
                if keyStdin { key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                else if key == nil, isatty(STDIN_FILENO) != 0, let entered = getpass("Recall API key (blank keeps saved key): ") { key = String(cString: entered) }
                if let key, !key.isEmpty { body["apiKey"] = key }
                if let region { body["region"] = region }
            } else if let key = env["RECALL_API_KEY"] ?? env["RECALL_AI_API_KEY"] {
                let status = try await client.post("/v1/recall/status")
                if status["configured"] as? Bool != true {
                    var config: [String: Any] = ["apiKey": key]
                    if let region { config["region"] = region }
                    _ = try await client.post("/v1/recall/configure", body: config)
                }
            }
            func read(_ path: String) throws -> String {
                path == "-" ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" : try String(contentsOfFile: path, encoding: .utf8)
            }
            if let meeting { body["meetingId"] = meeting }
            if action == "add" {
                body["meetingUrl"] = try file.map(read) ?? arguments.first
                body["name"] = name
                if let passcode { body["passcode"] = passcode }
            }
            if ["remove", "speak", "prepare"].contains(action) { body["botId"] = arguments.first }
            if ["cancel", "dispatch", "wait", "meeting-start", "meeting-status", "meeting-skip", "meeting-stop", "meeting-wait"].contains(action) { body["id"] = arguments.first }
            if action == "meeting-create" {
                guard let data = try read(file!).data(using: .utf8),
                      let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ValidationError("Meeting plan must be a JSON object.") }
                body = plan
            }
            if action == "speak" || action == "prepare" {
                let text = try file.map(read) ?? arguments.dropFirst().joined(separator: " ")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("Speech text is required.") }
                body["text"] = text
                if let voice { body["voice"] = voice }
                if action == "speak" {
                    body["at"] = at ?? "now"; body["loop"] = loop; body["interval"] = interval ?? 0
                    if let repeatCount { body["repeat"] = repeatCount }
                }
            }
            var response: [String: Any]
            if action == "wait" || action == "meeting-wait" {
                response = try await waitFor(arguments[0], meeting: action == "meeting-wait", prepared: false, client: client)
            } else {
                response = try await client.post("/v1/recall/" + action, body: body)
                if wait {
                    let isMeeting = action == "meeting-start"
                    guard let id = (response[isMeeting ? "meeting" : "job"] as? [String: Any])?["id"] as? String else { throw ValidationError("Recall did not return an ID.") }
                    response = try await waitFor(id, meeting: isMeeting, prepared: action == "prepare", client: client)
                }
            }
            Output.json(response)
            if response["ok"] as? Bool == false { throw ExitCode(1) }
        } catch let exit as ExitCode { throw exit }
        catch let error as ValidationError {
            Output.fail(ControlClient.Failure(exitCode: 1, code: "recall_error", message: error.message), json: global.json)
        }
        catch { Output.fail(error, json: global.json) }
    }

    private func waitFor(_ id: String, meeting: Bool, prepared: Bool, client: ControlClient) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            let response = try await client.post("/v1/recall/" + (meeting ? "meeting-status" : "status"), body: ["id": id], timeout: max(0.001, seconds))
            let item = meeting ? response["meeting"] as? [String: Any] : (response["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == id }
            guard let item else { throw ValidationError("Unknown Recall job or meeting.") }
            let state = item["status"] as? String ?? ""
            if ["failed", "cancelled", "stopped"].contains(state) { throw ValidationError(item["error"] as? String ?? "Recall work was \(state).") }
            if state == (meeting ? "finished" : prepared ? "prepared" : "finished_dispatching") { return ["ok": true, meeting ? "meeting" : "job": item] }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("Timed out waiting for Recall. Work continues in the app; use cancel or meeting-stop to stop it.")
    }
}
