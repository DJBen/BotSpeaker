import Foundation
import Observation

struct RecallMeetingTurn {
    let botID: String
    let voice: String
    let text: String
    var overlapWithPrevious = false
}

typealias RecallRequest = @MainActor (String, [String: Any]) async throws -> [String: Any]

/// Keeps local-only plans independent of Recall, including status polling and cancellation.
@MainActor
enum RecallMeetingRequestRouter {
    static func handle(_ action: String, _ body: [String: Any], usesRecall: Bool,
                       ownsLocalJob: (String?) -> Bool,
                       local: RecallRequest, remote: RecallRequest) async throws -> [String: Any] {
        if !usesRecall || (body["botId"] as? String)?.hasPrefix("local:") == true || ownsLocalJob(body["id"] as? String) {
            return try await local(action, body)
        }
        var response = try await remote(action, body)
        if action == "status" {
            let localResponse = try await local(action, body)
            response["jobs"] = (response["jobs"] as? [[String: Any]] ?? []) + (localResponse["jobs"] as? [[String: Any]] ?? [])
        }
        return response
    }
}

/// Shared by GUI and CLI: prepare the selected suffix before dispatching any audio.
@MainActor
enum RecallTurnRunner {
    static func run(_ turns: [RecallMeetingTurn], startingAt start: Int = 0, request: RecallRequest,
                    progress: (Int) -> Void, skipRequested: () -> Bool = { false },
                    preparing: (Int) -> Void = { _ in },
                    completed: (Int, [String: Any], Bool) -> Void = { _, _, _ in }) async throws {
        guard turns.indices.contains(start) else { throw AppError("Start turn is outside the plan.") }
        var group: Set<String> = []
        for (index, turn) in turns.enumerated() {
            if !turn.overlapWithPrevious { group = [] }
            guard !(index == 0 && turn.overlapWithPrevious), group.insert(turn.botID).inserted else {
                throw AppError("Overlapping turns need different speakers and a preceding turn.")
            }
        }
        var pending: [String] = []
        do {
            for index in start..<turns.count {
                let turn = turns[index]
                try Task.checkCancellation()
                preparing(index)
                let response = try await request("prepare", ["botId": turn.botID, "voice": turn.voice, "text": turn.text])
                guard let id = (response["job"] as? [String: Any])?["id"] as? String else { throw AppError("Recall did not return a speech job.") }
                pending.append(id)
                try await wait(id, expected: "prepared", request: request)
            }
            let prepared = pending
            var index = start
            while index < turns.count {
                var end = index + 1
                while end < turns.count && turns[end].overlapWithPrevious { end += 1 }
                try Task.checkCancellation()
                progress(index)
                // Dispatch all distinct speakers in the group before waiting for any of them.
                for current in index..<end {
                    try Task.checkCancellation()
                    _ = try await request("dispatch", ["id": prepared[current - start]])
                }
                for current in index..<end {
                    let id = prepared[current - start]
                    try await wait(id, expected: "finished_dispatching", request: request, skipRequested: skipRequested)
                    let response = try await request("status", [:])
                    let job = (response["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == id } ?? [:]
                    completed(current, job, skipRequested())
                    pending.removeAll { $0 == id }
                }
                index = end
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
        var turnStatuses: [String]
        var history: [[String: Any]] = []
        @ObservationIgnored var task: Task<Void, Never>?
        init(_ turns: [RecallMeetingTurn]) { self.turns = turns; turnStatuses = turns.map { _ in "upcoming" } }
        var snapshot: [String: Any] {
            ["id": id, "status": status, "turnIndex": index, "turnCount": turns.count, "error": error as Any? ?? NSNull(),
             "turns": turns.enumerated().map { index, turn in
                 ["turn": index + 1, "botId": turn.botID, "voice": turn.voice, "text": turn.text,
                  "overlapWithPrevious": turn.overlapWithPrevious, "status": turnStatuses[index]] as [String: Any]
             }, "history": history]
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
                return RecallMeetingTurn(botID: bot.uuidString.lowercased(), voice: voice, text: text, overlapWithPrevious: item["overlapWithPrevious"] as? Bool ?? false)
            }
            let run = Run(turns); runs.append(run)
            return ["ok": true, "meeting": run.snapshot]
        }
        guard let id = body["id"] as? String, let run = runs.first(where: { $0.id == id }) else { throw AppError("Unknown Recall meeting plan.") }
        switch action {
        case "meeting-status": break
        case "meeting-start":
            guard run.task == nil else { throw AppError("Meeting is already running.") }
            if let value = body["startTurn"], !(value is Int) { throw AppError("startTurn must be an integer.") }
            let startTurn = body["startTurn"] as? Int ?? 1
            guard (1...run.turns.count).contains(startTurn) else { throw AppError("startTurn must be between 1 and the turn count.") }
            let start = startTurn - 1
            let bots = Set(run.turns[start...].map(\.botID))
            guard !runs.contains(where: { $0.task != nil && $0.turns.contains { bots.contains($0.botID) } }) else { throw AppError("A speaker bot is already used by another running meeting plan.") }
            for index in start..<run.turns.count { run.turnStatuses[index] = "upcoming" }
            run.status = "starting"; run.error = nil; run.index = -1; run.skip = false
            run.task = Task {
                defer { run.task = nil }
                do {
                    let response = try await request("list", [:])
                    try Task.checkCancellation()
                    let ready = Set((response["bots"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "in_call_recording" }.compactMap { $0["id"] as? String })
                    guard bots.isSubset(of: ready) else { throw AppError("Every speaker bot must be in_call_recording before starting.") }
                    run.status = "preparing"
                    try await RecallTurnRunner.run(run.turns, startingAt: start, request: request, progress: { index in
                        for current in run.turns.indices where run.turnStatuses[current] == "preparing" { run.turnStatuses[current] = "upcoming" }
                        run.index = index; run.skip = false; run.status = "running"
                        var end = index + 1
                        while end < run.turns.count && run.turns[end].overlapWithPrevious { end += 1 }
                        for current in index..<end { run.turnStatuses[current] = "playing" }
                    }, skipRequested: { run.skip }, preparing: { index in
                        for current in run.turns.indices where run.turnStatuses[current] == "preparing" { run.turnStatuses[current] = "upcoming" }
                        run.index = index; run.turnStatuses[index] = "preparing"
                    }, completed: { index, _, skipped in
                        run.turnStatuses[index] = skipped ? "skipped" : "completed"
                        run.history.append(["turn": index + 1, "status": run.turnStatuses[index], "at": Date().timeIntervalSince1970])
                    })
                    run.status = "finished"
                } catch {
                    run.status = Task.isCancelled ? "stopped" : "failed"
                    for index in run.turns.indices where ["playing", "preparing"].contains(run.turnStatuses[index]) {
                        run.turnStatuses[index] = run.status
                        run.history.append(["turn": index + 1, "status": run.status, "at": Date().timeIntervalSince1970])
                    }
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
