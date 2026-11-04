import AppKit
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
        var overlapWithPrevious = false
    }
    var title = ""
    var meeting = UserDefaults.standard.string(forKey: "recallLastMeeting") ?? ""
    var passcode = ""
    var localSpeakerIndices: Set<Int> = [] { didSet { persistHostPreferences() } }
    var exportGroundTruth = false
    var artifactURL: URL?
    var allSpeakersLocal: Bool { !speakers.isEmpty && speakers.indices.allSatisfy { localSpeakerIndices.contains($0) } }
    func isLocal(_ index: Int) -> Bool { localSpeakerIndices.contains(index) }
    func speakerName(_ index: Int) -> String { speakers[index].name }
    var preparing = false
    var step = 0
    var speakers: [Speaker] = [] {
        didSet {
            if oldValue.map(\.configuration) != speakers.map(\.configuration) { persistSpeakers() }
        }
    }
    var turns: [Turn] = []
    var message = ""
    var busy = false
    var running = false
    var skipRequested = false
    @ObservationIgnored private var source: OrchestrationController?
    @ObservationIgnored private var templateID = ""
    @ObservationIgnored private var restoringPreferences = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func configure(_ source: OrchestrationController, model: AppModel) throws {
        guard speakers.isEmpty else { return }
        let parsed = try OrchestratedScriptParser.parse(source.meetingScriptText, speakerCount: source.selectedTemplate.speakerCount)
        self.source = source; templateID = source.selectedTemplate.id
        restoringPreferences = true
        let hostPreferences = UserDefaults.standard.dictionary(forKey: "orchestratedMeetingHostPreferences")?[templateID] as? [String: Any]
        let preferences = RecallLocalSpeakerPreferences(saved: hostPreferences, speakerCount: source.speakerConfigurations.count)
        localSpeakerIndices = preferences.indices
        title = source.selectedTemplate.title
        speakers = source.speakerConfigurations.map { Speaker(configuration: $0) }
        if let name = preferences.legacyHostName, !speakers.isEmpty { speakers[0].name = name }
        restoringPreferences = false
        persistHostPreferences()
        turns = parsed.enumerated().map { Turn(speaker: $0.element.speakerIndex, text: $0.element.text, overlapWithPrevious: source.selectedTemplate.overlapTurnIndices.contains($0.offset)) }
    }
    private func persistHostPreferences() {
        guard !restoringPreferences, !templateID.isEmpty else { return }
        var saved = UserDefaults.standard.dictionary(forKey: "orchestratedMeetingHostPreferences") ?? [:]
        var preferences = RecallLocalSpeakerPreferences(saved: nil, speakerCount: speakers.count)
        preferences.indices = localSpeakerIndices
        saved[templateID] = preferences.saved
        UserDefaults.standard.set(saved, forKey: "orchestratedMeetingHostPreferences")
    }
    func persistSpeakers() {
        source?.saveRecallSpeakerConfigurations(templateID: templateID, configurations: speakers.map(\.configuration))
    }
    func selectVoice(_ index: Int, voice: String, model: AppModel) {
        if !speakers[index].bot.isEmpty && speakers[index].configuration.customName.isEmpty {
            let joinedName = speakers[index].name; speakers[index].name = joinedName
        }
        speakers[index].voice = voice
        // Never blank the stored name: an unnamed speaker is named after its
        // voice, and an empty name falls back to the {{speaker_n}} placeholder.
        speakers[index].configuration.voiceName = model.voices.first { $0.id == voice }?.name
            ?? "Voice ID \(voice.prefix(8))…"
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy && !running else { return }
        busy = true
        Task { defer { busy = false }; do { message = ""; try await action() } catch { message = error.localizedDescription } }
    }
    func refresh(_ model: AppModel) async throws {
        guard !allSpeakersLocal, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let response = try await model.recall.handle("list", ["meetingId": meeting], model: model)
        let bots = response["bots"] as? [[String: Any]] ?? []
        for index in speakers.indices where !speakers[index].bot.isEmpty {
            speakers[index].status = bots.first { $0["id"] as? String == speakers[index].bot }?["status"] as? String ?? "Unavailable"
        }
    }
    func toggleBot(_ index: Int, model: AppModel) async throws {
        guard !isLocal(index) else { return }
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
        speakers.enumerated().reduce(text) { $0.replacingOccurrences(of: "{{speaker_\($1.offset + 1)}}", with: speakerName($1.offset)) }
    }
    func start(_ model: AppModel) async throws {
        guard !turns.isEmpty, turns.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AppError("Add nonempty speech for each turn.") }
        guard turns.allSatisfy({ speakers.indices.contains($0.speaker) }) else { throw AppError("A turn has an invalid speaker.") }
        let outputDevice = model.selectedDeviceUID
        var preferences = RecallLocalSpeakerPreferences(saved: nil, speakerCount: speakers.count)
        preferences.indices = localSpeakerIndices
        if outputDevice == DirectMicPlayer.deviceUID,
           preferences.hasOverlappingLocalSpeakers(turns.map { ($0.speaker, $0.overlapWithPrevious) }) {
            throw AppError("DirectMic supports one local speaker at a time. For overlapping local speakers, select a virtual output such as BlackHole in Settings, or remove the overlap between their turns.")
        }
        try await refresh(model)
        guard speakers.indices.allSatisfy({ isLocal($0) || speakers[$0].status == "in_call_recording" }) else { throw AppError("Wait until every speaker bot is in_call_recording. Admit bots from the lobby if needed.") }
        running = true
        artifactURL = nil
        task = Task {
            let local = LocalMeetingSpeech(outputDevice: outputDevice)
            defer { local.stop() }
            var origin: Date?
            var recorded: [[String: Any]] = []
            defer { running = false; preparing = false; skipRequested = false; task = nil }
            do {
                preparing = true
                let preparedTurns = turns.map { turn in
                    let speaker = speakers[turn.speaker]
                    return RecallMeetingTurn(botID: isLocal(turn.speaker) ? "local:\(turn.speaker)" : speaker.bot, voice: speaker.voice, text: resolved(turn.text), overlapWithPrevious: turn.overlapWithPrevious)
                }
                try await RecallTurnRunner.run(preparedTurns, request: { action, body in
                    try await RecallMeetingRequestRouter.handle(action, body, usesRecall: !allSpeakersLocal,
                        ownsLocalJob: { local.owns($0) },
                        local: { try await local.handle($0, $1, model: model) },
                        remote: { try await model.recall.handle($0, $1, model: model) })
                }, progress: { index in
                    if origin == nil { origin = Date() }
                    preparing = false; skipRequested = false
                    var end = index + 1
                    while end < turns.count && turns[end].overlapWithPrevious { end += 1 }
                    message = (index..<end).map { "Turn \($0 + 1) of \(turns.count) · \(speakerName(turns[$0].speaker))\n\n\(preparedTurns[$0].text)" }.joined(separator: "\n\nOverlapping with\n\n")
                }, skipRequested: { skipRequested }, preparing: { index in
                    message = "Preparing turn \(index + 1) of \(turns.count)…"
                }, completed: { index, job, skipped in
                    guard !skipped, let origin, let start = job["acceptedAtEpoch"] as? Double,
                          let duration = job["durationSeconds"] as? Double else { return }
                    recorded.append(MeetingGroundTruth.turn(speaker: turns[index].speaker, name: speakerName(turns[index].speaker), text: preparedTurns[index].text, start: start - origin.timeIntervalSince1970, duration: duration, local: isLocal(turns[index].speaker)))
                })
                if exportGroundTruth, let origin {
                    artifactURL = try MeetingGroundTruth.save(meetingID: allSpeakersLocal ? "local-\(UUID().uuidString)" : RecallController.meetingID(meeting), names: speakers.indices.map { speakerName($0) }, localSpeakers: localSpeakerIndices, origin: origin, turns: recorded)
                }
                message = allSpeakersLocal ? "All local turns finished." : "All turns dispatched. Use Remove all bots to make the speaker bots leave."
            } catch {
                message = Task.isCancelled
                    ? (allSpeakersLocal ? "Local playback stopped." : "Stopped. Audio already sent may finish playing. Use Remove all bots when finished.")
                    : error.localizedDescription
            }
        }
    }
    func stopAndWait() async { task?.cancel(); await task?.value }

    func stop() { task?.cancel() }
}

