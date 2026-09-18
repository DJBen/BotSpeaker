import ArgumentParser
import Foundation
import Darwin

struct Recall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Control Recall meeting bots and schedule prerecorded speech.", discussion: "Actions: configure, status, list, add MEETING_URL, remove BOT_ID, speak BOT_ID TEXT, cancel JOB_ID. Keep the app running and awake. Scheduling controls dispatch, not exact playback. Cancellation stops future dispatches only.")
    @OptionGroup var global: GlobalOptions
    @Argument var action: String = "status"
    @Argument var arguments: [String] = []
    @Option var region: String?
    @Option var name: String = "BotSpeaker"
    @Option(help: "ElevenLabs voice ID; defaults to the app's selected voice.") var voice: String?
    @Option(help: "now, +SECONDS, or ISO 8601 timestamp with timezone.") var at: String = "now"
    @Option(help: "Extra gap between clips in seconds.") var interval: Double = 0
    @Option(name: .customLong("repeat")) var repeatCount: Int?
    @Flag var loop = false
    @Flag(help: "Read the Recall key from stdin rather than a hidden prompt.") var keyStdin = false
    @Option(name: [.short, .long]) var file: String?

    func validate() throws {
        guard ["configure", "status", "list", "add", "remove", "speak", "cancel"].contains(action) else { throw ValidationError("Unknown Recall action.") }
        if loop && repeatCount != nil { throw ValidationError("Use --loop or --repeat, not both.") }
        if let repeatCount, repeatCount < 1 { throw ValidationError("--repeat must be positive.") }
        guard interval.isFinite, interval >= 0 else { throw ValidationError("--interval must be nonnegative seconds.") }
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
            if action == "add" { body["meetingUrl"] = arguments.first; body["name"] = name }
            if action == "remove" || action == "speak" { body["botId"] = arguments.first }
            if action == "cancel" { body["id"] = arguments.first }
            if action == "speak" {
                let text: String
                if let file { text = file == "-" ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" : try String(contentsOfFile: file, encoding: .utf8) }
                else { text = arguments.dropFirst().joined(separator: " ") }
                body["text"] = text; body["at"] = at; body["loop"] = loop; body["interval"] = interval
                if let repeatCount { body["repeat"] = repeatCount }
                if let voice { body["voice"] = voice }
            }
            Output.json(try await client.post("/v1/recall/" + action, body: body))
        } catch { Output.fail(error, json: global.json) }
    }
}
