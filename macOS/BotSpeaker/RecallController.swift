import Foundation
import Observation
import AVFoundation

@MainActor @Observable
final class RecallController {
    static let regions = ["us-east-1", "us-west-2", "eu-central-1", "ap-northeast-1"]
    var region = UserDefaults.standard.string(forKey: "recallRegion") ?? "us-east-1"
    var configured = false
    var jobs: [[String: Any]] = []
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let credentials = KeychainStore(account: "recall-api-key")
    @ObservationIgnored private var knownMeetingURLs: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var dueTimes: [String: Date] = [:]
    @ObservationIgnored private var activeBots: Set<String> = []

    let meetings = RecallRunManager()
    var hasPendingJobs: Bool { !tasks.isEmpty || meetings.hasActiveRuns }
    func cancelPendingJobs() async {
        await meetings.stopAll()
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }
    init(session: URLSession = .shared) { self.session = session; configured = key != nil }
    private var key: String? {
        if let saved = try? credentials.read(), !saved.isEmpty { return saved }
        let env = ProcessInfo.processInfo.environment
        return [env["RECALL_API_KEY"], env["RECALL_AI_API_KEY"]].compactMap { $0 }.first { !$0.isEmpty }
    }
    func status() -> [String: Any] { ["ok": true, "configured": configured, "region": region, "jobs": jobs, "meetings": meetings.snapshots] }
    func handle(_ action: String, _ body: [String: Any], model: AppModel) async throws -> [String: Any] {
        if action.hasPrefix("meeting-") {
            return try await meetings.handle(action, body) { [self] action, body in
                try await handle(action, body, model: model)
            }
        }
        switch action {
        case "status": return status()
        case "configure":
            let proposedRegion = body["region"] as? String ?? region
            guard Self.regions.contains(proposedRegion) else { throw AppError("Choose a supported Recall region.") }
            let input = (body["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let proposedKey = input.isEmpty ? key : input else { throw AppError("Enter a Recall key or set RECALL_API_KEY.") }
            _ = try await send("GET", "bot/?limit=1", key: proposedKey, region: proposedRegion)
            try credentials.save(proposedKey)
            region = proposedRegion; configured = true
            UserDefaults.standard.set(region, forKey: "recallRegion")
            return status()
        case "list":
            var bots: [[String: Any]] = []
            var path: String? = "bot/?limit=100"
            while let current = path {
                let page = try await send("GET", current)
                for item in page["results"] as? [[String: Any]] ?? [] {
                    let record = summary(item)
                    if let id = record["meeting_id"] as? String, let url = Self.joinURL(item["meeting_url"]) {
                        knownMeetingURLs[region + ":" + Self.meetingID(id)] = url
                    }
                    bots.append(record)
                }
                path = nil
                if let next = page["next"] as? String {
                    guard let url = URL(string: next), url.scheme == "https", url.host == "\(region).recall.ai", url.path.hasPrefix("/api/v1/bot/") else { throw AppError("Unexpected Recall pagination URL.") }
                    path = String(url.path.dropFirst(8)) + (url.query.map { "?" + $0 } ?? "")
                }
            }
            if let scope = body["meetingId"] as? String, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bots = bots.filter { $0["meeting_id"] as? String == Self.meetingID(scope) }
            }
            return ["ok": true, "bots": bots]
        case "add":
            let meeting = try await resolveMeetingURL(required(body, "meetingUrl"), passcode: body["passcode"] as? String, model: model)
            guard let silence = Bundle.main.url(forResource: "recall-silence", withExtension: "mp3") else { throw AppError("Missing bundled Recall silence clip.") }
            let audio = try Data(contentsOf: silence).base64EncodedString()
            let bot = try await send("POST", "bot/", body: ["meeting_url": meeting, "bot_name": body["name"] as? String ?? "BotSpeaker", "automatic_audio_output": ["in_call_recording": ["data": ["kind": "mp3", "b64_data": audio]]]])
            return ["ok": true, "bot": summary(bot)]
        case "remove":
            let bot = try botID(body)
            await meetings.stopForBots([bot])
            for job in jobs where job["botId"] as? String == bot { if let id = job["id"] as? String { tasks[id]?.cancel() } }
            _ = try await send("POST", "bot/\(bot)/leave_call/", body: [:])
            return ["ok": true]
        case "remove-all":
            let scope = Self.meetingID(try required(body, "meetingId"))
            guard !scope.isEmpty else { throw AppError("A nonempty meeting ID is required for remove-all.") }
            let result = try await handle("list", ["meetingId": scope], model: model)
            var removed: [String] = []
            var failures: [[String: String]] = []
            for bot in result["bots"] as? [[String: Any]] ?? [] {
                guard !["done", "fatal"].contains(bot["status"] as? String ?? ""), let id = bot["id"] as? String else { continue }
                do { _ = try await handle("remove", ["botId": id], model: model); removed.append(id) }
                catch { failures.append(["botId": id, "error": error.localizedDescription]) }
            }
            return ["ok": failures.isEmpty, "removed": removed, "failures": failures]
        case "dispatch":
            let id = try required(body, "id")
            guard let job = jobs.first(where: { $0["id"] as? String == id }),
                  job["status"] as? String == "prepared", tasks[id]?.isCancelled == false else {
                throw AppError("Speech is not ready to dispatch.")
            }
            dueTimes[id] = Date()
            update(id, ["status": "queued", "held": false, "at": ISO8601DateFormatter().string(from: dueTimes[id]!)])
            return ["ok": true, "job": jobs.first { $0["id"] as? String == id }!]
        case "cancel":
            let id = try required(body, "id")
            guard jobs.contains(where: { $0["id"] as? String == id }) else { throw AppError("Unknown Recall job.") }
            tasks[id]?.cancel()
            return status()
        case "speak", "prepare":
            let held = action == "prepare"
            guard !held || body["at"] == nil else { throw AppError("Prepared speech is held until dispatch; omit at.") }
            guard configured else { throw AppError("Configure Recall first.") }
            let bot = try botID(body), text = try required(body, "text")
            let at = try Self.parseTime(body["at"] as? String ?? "now")
            let loop = body["loop"] as? Bool ?? false
            let count = body["repeat"] as? Int ?? 1
            let gap = body["interval"] as? Double ?? 0
            guard count > 0, !(loop && body["repeat"] != nil), gap.isFinite, gap >= 0, gap <= 86400 else { throw AppError("Use loop or a positive repeat count and a nonnegative interval.") }
            let id = UUID().uuidString
            jobs.append(["id": id, "botId": bot, "text": text, "at": ISO8601DateFormatter().string(from: at), "status": "preparing", "sequence": jobs.count, "dispatched": 0, "loop": loop, "held": held])
            dueTimes[id] = at
            let voice = body["voice"] as? String ?? model.voiceID
            let speechModel = model.modelID
            let recallKey = key!
            let recallRegion = region
            tasks[id] = Task { await self.run(id: id, bot: bot, text: text, voice: voice, model: speechModel, at: at, count: loop ? nil : count, gap: gap, recallKey: recallKey, recallRegion: recallRegion, held: held) }
            return ["ok": true, "job": jobs.last!]
        default: throw AppError("Unknown Recall action.")
        }
    }
    static func parseTime(_ value: String) throws -> Date {
        if value == "now" || value.isEmpty { return Date() }
        if value.hasPrefix("+"), let seconds = Double(value.dropFirst()), seconds.isFinite, seconds >= 0, seconds <= 86400 * 30 { return Date().addingTimeInterval(seconds) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        if let date = fractional ?? formatter.date(from: value), date > Date(), date < Date().addingTimeInterval(86400 * 30) { return date }
        throw AppError("Use now, +SECONDS, or a future ISO 8601 timestamp with timezone (within 30 days).")
    }
    private func update(_ id: String, _ values: [String: Any]) {
        if let index = jobs.firstIndex(where: { $0["id"] as? String == id }) { jobs[index].merge(values) { _, new in new } }
    }
    private func sleep(_ seconds: Double) async throws {
        // Bounded sleeps avoid overflowing nanosecond conversions on large inputs.
        var remaining = seconds
        while remaining > 0 { let chunk = min(remaining, 3600); try await Task.sleep(for: .seconds(chunk)); remaining -= chunk }
        try Task.checkCancellation()
    }
    private func run(id: String, bot: String, text: String, voice: String, model: String, at: Date, count: Int?, gap: Double, recallKey: String, recallRegion: String, held: Bool) async {
        var at = at
        var acquired = false
        defer { if acquired { activeBots.remove(bot) }; tasks[id] = nil }
        do {
            guard let elevenKey = try KeychainStore().read() else { throw AppError("Configure ElevenLabs first.") }
            let clip = try await ElevenLabsClient().synthesize(text: text, voiceID: voice, modelID: model, apiKey: elevenKey, cacheNamespace: "recall")
            try Task.checkCancellation()
            let audio = try Data(contentsOf: clip.audioURL).base64EncodedString()
            guard audio.count <= 1835008 else { throw AppError("Recall clips must be shorter than about 85 seconds. Split this speech into shorter jobs.") }
            let duration = try await AVURLAsset(url: clip.audioURL).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw AppError("Cannot determine speech duration.") }
            update(id, ["durationSeconds": duration])
            if held {
                update(id, ["status": "prepared"])
                while jobs.first(where: { $0["id"] as? String == id })?["held"] as? Bool == true {
                    try await sleep(0.02)
                }
                at = dueTimes[id] ?? Date()
            }
            update(id, ["status": "scheduled"])
            try await sleep(max(0, at.timeIntervalSinceNow))
            update(id, ["status": "queued"])
            let sequence = jobs.first(where: { $0["id"] as? String == id })?["sequence"] as? Int ?? 0
            while activeBots.contains(bot) || jobs.contains(where: { job in
                let otherID = job["id"] as? String ?? ""
                let due = dueTimes[otherID] ?? .distantFuture
                return otherID != id && job["botId"] as? String == bot
                    && job["held"] as? Bool != true
                    && !["failed", "cancelled", "finished_dispatching"].contains(job["status"] as? String ?? "")
                    && (due < at || (due == at && (job["sequence"] as? Int ?? 0) < sequence))
            }) { try await sleep(0.1) }
            activeBots.insert(bot); acquired = true
            var pass = 0
            while count == nil || pass < count! {
                try Task.checkCancellation()
                update(id, ["status": "dispatching", "dispatchStartedAt": ISO8601DateFormatter().string(from: Date())])
                _ = try await send("POST", "bot/\(bot)/output_audio/", body: ["kind": "mp3", "b64_data": audio], key: recallKey, region: recallRegion)
                pass += 1
                let accepted = Date()
                let wait = duration + (held ? 0 : 2) + gap
                update(id, ["status": "dispatched", "dispatched": pass,
                            "acceptedAt": ISO8601DateFormatter().string(from: accepted),
                            "acceptedAtEpoch": accepted.timeIntervalSince1970,
                            "estimatedEndAt": ISO8601DateFormatter().string(from: accepted.addingTimeInterval(wait))])
                try await sleep(wait)
            }
            update(id, ["status": "finished_dispatching"])
        } catch {
            update(id, Task.isCancelled ? ["status": "cancelled"] : ["status": "failed", "error": error.localizedDescription])
        }
    }
    func resolveMeetingURL(_ input: String, passcode: String? = nil, model: AppModel) async throws -> String {
        let parsed = RecallMeetingInput.parse(input)
        let value = parsed.meeting
        let code = passcode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = try RecallMeetingInput.directURL(value, passcode: code?.isEmpty == false ? code! : parsed.passcode) { return url }
        _ = try await handle("list", [:], model: model)
        guard let url = knownMeetingURLs[region + ":" + Self.meetingID(value)] else {
            throw AppError("Enter the Teams passcode for this meeting ID, or paste the full invitation or join link.")
        }
        return url
    }
    static func joinURL(_ value: Any?) -> String? {
        if let link = value as? String { return URL(string: link)?.scheme == "https" ? link : nil }
        guard let meeting = value as? [String: Any] else { return nil }
        let platform = meeting["platform"] as? String ?? ""
        let id = meeting["business_meeting_id"] as? String ?? meeting["meeting_id"] as? String ?? ""
        let password = meeting["business_meeting_password"] as? String ?? meeting["meeting_password"] as? String
        func link(_ base: String, _ queryName: String) -> String? {
            guard var components = URLComponents(string: base) else { return nil }
            if let password, !password.isEmpty { components.queryItems = [URLQueryItem(name: queryName, value: password)] }
            return components.url?.absoluteString
        }
        if ["microsoft_teams", "microsoft_teams_live"].contains(platform), !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let host = platform == "microsoft_teams_live" ? "teams.live.com" : "teams.microsoft.com"
            return link("https://\(host)/meet/\(id)", "p")
        }
        if platform == "microsoft_teams", let thread = meeting["thread_id"] as? String, let message = meeting["message_id"] as? String,
           let tenant = meeting["tenant_id"] as? String, let organizer = meeting["organizer_id"] as? String {
            let context = try? JSONSerialization.data(withJSONObject: ["Tid": tenant, "Oid": organizer])
            guard let context, let json = String(data: context, encoding: .utf8) else { return nil }
            var components = URLComponents(string: "https://teams.microsoft.com")!
            components.path = "/l/meetup-join/\(thread)/\(message)"
            components.queryItems = [URLQueryItem(name: "context", value: json)]
            return components.url?.absoluteString
        }
        if platform == "google_meet", !id.isEmpty { return "https://meet.google.com/" + id }
        if platform == "zoom", !id.isEmpty { return link("https://zoom.us/j/" + id, "pwd") }
        return nil
    }
    static func meetingID(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https" else { return value.filter { !$0.isWhitespace } }
        let parts = url.path.split(separator: "/").map(String.init)
        for index in parts.indices where index + 1 < parts.count {
            if ["meet", "meetup-join", "j", "wc"].contains(parts[index]) { return parts[index + 1].removingPercentEncoding ?? parts[index + 1] }
        }
        return parts.last?.removingPercentEncoding ?? parts.last ?? ""
    }
    private func summary(_ bot: [String: Any]) -> [String: Any] {
        let meeting: Any = (bot["meeting_url"] as? [String: Any])?["meeting_id"] as? String ?? (bot["meeting_url"] as? [String: Any])?["business_meeting_id"] as? String ?? (bot["meeting_url"] as? [String: Any])?["thread_id"] as? String ?? (bot["meeting_url"] as? String).map(Self.meetingID) as Any? ?? NSNull()
        return ["id": bot["id"] ?? NSNull(), "bot_name": bot["bot_name"] ?? NSNull(),
         "status": (bot["status_changes"] as? [[String: Any]])?.last?["code"] ?? "unknown",
         "platform": (bot["meeting_url"] as? [String: Any])?["platform"] ?? NSNull(),
         "meeting_id": meeting,
         "join_at": bot["join_at"] ?? NSNull()]
    }
    private func required(_ body: [String: Any], _ name: String) throws -> String {
        guard let value = body[name] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("\(name) is required.") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func botID(_ body: [String: Any]) throws -> String {
        guard let uuid = UUID(uuidString: try required(body, "botId")) else { throw AppError("Use a Recall bot UUID.") }
        return uuid.uuidString.lowercased()
    }
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, key apiKey: String? = nil, region: String? = nil) async throws -> [String: Any] {
        guard let credential = apiKey ?? key else { throw AppError("Enter a Recall key or set RECALL_API_KEY.") }
        var request = URLRequest(url: URL(string: "https://\(region ?? self.region).recall.ai/api/v1/\(path)")!)
        request.httpMethod = method; request.timeoutInterval = 60
        request.setValue("Token " + credential, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw AppError("Recall returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check the key, region, bot status, and account limits.")
        }
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }
}
