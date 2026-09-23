import Foundation
import Observation

struct RecallMeetingTurn {
    let botID: String
    let voice: String
    let text: String
}

typealias RecallRequest = @MainActor (String, [String: Any]) async throws -> [String: Any]

/// Shared by GUI and CLI: prepare the whole script before dispatching any audio.
@MainActor
enum RecallTurnRunner {
    static func run(_ turns: [RecallMeetingTurn], request: RecallRequest,
                    progress: (Int) -> Void, skipRequested: () -> Bool = { false },
                    preparing: (Int) -> Void = { _ in },
                    completed: (Int, [String: Any], Bool) -> Void = { _, _, _ in }) async throws {
        var pending: [String] = []
        do {
            for (index, turn) in turns.enumerated() {
                try Task.checkCancellation()
                preparing(index)
                let response = try await request("prepare", ["botId": turn.botID, "voice": turn.voice, "text": turn.text])
                guard let id = (response["job"] as? [String: Any])?["id"] as? String else { throw AppError("Recall did not return a speech job.") }
                pending.append(id)
                try await wait(id, expected: "prepared", request: request)
            }
            for (index, id) in Array(pending).enumerated() {
                try Task.checkCancellation()
                progress(index)
                _ = try await request("dispatch", ["id": id])
                try await wait(id, expected: "finished_dispatching", request: request, skipRequested: skipRequested)
                let response = try await request("status", [:])
                let job = (response["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == id } ?? [:]
                completed(index, job, skipRequested())
                pending.removeAll { $0 == id }
            }
        } catch {
            // This cleanup is local cancellation, so it also works in a cancelled task.
            for id in pending { _ = try? await request("cancel", ["id": id]) }
            throw error
        }
    }

    private static func wait(_ id: String, expected: String, request: RecallRequest,
                             skipRequested: () -> Bool = { false }) async throws {
        while true {
            try Task.checkCancellation()
            if skipRequested() { _ = try await request("cancel", ["id": id]); return }
            let response = try await request("status", [:])
            guard let job = (response["jobs"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else { throw AppError("Speech job was lost.") }
            let status = job["status"] as? String ?? ""
            if status == expected { return }
            if ["failed", "cancelled"].contains(status) { throw AppError(job["error"] as? String ?? "Speech was cancelled.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor @Observable
final class RecallRunManager {
    @MainActor @Observable
    fileprivate final class Run {
        let id = UUID().uuidString
        let turns: [RecallMeetingTurn]
        var status = "created"
        var error: String?
        var index = -1
        var skip = false
        @ObservationIgnored var task: Task<Void, Never>?
        init(_ turns: [RecallMeetingTurn]) { self.turns = turns }
        var snapshot: [String: Any] {
            ["id": id, "status": status, "turnIndex": index, "turnCount": turns.count, "error": error as Any? ?? NSNull()]
        }
    }
    private var runs: [Run] = []
    var snapshots: [[String: Any]] { runs.map(\.snapshot) }
    var hasActiveRuns: Bool { runs.contains { ["starting", "preparing", "running"].contains($0.status) } }

    func stopAll() async {
        let tasks = runs.compactMap(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
    func stopForBots(_ ids: Set<String>) async {
        let tasks = runs.filter { $0.turns.contains { ids.contains($0.botID) } }.compactMap(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
    func handle(_ action: String, _ body: [String: Any], request: @escaping RecallRequest) async throws -> [String: Any] {
        if action == "meeting-create" {
            guard let items = body["turns"] as? [[String: Any]], (1...450).contains(items.count) else { throw AppError("Provide between 1 and 450 turns in a turns array.") }
            let turns = try items.map { item -> RecallMeetingTurn in
                guard let id = item["botId"] as? String, let bot = UUID(uuidString: id) else { throw AppError("Every turn needs a bot UUID.") }
                let voice = (item["voice"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !voice.isEmpty, !text.isEmpty else { throw AppError("Every turn needs voice and text.") }
                return RecallMeetingTurn(botID: bot.uuidString.lowercased(), voice: voice, text: text)
            }
            let run = Run(turns); runs.append(run)
            return ["ok": true, "meeting": run.snapshot]
        }
        guard let id = body["id"] as? String, let run = runs.first(where: { $0.id == id }) else { throw AppError("Unknown Recall meeting plan.") }
        switch action {
        case "meeting-status": break
        case "meeting-start":
            guard run.task == nil else { throw AppError("Meeting is already running.") }
            let bots = Set(run.turns.map(\.botID))
            guard !runs.contains(where: { $0.task != nil && $0.turns.contains { bots.contains($0.botID) } }) else { throw AppError("A speaker bot is already used by another running meeting plan.") }
            run.status = "starting"; run.error = nil; run.index = -1; run.skip = false
            run.task = Task {
                defer { run.task = nil }
                do {
                    let response = try await request("list", [:])
                    try Task.checkCancellation()
                    let ready = Set((response["bots"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "in_call_recording" }.compactMap { $0["id"] as? String })
                    guard bots.isSubset(of: ready) else { throw AppError("Every speaker bot must be in_call_recording before starting.") }
                    run.status = "preparing"
                    try await RecallTurnRunner.run(run.turns, request: request, progress: { index in
                        run.index = index; run.skip = false; run.status = "running"
                    }, skipRequested: { run.skip }, preparing: { run.index = $0 })
                    run.status = "finished"
                } catch {
                    run.status = Task.isCancelled ? "stopped" : "failed"
                    if !Task.isCancelled { run.error = error.localizedDescription }
                }
            }
        case "meeting-stop":
            if let task = run.task { task.cancel(); await task.value } else { run.status = "stopped" }
        case "meeting-skip":
            guard run.status == "running" else { throw AppError("A turn must be running to skip it.") }
            run.skip = true
        default: throw AppError("Unknown Recall meeting action.")
        }
        return ["ok": true, "meeting": run.snapshot]
    }
}
