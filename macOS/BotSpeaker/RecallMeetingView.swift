import SwiftUI
import Observation

@MainActor @Observable
final class RecallMeetingPlan {
    struct Speaker: Identifiable, Equatable {
        let id = UUID()
        var configuration: OrchestratedSpeakerConfiguration
        var name: String { get { configuration.name } set { configuration.name = newValue } }
        var voice: String { get { configuration.voiceID } set { configuration.voiceID = newValue } }
        var bot = ""
        var status = "Not added"
    }
    struct Turn: Identifiable {
        let id = UUID()
        var speaker: Int
        var text: String
    }
    var title = ""
    var meeting = UserDefaults.standard.string(forKey: "recallLastMeeting") ?? ""
    var step = 0
    var speakers: [Speaker] = []
    var turns: [Turn] = []
    var message = ""
    var busy = false
    var running = false
    var skipRequested = false
    @ObservationIgnored private var source: OrchestrationController?
    @ObservationIgnored private var templateID = ""
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func configure(_ source: OrchestrationController, model: AppModel) throws {
        guard speakers.isEmpty else { return }
        let parsed = try OrchestratedScriptParser.parse(source.meetingScriptText, speakerCount: source.selectedTemplate.speakerCount)
        self.source = source; templateID = source.selectedTemplate.id
        title = source.selectedTemplate.title
        speakers = source.speakerConfigurations.map { Speaker(configuration: $0) }
        turns = parsed.map { Turn(speaker: $0.speakerIndex, text: $0.text) }
    }
    func persistSpeakers() {
        source?.saveRecallSpeakerConfigurations(templateID: templateID, configurations: speakers.map(\.configuration))
    }
    func selectVoice(_ index: Int, voice: String, model: AppModel) {
        if !speakers[index].bot.isEmpty && speakers[index].configuration.customName.isEmpty {
            let joinedName = speakers[index].name; speakers[index].name = joinedName
        }
        speakers[index].voice = voice
        speakers[index].configuration.voiceName = model.voices.first { $0.id == voice }?.name ?? ""
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy && !running else { return }
        busy = true
        Task { defer { busy = false }; do { message = ""; try await action() } catch { message = error.localizedDescription } }
    }
    func refresh(_ model: AppModel) async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let response = try await model.recall.handle("list", ["meetingId": meeting], model: model)
        let bots = response["bots"] as? [[String: Any]] ?? []
        for index in speakers.indices where !speakers[index].bot.isEmpty {
            speakers[index].status = bots.first { $0["id"] as? String == speakers[index].bot }?["status"] as? String ?? "Unavailable"
        }
    }
    func toggleBot(_ index: Int, model: AppModel) async throws {
        if speakers[index].bot.isEmpty {
            let name = speakers[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw AppError("Enter a speaker name.") }
            let result = try await model.recall.handle("add", ["meetingUrl": meeting, "name": name], model: model)
            guard let bot = result["bot"] as? [String: Any], let id = bot["id"] as? String else { throw AppError("Recall did not return a bot.") }
            speakers[index].bot = id; speakers[index].status = bot["status"] as? String ?? "Joining"
        } else {
            _ = try await model.recall.handle("remove", ["botId": speakers[index].bot], model: model)
            speakers[index].bot = ""; speakers[index].status = "Not added"
        }
    }
    func removeAllBots(_ model: AppModel) async {
        var failures: [String] = []
        for index in speakers.indices where !speakers[index].bot.isEmpty {
            do {
                _ = try await model.recall.handle("remove", ["botId": speakers[index].bot], model: model)
                speakers[index].bot = ""; speakers[index].status = "Not added"
            } catch { failures.append("\(speakers[index].name): \(error.localizedDescription)") }
        }
        message = failures.isEmpty ? "All speaker bots removed." : "Some bots could not be removed. Retry Remove all bots.\n" + failures.joined(separator: "\n")
    }

    func resolved(_ text: String) -> String {
        speakers.enumerated().reduce(text) { $0.replacingOccurrences(of: "{{speaker_\($1.offset + 1)}}", with: $1.element.name) }
    }
    func start(_ model: AppModel) async throws {
        guard !turns.isEmpty, turns.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AppError("Add nonempty speech for each turn.") }
        try await refresh(model)
        guard speakers.allSatisfy({ $0.status == "in_call_recording" }) else { throw AppError("Wait until every speaker bot is in_call_recording. Admit bots from the lobby if needed.") }
        running = true
        task = Task {
            var activeJob: String?
            defer { running = false; skipRequested = false; task = nil }
            do {
                for (index, turn) in turns.enumerated() {
                    try Task.checkCancellation()
                    skipRequested = false
                    let speaker = speakers[turn.speaker]
                    message = "Turn \(index + 1) of \(turns.count) · \(speaker.name)\n\n\(resolved(turn.text))"
                    let result = try await model.recall.handle("speak", ["botId": speaker.bot, "voice": speaker.voice, "text": resolved(turn.text)], model: model)
                    guard let job = result["job"] as? [String: Any], let id = job["id"] as? String else { throw AppError("Recall did not return a speech job.") }
                    activeJob = id
                    while true {
                        try Task.checkCancellation()
                        if skipRequested {
                            _ = try await model.recall.handle("cancel", ["id": id], model: model)
                            break
                        }
                        guard let state = model.recall.jobs.first(where: { $0["id"] as? String == id }) else { throw AppError("Speech job was lost.") }
                        let status = state["status"] as? String
                        if status == "finished_dispatching" { break }
                        if status == "failed" || status == "cancelled" { throw AppError(state["error"] as? String ?? "Speech was cancelled.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    activeJob = nil
                }
                message = "All turns dispatched. Bots remain in the meeting; use Back to bots to remove them."
            } catch {
                if Task.isCancelled {
                    if let id = activeJob { _ = try? await model.recall.handle("cancel", ["id": id], model: model) }
                    message = "Stopped. Audio already sent may finish playing. Bots remain available in Back to bots."
                } else { message = error.localizedDescription }
            }
        }
    }
    func stop() { task?.cancel() }
}

struct RecallMeetingView: View {
    let model: AppModel
    @Bindable var plan: RecallMeetingPlan
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recall.ai · \(plan.title)").font(.title.bold())
                Text("1  Meeting   →   2  Speaker bots   →   3  Arrange turns").foregroundStyle(.secondary)
                if !plan.message.isEmpty { Text(plan.message).textSelection(.enabled) }
                if plan.running {
                    HStack {
                        Button("Skip turn") { plan.skipRequested = true }.disabled(plan.skipRequested)
                        Button("Stop meeting") { plan.stop() }
                    }
                    Text("Skip advances to the next turn. Audio already sent may finish playing over the next speaker.").font(.caption)
                } else {
                    controls.disabled(plan.busy)
                }
            }.padding(22)
        }
        .onChange(of: plan.speakers) { _, _ in plan.persistSpeakers() }
        .task {
            await model.loadVoicesIfNeeded()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if plan.step > 0 && !plan.busy && !plan.running {
                    do { try await plan.refresh(model) } catch { plan.message = error.localizedDescription }
                }
            }
        }
    }
    @ViewBuilder private var controls: some View {
        if plan.step == 0 {
            if !model.recall.configured { RecallConfigurationView(model: model) }
            TextField("Meeting URL or ID", text: $plan.meeting).textFieldStyle(.roundedBorder)
            Text("For a new meeting, paste its full invite link, including any passcode.").font(.caption)
            HStack {
                Button("Back") { onBack() }
                Button("Continue to bots") { plan.perform {
                    guard model.recall.configured else { throw AppError("Configure Recall first.") }
                    plan.meeting = plan.meeting.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !plan.meeting.isEmpty else { throw AppError("Enter a meeting URL or ID.") }
                    if plan.meeting.contains("://") && URL(string: plan.meeting)?.scheme != "https" { throw AppError("Use an HTTPS meeting URL.") }
                    UserDefaults.standard.set(plan.meeting, forKey: "recallLastMeeting"); plan.step = 1
                }}.buttonStyle(.borderedProminent)
            }
        } else if plan.step == 1 {
            Text("Meeting \(RecallController.meetingID(plan.meeting))")
            Text("Arrange turns adds any missing speaker bots to your meeting. Admit them from the lobby if needed.")
            ForEach(plan.speakers.indices, id: \.self) { index in
                GroupBox("Speaker \(index + 1)") {
                    VStack(alignment: .leading) {
                        TextField("Speaker name", text: $plan.speakers[index].name).textFieldStyle(.roundedBorder).disabled(!plan.speakers[index].bot.isEmpty)
                        Picker("Voice", selection: Binding(get: { plan.speakers[index].voice }, set: { plan.selectVoice(index, voice: $0, model: model) })) {
                            ForEach(model.voices) { voice in Text(voice.name).tag(voice.id) }
                        }.labelsHidden().controlSize(.small)
                        HStack {
                            if !plan.speakers[index].bot.isEmpty {
                                Button("Remove bot") { plan.perform { try await plan.toggleBot(index, model: model) } }
                            }
                            Text(plan.speakers[index].status).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }
            }
            HStack {
                if plan.speakers.allSatisfy({ $0.bot.isEmpty }) { Button("Change meeting") { plan.step = 0 } }
                Button("Refresh bots") { plan.perform { try await plan.refresh(model) } }
                Button("Remove all bots") { plan.perform { await plan.removeAllBots(model) } }
                    .disabled(plan.speakers.allSatisfy { $0.bot.isEmpty })
                Button("Arrange turns") { plan.perform {
                    for index in plan.speakers.indices where plan.speakers[index].bot.isEmpty {
                        plan.message = "Adding \(plan.speakers[index].name) to the meeting…"
                        try await plan.toggleBot(index, model: model)
                    }
                    plan.step = 2
                    plan.message = "Speaker bots have been sent to the meeting. Admit them from the lobby if needed."
                    try await plan.refresh(model)
                } }
                    .disabled(plan.speakers.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.voice.isEmpty }).buttonStyle(.borderedProminent)
            }
        } else {
            ForEach(plan.speakers) { speaker in Text("\(speaker.name): \(speaker.status)").font(.caption) }
            Text("Turns play in order. Timing uses clip duration plus a short pause; Recall does not confirm when playback ends.").font(.caption)
            HStack {
                Button("Back to bots") { plan.step = 1 }
                Button("Add turn") { plan.turns.append(.init(speaker: 0, text: "Enter speech here.")) }
                Button("Start meeting") { plan.perform { try await plan.start(model) } }.buttonStyle(.borderedProminent)
            }
            ForEach(plan.turns.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    HStack {
                        Text("\(index + 1).")
                        Picker("Speaker", selection: $plan.turns[index].speaker) {
                            ForEach(plan.speakers.indices, id: \.self) { i in Text(plan.speakers[i].name).tag(i) }
                        }.labelsHidden()
                        Button("↑") { plan.turns.swapAt(index, index-1) }.disabled(index == 0)
                        Button("↓") { plan.turns.swapAt(index, index+1) }.disabled(index == plan.turns.count-1)
                        Button("Remove turn") { plan.turns.remove(at: index) }
                    }
                    TextEditor(text: Binding(get: { plan.resolved(plan.turns[index].text) }, set: { plan.turns[index].text = $0 })).frame(minHeight: 90)
                }
            }
        }
    }
}
