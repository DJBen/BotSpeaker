import ArgumentParser
import Foundation

@main
struct BotSpeakerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "botspeaker",
        abstract: "Drive the BotSpeaker app: play text on this Mac or on a paired attendee.",
        discussion: """
        The CLI launches the app in the background if it is not running. Pair machines by hosting on one Mac (`botspeaker host`) and joining \
        from the other (`botspeaker join CODE`), then `botspeaker speak --target NAME "text"` plays \
        on that attendee. Without --target, text plays on this Mac.

        Exit codes: 0 success, 1 request failed, 2 app unreachable.
        """,
        version: BotSpeakerCLIVersion.current,
        subcommands: [
            Speak.self, PlayAudio.self, Stop.self, Status.self, Targets.self, Voices.self, Outputs.self,
            Requests.self, Wait.self, Host.self, Join.self, Leave.self, Upgrade.self
        ],
        defaultSubcommand: Status.self
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false
}

// MARK: - speak

struct Speak: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Speak text on this Mac or on a paired attendee.")

    @OptionGroup var global: GlobalOptions

    @Option(name: [.short, .long], help: "Where to play: \"local\" (default), an attendee name, or an attendee UID.")
    var target: String = "local"

    @Option(name: [.short, .long], help: "Voice name or ElevenLabs voice ID. Defaults to the target's configured voice.")
    var voice: String?

    @Flag(name: [.customShort("w"), .long], help: "Block until playback finishes and report the final status.")
    var wait = false

    @Option(name: .long, help: "Seconds to wait when --wait is set.")
    var timeout: Double = 600

    @Option(name: [.customShort("f"), .long], help: "Read the text from a file (\"-\" for stdin).")
    var file: String?

    @Flag(name: [.customShort("l"), .long], help: "Play the text on a cycle until `botspeaker stop` cancels it.")
    var loop = false

    @Option(name: [.customShort("r"), .customLong("repeat")], help: "Play the text this many times.")
    var repeatCount: Int?

    @Argument(help: "Text to speak. Omit to read from --file or stdin. Use \"--\" before text that starts with a dash.")
    var text: [String] = []

    func validate() throws {
        if let repeatCount, repeatCount < 1 {
            throw ValidationError("--repeat must be at least 1.")
        }
        if loop, repeatCount != nil {
            throw ValidationError("Use either --loop or --repeat, not both.")
        }
    }

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let spoken = try resolveText()
            var body: [String: Any] = ["text": spoken, "target": target, "wait": wait, "timeout": timeout, "loop": loop]
            if let repeatCount { body["repeat"] = repeatCount }
            if let voice { body["voice"] = voice }
            let response = try await client.post("/v1/speak", body: body)
            let request = response["request"] as? [String: Any] ?? [:]
            if global.json {
                Output.json(response)
            } else {
                let status = Output.string(request["status"])
                let id = Output.string(request["id"])
                let targetName = Output.string(request["targetName"])
                let passes = Output.cycles(of: request).map { " [\($0)]" } ?? ""
                let appIgnoredCycles = (loop || repeatCount != nil) && request["loop"] == nil
                if appIgnoredCycles {
                    FileHandle.standardError.write(Data("note: this BotSpeaker app does not support --loop/--repeat; the text plays once. Update the app.\n".utf8))
                }
                if wait {
                    let detail = request["error"] as? String
                    print("\(status) on \(targetName)\(passes) (\(id))\(detail.map { ": \($0)" } ?? "")")
                } else if loop, !appIgnoredCycles {
                    print("\(status) on \(targetName)\(passes) (\(id)) — loops until `botspeaker stop \(id)`")
                } else {
                    print("\(status) on \(targetName)\(passes) (\(id)) — use `botspeaker wait \(id)` to follow it")
                }
            }
            if wait, request["status"] as? String != "completed" {
                throw ExitCode(1)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Output.fail(error, json: global.json)
        }
    }

    private func resolveText() throws -> String {
        if let file {
            let data: Data
            if file == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            }
            guard let string = String(data: data, encoding: .utf8) else {
                throw ControlClient.Failure(exitCode: 1, code: "bad_input", message: "\(file) is not UTF-8 text.")
            }
            return string
        }
        let joined = text.joined(separator: " ")
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return joined }
        if isatty(STDIN_FILENO) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let string = String(data: data, encoding: .utf8), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        throw ControlClient.Failure(exitCode: 1, code: "bad_input", message: "Give the text as an argument, via --file, or on stdin.")
    }
}

// MARK: - play-audio

