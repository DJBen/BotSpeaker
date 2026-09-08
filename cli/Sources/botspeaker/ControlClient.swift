import Foundation

/// Locates the running BotSpeaker app through its discovery file and talks
/// to its loopback control API.
struct ControlClient {
    struct Discovery: Decodable {
        let url: String
        let port: Int
        let token: String
        let pid: Int
        let version: String
    }

    struct Failure: Error, CustomStringConvertible {
        let exitCode: Int32
        let code: String
        let message: String
        var description: String { message }
    }

    let baseURL: URL
    let token: String
    let discovery: Discovery?

    static let bundleID = "ai.DJBen.2.BotSpeaker"

    static var discoveryCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["BOTSPEAKER_CONTROL_FILE"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        urls.append(home
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/BotSpeaker/control.json"))
        urls.append(home.appendingPathComponent("Library/Application Support/BotSpeaker/control.json"))
        return urls
    }

    /// Returns a client for a live app instance, or nil when no discovery
    /// file points at a running process.
    static func findRunning() -> (client: ControlClient?, stalePID: Int?) {
        var stalePID: Int?
        for candidate in discoveryCandidates {
            guard let data = try? Data(contentsOf: candidate),
                  let discovery = try? JSONDecoder().decode(Discovery.self, from: data),
                  let base = URL(string: discovery.url) else { continue }
            if kill(pid_t(discovery.pid), 0) != 0 && errno == ESRCH {
                // Stale file from a previous launch.
                stalePID = discovery.pid
                continue
            }
            return (ControlClient(baseURL: base, token: discovery.token, discovery: discovery), nil)
        }
        return (nil, stalePID)
    }

    /// Finds the running app, launching it in the background first when it is
    /// not running. Set `BOTSPEAKER_NO_LAUNCH=1` to fail instead of launching,
    /// and `BOTSPEAKER_APP=/path/to/BotSpeaker.app` to launch a specific copy.
    static func locate(launchIfNeeded: Bool = true) async throws -> ControlClient {
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["BOTSPEAKER_CONTROL_URL"], let token = environment["BOTSPEAKER_TOKEN"],
           let base = URL(string: url) {
            return ControlClient(baseURL: base, token: token, discovery: nil)
        }
        var found = findRunning()
        if found.client == nil, launchIfNeeded, environment["BOTSPEAKER_NO_LAUNCH"].map({ $0.isEmpty || $0 == "0" }) ?? true {
            try launchApp(explicitPath: environment["BOTSPEAKER_APP"])
            let deadline = Date().addingTimeInterval(launchTimeout)
            while found.client == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
                found = findRunning()
            }
            if found.client == nil {
                throw Failure(
                    exitCode: 2,
                    code: "app_unreachable",
                    message: "Launched BotSpeaker but it did not publish a control file within \(Int(launchTimeout)) seconds. "
                        + "Check that the installed app is version 0.4 or newer (the one built from this repository), "
                        + "or point BOTSPEAKER_APP at the right BotSpeaker.app."
                )
            }
        }
        if let client = found.client { return client }
        let detail = found.stalePID.map { "the last control.json belongs to pid \($0), which has exited" }
            ?? "no control.json found"
        throw Failure(
            exitCode: 2,
            code: "app_unreachable",
            message: "BotSpeaker is not running (\(detail)). Launch the BotSpeaker app, then retry. Looked in: "
                + discoveryCandidates.map(\.path).joined(separator: ", ")
        )
    }

    static let launchTimeout: TimeInterval = 20

    /// Asks LaunchServices to start the app without stealing focus.
    private static func launchApp(explicitPath: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let explicitPath, !explicitPath.isEmpty {
            process.arguments = ["-g", explicitPath]
        } else {
            process.arguments = ["-g", "-b", bundleID]
        }
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure(exitCode: 2, code: "app_launch_failed", message: "Could not run /usr/bin/open: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(
                exitCode: 2,
                code: "app_launch_failed",
                message: "BotSpeaker is not installed or could not be launched (\(output.isEmpty ? "open exited \(process.terminationStatus)" : output)). "
                    + "Install BotSpeaker.app or set BOTSPEAKER_APP to its path."
            )
        }
    }

    func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        try await send(method: "GET", path: path, query: query, body: nil)
    }

    func post(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        try await send(method: "POST", path: path, query: [:], body: body)
    }

    private func send(method: String, path: String, query: [String: String], body: [String: Any]?) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 3600
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(
                exitCode: 2,
                code: "app_unreachable",
                message: "Could not reach BotSpeaker at \(baseURL.absoluteString): \(error.localizedDescription). Is the app running?"
            )
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 401 {
            throw Failure(exitCode: 2, code: "unauthorized", message: "BotSpeaker rejected the control token. Restart the app or clear BOTSPEAKER_TOKEN.")
        }
        if status >= 400 || payload["ok"] as? Bool == false, let error = payload["error"] as? [String: Any] {
            throw Failure(
                exitCode: 1,
                code: error["code"] as? String ?? "error",
                message: error["message"] as? String ?? "Request failed with HTTP \(status)."
            )
        }
        if status >= 400 {
            throw Failure(exitCode: 1, code: "http_\(status)", message: "Request failed with HTTP \(status).")
        }
        return payload
    }
}
