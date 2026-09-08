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

    static func locate() throws -> ControlClient {
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["BOTSPEAKER_CONTROL_URL"], let token = environment["BOTSPEAKER_TOKEN"],
           let base = URL(string: url) {
            return ControlClient(baseURL: base, token: token, discovery: nil)
        }
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
            return ControlClient(baseURL: base, token: discovery.token, discovery: discovery)
        }
        let detail = stalePID.map { "the last control.json belongs to pid \($0), which has exited" }
            ?? "no control.json found"
        throw Failure(
            exitCode: 2,
            code: "app_unreachable",
            message: "BotSpeaker is not running (\(detail)). Launch the BotSpeaker app, then retry. Looked in: "
                + discoveryCandidates.map(\.path).joined(separator: ", ")
        )
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