struct RecallMeetingView: View {
    let model: AppModel
    @Bindable var plan: RecallMeetingPlan
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(plan.allSpeakersLocal ? "Local playback" : "Recall.ai") · \(plan.title)").font(.title.bold())
                Text(plan.allSpeakersLocal ? "1  Setup   →   2  Speakers   →   3  Arrange turns" : "1  Meeting   →   2  Speaker bots   →   3  Arrange turns").foregroundStyle(.secondary)
                if let url = plan.artifactURL {
                    Button("Reveal ground truth artifact") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if !plan.message.isEmpty { Text(plan.message).textSelection(.enabled) }
                if plan.step > 0 && !plan.allSpeakersLocal {
                    RecallScreenShareView(model: model, bots: plan.speakers.filter { !$0.bot.isEmpty }.map { .init(id: $0.bot, name: $0.name, status: $0.status) })
                }
                if plan.running {
                    HStack {
                        Button("Skip turn / overlap group") { plan.skipRequested = true }.disabled(plan.skipRequested || plan.preparing)
                        Button("Stop meeting") { plan.stop() }
                    }
                    Text("Skip advances past the current turn or simultaneous group. Audio already sent may finish playing over the next speaker.").font(.caption)
                } else {
                    controls.disabled(plan.busy)
                }
            }.padding(22)
        }
        .task {
            await model.loadVoicesIfNeeded()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if plan.step > 0 && !plan.allSpeakersLocal && !plan.busy {
                    do { try await plan.refresh(model) } catch { plan.message = error.localizedDescription }
                }
            }
        }
    }
    @ViewBuilder private var controls: some View {
        if plan.step == 0 {
            if !plan.allSpeakersLocal {
                if !model.recall.configured { RecallConfigurationView(model: model) }
                Text("Paste a meeting invitation, join link, or Teams meeting ID.")
                TextEditor(text: $plan.meeting).frame(height: 90).border(.secondary.opacity(0.3))
                SecureField("Teams passcode (for a meeting ID)", text: $plan.passcode).textFieldStyle(.roundedBorder)
            } else {
                Text("All speakers play on this computer. No meeting link or Recall configuration is needed.")
            }
            GroupBox("Local speakers and ground truth") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.speakers.indices, id: \.self) { index in
                        Toggle("Speaker \(index + 1): \(plan.speakerName(index)) · Play locally", isOn: Binding(
                            get: { plan.isLocal(index) },
                            set: { selected in
                                if selected { plan.localSpeakerIndices.insert(index) }
                                else { plan.localSpeakerIndices.remove(index) }
                            }
                        ))
                    }
                    Text("Select any number of speakers to play through this computer. Each keeps their own name and voice. Invites \(plan.speakers.count - plan.localSpeakerIndices.count) bots.").font(.caption)
                    if !plan.localSpeakerIndices.isEmpty {
                        Text("Local speech uses the audio destination selected in Settings. Select the same virtual device as your microphone in the meeting app.").font(.caption)
                    }
                    Toggle("Produce ground truth after the meeting", isOn: $plan.exportGroundTruth)
                    if plan.exportGroundTruth {
                        Text("Saves gt_final.json with scripted text and estimated playback times relative to the first turn. Align this origin with your recording before scoring. Skipped turns are omitted.").font(.caption)
                    }
                }.padding(6)
            }
            HStack {
                Button("Back") { onBack() }
                Button(plan.allSpeakersLocal ? "Continue to speakers" : "Continue to bots") { plan.perform {
                    if plan.allSpeakersLocal { plan.passcode = ""; plan.step = 1; return }
                    guard model.recall.configured else { throw AppError("Configure Recall first.") }
                    plan.meeting = try await model.recall.resolveMeetingURL(plan.meeting, passcode: plan.passcode, model: model)
                    plan.passcode = ""
                    UserDefaults.standard.set(plan.meeting, forKey: "recallLastMeeting"); plan.step = 1
                }}.buttonStyle(.borderedProminent)
            }
        } else if plan.step == 1 {
            if plan.allSpeakersLocal {
                Text("Choose each local speaker’s name and voice, then arrange turns.")
            } else {
                Text("Meeting \(RecallController.meetingID(plan.meeting))")
                Text("Arrange turns adds any missing speaker bots to your meeting. Admit them from the lobby if needed.")
            }
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
                            Text(plan.isLocal(index) ? "Local playback" : plan.speakers[index].status).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }
            }
            HStack {
                if plan.speakers.allSatisfy({ $0.bot.isEmpty }) { Button(plan.allSpeakersLocal ? "Change setup" : "Change meeting") { plan.step = 0 } }
                if !plan.allSpeakersLocal {
                    Button("Refresh bots") { plan.perform { try await plan.refresh(model) } }
                    Button("Remove all bots") { plan.perform { await plan.removeAllBots(model) } }
                        .disabled(plan.speakers.allSatisfy { $0.bot.isEmpty })
                }
                Button("Arrange turns") { plan.perform {
                    for index in plan.speakers.indices where !plan.isLocal(index) && plan.speakers[index].bot.isEmpty {
                        plan.message = "Adding \(plan.speakers[index].name) to the meeting…"
                        try await plan.toggleBot(index, model: model)
                    }
                    plan.step = 2
                    plan.message = plan.allSpeakersLocal ? "Ready for local playback." : "Speaker bots have been sent to the meeting. Admit them from the lobby if needed."
                    try await plan.refresh(model)
                } }
                    .disabled(plan.speakers.indices.contains { plan.speakerName($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plan.speakers[$0].voice.isEmpty }).buttonStyle(.borderedProminent)
            }
        } else {
            ForEach(plan.speakers.indices, id: \.self) { i in Text("\(plan.speakerName(i)): \(plan.isLocal(i) ? "This computer" : plan.speakers[i].status)").font(.caption) }
            Text(plan.allSpeakersLocal ? "All audio is prepared before local playback begins." : "Turns play in order. All audio is prepared before playback. Timing uses clip duration; Recall does not confirm when playback ends.").font(.caption)
            HStack {
                Button(plan.allSpeakersLocal ? "Back to speakers" : "Back to bots") { plan.step = 1 }
                if !plan.allSpeakersLocal {
                    Button("Remove all bots") { plan.perform { await plan.removeAllBots(model) } }
                        .disabled(plan.speakers.allSatisfy { $0.bot.isEmpty })
                }
                Button("Add turn") { plan.turns.append(.init(speaker: 0, text: "Enter speech here.")) }
                Button(plan.allSpeakersLocal ? "Start playback" : "Start meeting") { plan.perform { try await plan.start(model) } }.buttonStyle(.borderedProminent)
            }
            ForEach(plan.turns.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    HStack {
                        Text("\(index + 1).")
                        Picker("Speaker", selection: $plan.turns[index].speaker) {
                            ForEach(plan.speakers.indices, id: \.self) { i in Text(plan.speakerName(i)).tag(i) }
                        }.labelsHidden()
                        Button("↑") { plan.turns.swapAt(index, index-1) }.disabled(index == 0)
                        Button("↓") { plan.turns.swapAt(index, index+1) }.disabled(index == plan.turns.count-1)
                        Button("Remove turn") { plan.turns.remove(at: index) }
                    }
                    Toggle("Start together with previous turn (different speaker)", isOn: $plan.turns[index].overlapWithPrevious)
                    TextEditor(text: Binding(get: { plan.resolved(plan.turns[index].text) }, set: { plan.turns[index].text = $0 })).frame(minHeight: 90)
                }
            }
        }
    }
}