struct PlayAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play-audio",
        abstract: "Play an audio file (mp3, wav, m4a, aiff, ...) through BotSpeaker's output on this Mac.",
        discussion: """
        The file is uploaded to the running app and queued like spoken text, so `--wait`, \
        `botspeaker stop`, and `botspeaker requests` all apply. A scripted meeting turn preempts it. \
        Audio files play locally only; use `speak --target` to reach a paired attendee.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Path to the audio file to play.", completion: .file())
    var file: String

    @Flag(name: [.customShort("w"), .long], help: "Block until playback finishes and report the final status.")
    var wait = false

    @Option(name: .long, help: "Seconds to wait when --wait is set.")
    var timeout: Double = 600

    @Flag(name: [.customShort("l"), .long], help: "Play the file on a cycle until `botspeaker stop` cancels it.")
    var loop = false

    @Option(name: [.customShort("r"), .customLong("repeat")], help: "Play the file this many times.")
    var repeatCount: Int?

    static let supportedExtensions = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac", "ogg", "opus"]

    func validate() throws {
        if let repeatCount, repeatCount < 1 {
            throw ValidationError("--repeat must be at least 1.")
        }
        if loop, repeatCount != nil {
            throw ValidationError("Use either --loop or --repeat, not both.")
        }
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No file at \(file).")
        }
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ValidationError("\(url.lastPathComponent) is not a supported audio file. Use one of: \(Self.supportedExtensions.joined(separator: ", ")).")
        }
    }

    func run() async throws {
        do {
            let url = URL(fileURLWithPath: file)
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw ControlClient.Failure(exitCode: 1, code: "bad_input", message: "\(url.lastPathComponent) is empty.")
            }
            let client = try await ControlClient.locate()
            var body: [String: Any] = [
                "audio": data.base64EncodedString(),
                "filename": url.lastPathComponent,
                "target": "local",
                "wait": wait,
                "timeout": timeout,
                "loop": loop
            ]
            if let repeatCount { body["repeat"] = repeatCount }
            let response = try await client.post("/v1/play-audio", body: body)
            let request = response["request"] as? [String: Any] ?? [:]
            if global.json {
                Output.json(response)
            } else {
                let status = Output.string(request["status"])
                let id = Output.string(request["id"])
                let passes = Output.cycles(of: request).map { " [\($0)]" } ?? ""
                if wait {
                    let detail = request["error"] as? String
                    print("\(status) \(url.lastPathComponent)\(passes) (\(id))\(detail.map { ": \($0)" } ?? "")")
                } else if loop {
                    print("\(status) \(url.lastPathComponent)\(passes) (\(id)) — loops until `botspeaker stop \(id)`")
                } else {
                    print("\(status) \(url.lastPathComponent)\(passes) (\(id)) — use `botspeaker wait \(id)` to follow it")
                }
            }
            if wait, request["status"] as? String != "completed" {
                throw ExitCode(1)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

// MARK: - stop / wait / requests

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Cancel one speech request, or everything queued and playing.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Request ID to cancel. Omit to cancel all.")
    var id: String?

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let response: [String: Any]
            if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                response = try await client.post("/v1/speech/\(id)/cancel")
            } else {
                response = try await client.post("/v1/speech/cancel-all")
            }
            if global.json {
                Output.json(response)
            } else if let request = response["request"] as? [String: Any] {
                print("\(Output.string(request["status"])) (\(Output.string(request["id"])))")
            } else {
                print("cancelled all pending speech")
            }
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait for a speech request to finish and print its final status.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Request ID from `speak`.")
    var id: String

    @Option(name: .long, help: "Seconds to wait.")
    var timeout: Double = 600

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let response = try await client.get("/v1/speech/\(id)", query: ["wait": "1", "timeout": String(timeout)])
            let request = response["request"] as? [String: Any] ?? [:]
            if global.json {
                Output.json(response)
            } else {
                let detail = request["error"] as? String
                let passes = Output.cycles(of: request).map { " [\($0)]" } ?? ""
                print("\(Output.string(request["status"])) on \(Output.string(request["targetName"]))\(passes)\(detail.map { ": \($0)" } ?? "")")
            }
            if request["status"] as? String != "completed" { throw ExitCode(1) }
        } catch let error as ExitCode {
            throw error
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Requests: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recent speech requests and their status.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let response = try await client.get("/v1/speech")
            if global.json {
                Output.json(response)
                return
            }
            let requests = response["requests"] as? [[String: Any]] ?? []
            if requests.isEmpty {
                print("no speech requests yet")
                return
            }
            var rows = [["ID", "STATUS", "TARGET", "PASSES", "TEXT"]]
            for request in requests {
                let text = Output.string(request["text"]).replacingOccurrences(of: "\n", with: " ")
                rows.append([
                    Output.string(request["id"]),
                    Output.string(request["status"]),
                    Output.string(request["targetName"]),
                    Output.cycles(of: request) ?? "1",
                    String(text.prefix(60))
                ])
            }
            Output.table(rows)
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

// MARK: - status / targets / voices / outputs

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show app, session, output, and playback status.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let response = try await client.get("/v1/status")
            if global.json {
                Output.json(response)
                return
            }
            let app = response["app"] as? [String: Any] ?? [:]
            print("BotSpeaker \(Output.string(app["version"])) (pid \(Output.string(app["pid"]))) at \(client.baseURL.absoluteString)")
            print("API key: \(Output.string(response["apiKeyConfigured"]))")
            if let output = response["output"] as? [String: Any] {
                print("Output: \(Output.string(output["name"]))")
            } else {
                print("Output: none selected")
            }
            if let voice = response["voice"] as? [String: Any] {
                print("Voice: \(Output.string(voice["name"])) (\(Output.string(voice["id"])))")
            }
            if let session = response["session"] as? [String: Any] {
                let mode = Output.string(session["mode"])
                print("Session: \(mode) · code \(Output.string(session["code"])) · \(Output.string(session["status"]))")
                for attendee in session["attendees"] as? [[String: Any]] ?? [] {
                    let mark = (attendee["isThisMac"] as? Bool ?? false) ? " (this Mac)" : ""
                    let connected = (attendee["connected"] as? Bool ?? false) ? "connected" : "offline"
                    print("  - \(Output.string(attendee["name"]))\(mark): \(connected) [\(Output.string(attendee["id"]))]")
                }
            } else {
                print("Session: none (run `botspeaker host` or `botspeaker join CODE`)")
            }
            if let active = response["activeSpeech"] as? [String: Any] {
                print("Speaking: \(Output.string(active["status"])) on \(Output.string(active["targetName"])) (\(Output.string(active["id"])))")
            }
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Targets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List where speech can be played: this Mac and paired attendees.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let response = try await client.get("/v1/targets")
            if global.json {
                Output.json(response)
                return
            }
            var rows = [["ID", "NAME", "KIND", "CONNECTED"]]
            for target in response["targets"] as? [[String: Any]] ?? [] {
                rows.append([
                    Output.string(target["id"]),
                    Output.string(target["name"]),
                    Output.string(target["kind"]),
                    Output.string(target["connected"])
                ])
            }
            Output.table(rows)
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List ElevenLabs voices, or select the default voice.")

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Re-fetch the voice list from ElevenLabs.")
    var refresh = false

    @Option(name: .long, help: "Voice name or ID to make the default.")
    var select: String?

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            if let select {
                let response = try await client.post("/v1/voices/select", body: ["voice": select])
                if global.json { Output.json(response) } else if let selected = response["selected"] as? [String: Any] {
                    print("selected \(Output.string(selected["name"])) (\(Output.string(selected["id"])))")
                }
                return
            }
            let response = try await client.get("/v1/voices", query: refresh ? ["refresh": "1"] : [:])
            if global.json {
                Output.json(response)
                return
            }
            let selected = response["selected"] as? String
            var rows = [["", "ID", "NAME", "DETAIL"]]
            for voice in response["voices"] as? [[String: Any]] ?? [] {
                rows.append([
                    voice["id"] as? String == selected ? "*" : " ",
                    Output.string(voice["id"]),
                    Output.string(voice["name"]),
                    Output.string(voice["detail"])
                ])
            }
            Output.table(rows)
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Outputs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List audio output devices on this Mac, or select one.")

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Device name or UID to route playback through.")
    var select: String?

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            if let select {
                let response = try await client.post("/v1/outputs/select", body: ["name": select])
                if global.json { Output.json(response) } else if let selected = response["selected"] as? [String: Any] {
                    print("selected \(Output.string(selected["name"]))")
                }
                return
            }
            let response = try await client.get("/v1/outputs")
            if global.json {
                Output.json(response)
                return
            }
            var rows = [["", "NAME", "UID"]]
            for output in response["outputs"] as? [[String: Any]] ?? [] {
                rows.append([
                    (output["selected"] as? Bool ?? false) ? "*" : " ",
                    Output.string(output["name"]),
                    Output.string(output["uid"])
                ])
            }
            Output.table(rows)
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

// MARK: - host / join / leave

struct Host: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Host a meeting on this Mac and print the pairing code.")

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Display name for this Mac in the meeting.")
    var name: String?

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            var body: [String: Any] = [:]
            if let name { body["speakerName"] = name }
            let response = try await client.post("/v1/session/host", body: body)
            if global.json { Output.json(response) } else if let session = response["session"] as? [String: Any] {
                print("hosting · pairing code \(Output.string(session["code"]))")
            }
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Join: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Join a hosted meeting from this Mac using its pairing code.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Six-character pairing code shown on the host.")
    var code: String

    @Option(name: .long, help: "Display name for this Mac in the meeting.")
    var name: String?

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            var body: [String: Any] = ["code": code]
            if let name { body["speakerName"] = name }
            let response = try await client.post("/v1/session/join", body: body)
            if global.json { Output.json(response) } else if let session = response["session"] as? [String: Any] {
                print("joined · code \(Output.string(session["code"])) · \(Output.string(session["status"]))")
            }
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}

struct Leave: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Leave the current meeting (ends it when this Mac is the host).")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        do {
            let client = try await ControlClient.locate()
            let response = try await client.post("/v1/session/leave")
            if global.json { Output.json(response) } else { print("left the meeting") }
        } catch {
            Output.fail(error, json: global.json)
        }
    }
}
