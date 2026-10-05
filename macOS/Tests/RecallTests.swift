import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct KeychainStore {
    init(account: String = "test") {}
    func read() throws -> String? { "fixture-key" }
    func save(_ key: String) throws {}
}
@MainActor final class AppModel {
    var voiceID = "voice"
    var modelID = "eleven_v3"
}
struct ElevenLabsClient {
    struct Clip { let audioURL: URL }
    func synthesize(text: String, voiceID: String, modelID: String, apiKey: String, cacheNamespace: String) async throws -> Clip {
        if text == "fail" { throw AppError("Synthesis failed") }
        return Clip(audioURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
final class MockHTTP: URLProtocol, @unchecked Sendable {
    static var requests: [String] = []
    static var requestedURLs: [String] = []
    static var listPages: [[String: Any]] = []
    static let bot = "11111111-1111-1111-1111-111111111111"
    static let other = "22222222-2222-2222-2222-222222222222"
    static let ended = "33333333-3333-3333-3333-333333333333"
    static let stuck = "44444444-4444-4444-4444-444444444444"
    static var rejectedLeaves: Set<String> = []
    static var botStatuses: [String: String] = [:]
    static var screenRequests: [URLRequest] = []
    static var screenBodies: [Data] = []
    static var rejectScreen = false
    static var holdScreen = false
    static var heldScreenResponse: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path + (request.url!.path.hasSuffix("/") ? "" : "/")
        Self.requests.append(path)
        Self.requestedURLs.append(request.url!.absoluteString)
        var body: [String: Any]
        var status = 200
        if path.hasSuffix("/output_screenshare/") {
            Self.screenRequests.append(request)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.screenBodies.append(data)
            status = Self.rejectScreen ? 403 : request.httpMethod == "DELETE" ? 204 : 200
            body = [:]
        } else if path.hasSuffix("/leave_call/"), Self.rejectedLeaves.contains(where: path.contains) {
            status = 400; body = ["code": "cannot_command_completed_bot"]
        } else if let id = Self.botStatuses.keys.first(where: { path.hasSuffix("/bot/\($0)/") }) {
            body = ["id": id, "status_changes": [["code": Self.botStatuses[id]!]]]
        } else if path.hasSuffix("/bot/"), !Self.listPages.isEmpty {
            body = Self.listPages.removeFirst()
        } else if path.hasSuffix("/bot/") {
            body = ["results": [
                ["id": Self.bot, "meeting_url": "https://teams.microsoft.com/meet/123?p=x", "status_changes": [["code": "in_call_recording"]]],
                ["id": Self.other, "meeting_url": "https://teams.microsoft.com/meet/456?p=y", "status_changes": [["code": "in_call_recording"]]]]]
        } else { body = [:] }
        let finish = {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: status == 204 ? Data() : try! JSONSerialization.data(withJSONObject: body))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.holdScreen && path.hasSuffix("/output_screenshare/") { Self.heldScreenResponse = finish }
        else { finish() }
    }
    override func stopLoading() {}
}
@main struct RecallTests {
    @MainActor static func main() async throws {
        let parsed = RecallMeetingInput.parse("Help: https://support.microsoft.com/\nMeeting ID: 123 456 789\nPasscode: ab+c")
        precondition(parsed.meeting == "123456789" && parsed.passcode == "ab+c")
        let url = try RecallMeetingInput.directURL(parsed.meeting, passcode: parsed.passcode)!
        precondition(URLComponents(string: url)?.queryItems?.first?.value == "ab+c")
        precondition(RecallMeetingInput.parse("Join <https://teams.microsoft.com/meet/123?p=x&amp;a=b>").meeting == "https://teams.microsoft.com/meet/123?p=x&a=b")
        do { _ = try RecallMeetingInput.directURL("http://bad", passcode: ""); fatalError("Accepted HTTP") } catch {}
        print("PASS: invitation, passcode, help-link filtering, URL validation")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let image = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let controller = RecallController(session: URLSession(configuration: config), testScreen: image)
        let model = AppModel()
        func request(_ action: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
            try await controller.handle(action, body, model: model)
        }
        func id(_ response: [String: Any], _ kind: String = "job") -> String { (response[kind] as! [String: Any])["id"] as! String }
        func wait(_ id: String, _ state: String) async throws {
            for _ in 0..<1000 {
                if controller.jobs.first(where: { $0["id"] as? String == id })?["status"] as? String == state { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Did not reach \(state): \(controller.jobs)")
        }
        let next = "https://\(controller.region).recall.ai/api/v1/bot/?page=cursor%2Bvalue%2Fpart%3D&limit=100"
        MockHTTP.listPages = [
            ["results": [["id": MockHTTP.bot]], "next": next],
            ["results": [["id": MockHTTP.other]], "next": NSNull()]
        ]
        let listed = try await request("list")
        precondition((listed["bots"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [MockHTTP.bot, MockHTTP.other])
        precondition(MockHTTP.requestedURLs.count == 2 && MockHTTP.requestedURLs.last == next,
                     "Pagination must preserve the trailing slash and encoded cursor: \(MockHTTP.requestedURLs)")
        for invalid in [
            "http://\(controller.region).recall.ai/api/v1/bot/?page=2",
            "https://example.com/api/v1/bot/?page=2",
            "https://\(controller.region).recall.ai/api/v1/bots/?page=2",
            "https://\(controller.region).recall.ai/api/v1/bot%2F?page=2"
        ] {
            MockHTTP.listPages = [["results": [], "next": invalid]]
            let count = MockHTTP.requestedURLs.count
            do { _ = try await request("list"); fatalError("Accepted unexpected pagination URL: \(invalid)") }
            catch { precondition(error.localizedDescription == "Unexpected Recall pagination URL.") }
            precondition(MockHTTP.requestedURLs.count == count + 1)
        }
        print("PASS: two-page listing preserves URL and cursor; unexpected pagination URLs are rejected")

        let screen = try await request("screenshare-start", ["botId": MockHTTP.bot.uppercased()])
        precondition((screen["screenshare"] as? [String: Any])?["state"] as? String == "start_accepted")
        let start = MockHTTP.screenRequests.last!
        let payload = try JSONSerialization.jsonObject(with: MockHTTP.screenBodies.last!) as! [String: Any]
        precondition(start.httpMethod == "POST" && start.url!.path(percentEncoded: true).hasSuffix("/\(MockHTTP.bot)/output_screenshare/"))
        precondition(payload["kind"] as? String == "jpeg" && Data(base64Encoded: payload["b64_data"] as! String) == image)
        let stopped = try await request("screenshare-stop", ["botId": MockHTTP.bot])
        precondition((stopped["screenshare"] as? [String: Any])?["state"] as? String == "stop_accepted")
        precondition(MockHTTP.screenRequests.last!.httpMethod == "DELETE" && MockHTTP.screenRequests.last!.httpBody == nil)
        let screenCount = MockHTTP.screenRequests.count
        do { _ = try await request("screenshare-start", ["botId": "invalid"]); fatalError("Accepted invalid bot") } catch {}
        precondition(MockHTTP.screenRequests.count == screenCount)
        MockHTTP.rejectScreen = true
        do { _ = try await request("screenshare-start", ["botId": MockHTTP.bot]); fatalError("Accepted rejected share") } catch {}
        precondition(controller.screenShare(MockHTTP.bot)?["state"] as? String == "failed")
        MockHTTP.rejectScreen = false
        _ = try await request("screenshare-start", ["botId": MockHTTP.bot])
        print("PASS: JPEG payload, POST/DELETE, empty 204, UUID validation, failure and retry")

        MockHTTP.holdScreen = true
        let pendingShare = Task { try await request("screenshare-start", ["botId": MockHTTP.bot]) }
        for _ in 0..<1000 {
            if MockHTTP.heldScreenResponse != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(MockHTTP.heldScreenResponse != nil && controller.hasPendingJobs)
        let countBeforeConflict = MockHTTP.requests.count
        for action in ["screenshare-stop", "remove"] {
            do { _ = try await request(action, ["botId": MockHTTP.bot]); fatalError("Allowed overlapping bot control") } catch {}
        }
        do { _ = try await request("configure", ["region": "us-west-2"]); fatalError("Changed region mid-request") } catch {}
        precondition(MockHTTP.requests.count == countBeforeConflict)
        MockHTTP.holdScreen = false
        MockHTTP.heldScreenResponse?(); MockHTTP.heldScreenResponse = nil
        _ = try await pendingShare.value
        precondition(!controller.hasPendingJobs)
        print("PASS: overlapping control and configuration changes rejected while a request is in flight")

        let first = id(try await request("prepare", ["botId": MockHTTP.bot, "text": "one"]))
        try await wait(first, "prepared")
        _ = try await request("screenshare-start", ["botId": MockHTTP.bot])
        _ = try await request("screenshare-stop", ["botId": MockHTTP.bot])
        precondition(controller.jobs.first { $0["id"] as? String == first }?["status"] as? String == "prepared")
        precondition(!MockHTTP.requests.contains { $0.hasSuffix("output_audio/") })
        let second = id(try await request("prepare", ["botId": MockHTTP.bot, "text": "two"]))
        try await wait(second, "prepared")
        _ = try await request("dispatch", ["id": second])
        try await wait(second, "finished_dispatching")
        precondition(controller.jobs.first { $0["id"] as? String == first }?["status"] as? String == "prepared")
        let job = controller.jobs.first { $0["id"] as? String == second }!
        _ = try await request("screenshare-stop", ["botId": MockHTTP.bot])
        precondition(controller.jobs.first { $0["id"] as? String == second }?["status"] as? String == "finished_dispatching")
        precondition(job["durationSeconds"] != nil && job["acceptedAt"] != nil && job["estimatedEndAt"] != nil)
        _ = try await request("cancel", ["id": first])
        try await wait(first, "cancelled")
        do { _ = try await request("dispatch", ["id": first]); fatalError("Dispatched cancelled job") } catch {}
        print("PASS: held clips do not dispatch or block other jobs; dispatch timing; cancellation")

        let removed = try await request("remove-all", ["meetingId": "123"])
        precondition(removed["removed"] as? [String] == [MockHTTP.bot], "Removal: \(removed)")
        precondition(controller.screenShare(MockHTTP.bot) == nil)
        precondition(!MockHTTP.requests.contains { $0.contains(MockHTTP.other) })
        do { _ = try await request("remove-all", ["meetingId": "https://example.com/"]); fatalError("Accepted empty scope") } catch {}
        print("PASS: bulk removal stays scoped to the requested meeting")

        MockHTTP.rejectedLeaves = [MockHTTP.ended, MockHTTP.stuck]
        MockHTTP.botStatuses = [MockHTTP.ended: "done", MockHTTP.stuck: "in_call_recording"]
        let departed = try await request("remove", ["botId": MockHTTP.ended])
        precondition(departed["ok"] as? Bool == true, "Departed removal: \(departed)")
        precondition(MockHTTP.requests.contains { $0.hasSuffix("/bot/\(MockHTTP.ended)/") })
        do { _ = try await request("remove", ["botId": MockHTTP.stuck]); fatalError("Ignored a rejected leave for a bot still in the call") }
        catch { precondition(error.localizedDescription.hasPrefix("Recall returned HTTP 400."), "\(error)") }
        print("PASS: removal accepts bots that already left; rejected leaves for joined bots still fail")

        let sends = MockHTTP.requests.filter { $0.hasSuffix("output_audio/") }.count
        let failed = id(try await request("meeting-create", ["turns": [
            ["botId": MockHTTP.bot, "voice": "voice", "text": "good"],
            ["botId": MockHTTP.bot, "voice": "voice", "text": "fail"]]]), "meeting")
        _ = try await request("meeting-start", ["id": failed])
        for _ in 0..<500 {
            if controller.meetings.snapshots.first(where: { $0["id"] as? String == failed })?["status"] as? String == "failed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(controller.meetings.snapshots.first { $0["id"] as? String == failed }?["status"] as? String == "failed")
        precondition(MockHTTP.requests.filter { $0.hasSuffix("output_audio/") }.count == sends)
        await controller.cancelPendingJobs()
        precondition(!controller.hasPendingJobs)
        print("PASS: late preparation failure sends no partial meeting; shutdown cancels held jobs")

        var calls: [String] = []
        var states: [String: String] = [:]
        try await RecallTurnRunner.run([
            RecallMeetingTurn(botID: MockHTTP.bot, voice: "v", text: "1"),
            RecallMeetingTurn(botID: MockHTTP.other, voice: "v", text: "2")
        ], request: { action, body in
            calls.append(action)
            if action == "prepare" { let id = String(states.count); states[id] = "prepared"; return ["job": ["id": id]] }
            if action == "dispatch" { states[body["id"] as! String] = "finished_dispatching" }
            return ["jobs": states.map { ["id": $0.key, "status": $0.value] }]
        }, progress: { _ in })
        precondition(calls.filter { $0 != "status" } == ["prepare", "prepare", "dispatch", "dispatch"])
        print("PASS: all turns prepare before any dispatch")

        var cancelled: [String] = []
        var heldStates: [String: String] = [:]
        let pendingRun = Task { @MainActor in
            try await RecallTurnRunner.run([
                RecallMeetingTurn(botID: MockHTTP.bot, voice: "v", text: "1"),
                RecallMeetingTurn(botID: MockHTTP.other, voice: "v", text: "2")
            ], request: { action, body in
                if action == "prepare" { let id = String(heldStates.count); heldStates[id] = "prepared"; return ["job": ["id": id]] }
                if action == "dispatch" { heldStates[body["id"] as! String] = "dispatched" }
                if action == "cancel" { cancelled.append(body["id"] as! String) }
                return ["jobs": heldStates.map { ["id": $0.key, "status": $0.value] }]
            }, progress: { _ in })
        }
        while !heldStates.values.contains("dispatched") { try await Task.sleep(for: .milliseconds(10)) }
        pendingRun.cancel()
        do { try await pendingRun.value; fatalError("Cancelled run completed") } catch is CancellationError {}
        precondition(Set(cancelled) == Set(["0", "1"]))
        print("PASS: Stop cancels the active job and every prepared remaining turn")

        cancelled = []; heldStates = [:]
        var dispatches = 0
        var completedTurns: [Int] = []
        var skippedTurns: [Int] = []
        try await RecallTurnRunner.run([
            RecallMeetingTurn(botID: MockHTTP.bot, voice: "v", text: "1"),
            RecallMeetingTurn(botID: MockHTTP.other, voice: "v", text: "2")
        ], request: { action, body in
            if action == "prepare" { let id = String(heldStates.count); heldStates[id] = "prepared"; return ["job": ["id": id]] }
            if action == "dispatch" { dispatches += 1; heldStates[body["id"] as! String] = "finished_dispatching" }
            if action == "cancel" { cancelled.append(body["id"] as! String) }
            return ["jobs": heldStates.map { ["id": $0.key, "status": $0.value] }]
        }, progress: { _ in }, skipRequested: { dispatches == 1 }, completed: { index, job, skipped in
            precondition(job["id"] as? String == String(index))
            if skipped { skippedTurns.append(index) } else { completedTurns.append(index) }
        })
        precondition(dispatches == 2 && cancelled == ["0"])
        precondition(completedTurns == [1] && skippedTurns == [0])
        print("PASS: Skip cancels only the current turn and advances")

    }
}
