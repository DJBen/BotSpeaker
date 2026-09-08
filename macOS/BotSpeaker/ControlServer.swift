import Foundation
import Network
import OSLog

/// A minimal loopback HTTP/1.1 server that exposes the app to local tooling
/// (the `botspeaker` CLI and any agent that can run `curl`). It only binds
/// 127.0.0.1, requires a per-launch bearer token, and publishes a discovery
/// file so clients can find the port and token without configuration.
@MainActor
final class ControlServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        func json() -> [String: Any]? {
            guard !body.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    struct Response {
        var status: Int
        var body: Any

        static func ok(_ body: Any) -> Response { Response(status: 200, body: body) }
        static func error(_ status: Int, _ message: String, code: String = "error") -> Response {
            Response(status: status, body: ["ok": false, "error": ["code": code, "message": message]])
        }
    }

    static let defaultPort: UInt16 = 47311
    static let discoveryFileName = "control.json"

    private(set) var port: UInt16 = 0
    private(set) var token: String
    private(set) var discoveryURL: URL?
    private(set) var lastError: String?

    private let handler: (Request) async -> Response
    private var listener: NWListener?
    private let connections = ConnectionRegistry()
    private let queue = DispatchQueue(label: "ai.DJBen.BotSpeaker.control")
    private let log = Logger(subsystem: "ai.DJBen.BotSpeaker", category: "control")

    init(handler: @escaping (Request) async -> Response) {
        self.handler = handler
        token = Self.makeToken()
    }

    // MARK: Lifecycle

    func start() {
        let preferred = UInt16(clamping: UserDefaults.standard.integer(forKey: "controlPort"))
        startListener(port: preferred > 0 ? preferred : Self.defaultPort, allowFallback: true)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let discoveryURL {
            try? FileManager.default.removeItem(at: discoveryURL)
        }
    }

    private func startListener(port requested: UInt16, allowFallback: Bool) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: requested) ?? .any
        )
        let created: NWListener?
        do {
            created = try NWListener(using: parameters)
        } catch {
            lastError = error.localizedDescription
            log.error("Control server could not create a listener: \(error.localizedDescription, privacy: .public)")
            created = nil
        }
        guard let listener = created else { return }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue ?? requested
                    self.lastError = nil
                    self.writeDiscoveryFile()
                    self.log.notice("Control server listening on 127.0.0.1:\(self.port)")
                case .failed(let error):
                    self.lastError = error.localizedDescription
                    self.log.error("Control listener on port \(requested) failed: \(error.localizedDescription, privacy: .public)")
                    listener.cancel()
                    self.listener = nil
                    if allowFallback {
                        self.startListener(port: 0, allowFallback: false)
                    }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let registry = self.connections
            let http = HTTPConnection(connection: connection, queue: self.queue, handler: { [weak self] request in
                guard let self else { return .error(503, "Shutting down") }
                return await self.dispatch(request)
            }, onClose: { [registry] http in
                registry.remove(http)
            })
            registry.insert(http)
            http.start()
        }
        listener.start(queue: queue)
    }

    // MARK: Discovery

    static var discoveryDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("BotSpeaker", isDirectory: true)
    }

    private func writeDiscoveryFile() {
        guard let directory = Self.discoveryDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.discoveryFileName)
            let payload: [String: Any] = [
                "url": "http://127.0.0.1:\(port)",
                "port": Int(port),
                "token": token,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "apiVersion": 1
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            discoveryURL = url
        } catch {
            lastError = "Could not write \(Self.discoveryFileName): \(error.localizedDescription)"
            log.error("\(self.lastError ?? "", privacy: .public)")
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Dispatch

    private func dispatch(_ request: Request) async -> Response {
        if request.method == "OPTIONS" {
            return Response(status: 204, body: [:])
        }
        if request.path == "/health" || request.path == "/v1/health" {
            return .ok(["ok": true, "pid": Int(ProcessInfo.processInfo.processIdentifier)])
        }
        guard isAuthorized(request) else {
            return .error(401, "Missing or invalid bearer token. Read it from control.json.", code: "unauthorized")
        }
        return await handler(request)
    }

    private func isAuthorized(_ request: Request) -> Bool {
        let presented: String?
        if let header = request.headers["authorization"], header.lowercased().hasPrefix("bearer ") {
            presented = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let header = request.headers["x-botspeaker-token"] {
            presented = header
        } else {
            presented = request.query["token"]
        }
        guard let presented, presented.utf8.count == token.utf8.count else { return false }
        // Constant-time compare.
        var difference: UInt8 = 0
        for (a, b) in zip(presented.utf8, token.utf8) { difference |= a ^ b }
        return difference == 0
    }
}

// MARK: - HTTP/1.1 connection

/// Keeps live connections alive until they close; NWConnection callbacks
/// only hold weak references back to their owner.
private final class ConnectionRegistry: @unchecked Sendable {
    private var storage: [ObjectIdentifier: HTTPConnection] = [:]
    private let lock = NSLock()

    func insert(_ connection: HTTPConnection) {
        lock.lock(); defer { lock.unlock() }
        storage[ObjectIdentifier(connection)] = connection
    }

    func remove(_ connection: HTTPConnection) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: ObjectIdentifier(connection))
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (ControlServer.Request) async -> ControlServer.Response
    private let onClose: (HTTPConnection) -> Void
    private var buffer = Data()
    private var didClose = false
    private static let maximumBodySize = 4 * 1024 * 1024

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        handler: @escaping (ControlServer.Request) async -> ControlServer.Response,
        onClose: @escaping (HTTPConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        connection.cancel()
        onClose(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil {
                self.close()
                return
            }
            if let (request, consumed) = self.parseRequest() {
                self.buffer.removeFirst(consumed)
                self.respond(to: request)
                return
            }
            if self.buffer.count > Self.maximumBodySize + 65536 {
                self.send(.error(413, "Request too large"))
                return
            }
            if isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func parseRequest() -> (ControlServer.Request, Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return (ControlServer.Request(method: "BAD", path: "/", query: [:], headers: [:], body: Data()), buffer.count)
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else {
            return (ControlServer.Request(method: "BAD", path: "/", query: [:], headers: [:], body: Data()), buffer.count)
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= contentLength else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])

        let target = String(requestLine[1])
        let components = URLComponents(string: target) ?? URLComponents()
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let request = ControlServer.Request(
            method: String(requestLine[0]).uppercased(),
            path: components.path.isEmpty ? "/" : components.path,
            query: query,
            headers: headers,
            body: body
        )
        return (request, (bodyStart - buffer.startIndex) + contentLength)
    }

    private func respond(to request: ControlServer.Request) {
        if request.method == "BAD" {
            send(.error(400, "Malformed request"))
            return
        }
        Task { [handler] in
            let response = await handler(request)
            self.send(response)
        }
    }

    private func send(_ response: ControlServer.Response) {
        let body: Data
        if let data = response.body as? Data {
            body = data
        } else {
            body = (try? JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys])) ?? Data("{}".utf8)
        }
        let reason: String = switch response.status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}
