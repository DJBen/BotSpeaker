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
    static let bot = "11111111-1111-1111-1111-111111111111"
    static let other = "22222222-2222-2222-2222-222222222222"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path + (request.url!.path.hasSuffix("/") ? "" : "/")
        Self.requests.append(path)
        let body: [String: Any]
        if path.hasSuffix("/bot/") {
            body = ["results": [
                ["id": Self.bot, "meeting_url": "https://teams.microsoft.com/meet/123?p=x", "status_changes": [["code": "in_call_recording"]]],
                ["id": Self.other, "meeting_url": "https://teams.microsoft.com/meet/456?p=y", "status_changes": [["code": "in_call_recording"]]]]]
        } else { body = [:] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
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
        let controller = RecallController(session: URLSession(configuration: config))
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
        let first = id(try await request("prepare", ["botId": MockHTTP.bot, "text": "one"]))
        try await wait(first, "prepared")
        precondition(!MockHTTP.requests.contains { $0.hasSuffix("output_audio/") })
        let second = id(try await request("prepare", ["botId": MockHTTP.bot, "text": "two"]))
        try await wait(second, "prepared")
        _ = try await request("dispatch", ["id": second])
        try await wait(second, "finished_dispatching")
        precondition(controller.jobs.first { $0["id"] as? String == first }?["status"] as? String == "prepared")
        let job = controller.jobs.first { $0["id"] as? String == second }!
        precondition(job["durationSeconds"] != nil && job["acceptedAt"] != nil && job["estimatedEndAt"] != nil)
        _ = try await request("cancel", ["id": first])
        try await wait(first, "cancelled")
        do { _ = try await request("dispatch", ["id": first]); fatalError("Dispatched cancelled job") } catch {}
        print("PASS: held clips do not dispatch or block other jobs; dispatch timing; cancellation")

        let removed = try await request("remove-all", ["meetingId": "123"])
        precondition(removed["removed"] as? [String] == [MockHTTP.bot], "Removal: \(removed)")
        precondition(!MockHTTP.requests.contains { $0.contains(MockHTTP.other) })
        do { _ = try await request("remove-all", ["meetingId": "https://example.com/"]); fatalError("Accepted empty scope") } catch {}
        print("PASS: bulk removal stays scoped to the requested meeting")

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
