import SwiftUI

struct RecallView: View {
    let model: AppModel
    @State private var meeting = ""
    @State private var name = "BotSpeaker"
    @AppStorage("recallLastMeeting") private var lastMeeting = ""
    @State private var meetingDraft = ""
    @State private var meetingReady = false
    @State private var showingNamePrompt = false
    @State private var bots: [BotRow] = []
    @State private var bot: String?
    @State private var text = "Hi I am BotSpeaker, I am ready to help test the meeting audio."
    @State private var drafts: [String: String] = [:]
    @State private var voice = ""
    @State private var schedule = false
    @State private var dispatchDate = Date().addingTimeInterval(300)
    @State private var repeatCount = 1
    @State private var loop = false
    @State private var interval = 0.0
    @State private var error: String?
    @State private var refreshingBots = false
    @State private var busy = false

    private struct BotRow: Identifiable {
        let id: String
        let name: String
        let status: String
        let meetingID: String
        var shortID: String { String(id.prefix(8)) }
    }
    private static let sentences = ["I am ready to help test the meeting audio. I will speak at a steady pace so that everyone can check the sound and follow the conversation.\n\nFor our first task, let us agree on one useful outcome for today. We can collect ideas, compare a few options, and choose a clear next step together.\n\nBefore we finish, we will recap the decision and name the person responsible for following up. That way, everyone leaves with the same understanding and a practical plan.", "I look forward to hearing everyone's ideas. A thoughtful question can reveal something we have missed, so let us leave room for different perspectives.\n\nImagine we are planning a small community garden. We need to choose a location, decide what to grow, and work out how to share the watering schedule.\n\nA simple plan will help us get started without making everything perfect on the first day. We can learn from the first few weeks and make improvements as we go.", "Today is a good day to turn ideas into action. Let us start by describing the problem in plain language and checking that we all mean the same thing.\n\nNext, we can identify one small experiment that would teach us something useful. We should agree on what success looks like and how we will measure the result.\n\nOnce the experiment is complete, we can review the evidence together. Whether the result is encouraging or surprising, it will help us make a better decision about what comes next."]
    private var visibleBots: [BotRow] {
        let scope = RecallController.meetingID(meeting)
        return bots.filter { !scope.isEmpty && $0.meetingID == scope && $0.status != "done" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recall Bot").font(.title.bold())
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                }
                if !model.recall.configured { RecallConfigurationView(model: model) }
                if let error { Text(error).foregroundStyle(.red) }
                if model.recall.configured {
                    if meetingReady {
                        botPanel
                        speechPanel
                        jobRows
                    } else { meetingSetup }
                }
            }.padding(20).disabled(busy)
        }
        .alert("Add bot", isPresented: $showingNamePrompt) {
            TextField("Bot name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button("Add bot") { perform {
                let result = try await model.recall.handle("add", ["meetingUrl": meeting, "name": name.trimmingCharacters(in: .whitespacesAndNewlines)], model: model)
                try await refresh()
                bot = (result["bot"] as? [String: Any])?["id"] as? String
            } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)
        } message: { Text("Choose the name shown in the meeting.") }
        .task {
            if meetingDraft.isEmpty { meetingDraft = lastMeeting }
            await model.loadVoicesIfNeeded()
            if voice.isEmpty { voice = model.voices.contains(where: { $0.id == model.voiceID }) ? model.voiceID : model.voices.first?.id ?? "" }
            if bot == nil { text = starter(name) }
        }
        .task(id: meetingReady ? meeting : "") {
            guard meetingReady else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                if !busy && model.recall.configured {
                    do { try await refresh() } catch { if !Task.isCancelled { self.error = "Bot refresh failed: " + error.localizedDescription } }
                }
            }
        }
        .onChange(of: bot) { old, new in
            if let old { drafts[old] = text }
            if let new, let row = visibleBots.first(where: { $0.id == new }) { text = drafts[new] ?? starter(row.name) }
        }
        .onChange(of: meeting) { _, _ in
            if !visibleBots.contains(where: { $0.id == bot }) { bot = nil }
        }
    }
    private var meetingSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a meeting").font(.title2)
            TextField("Meeting URL or ID", text: $meetingDraft)
                .textFieldStyle(.roundedBorder).controlSize(.large).frame(minHeight: 28)
            Text("Enter a meeting URL or a previously used meeting ID. Known IDs reuse their saved join details.").foregroundStyle(.secondary)
            Button("Continue") { perform {
                let value = meetingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                if value.contains("://"), URL(string: value)?.scheme != "https" { throw AppError("Use an HTTPS meeting URL.") }
                lastMeeting = value
                meeting = value; bots = []; bot = nil; meetingReady = true
                try await refresh()
            } }.buttonStyle(.borderedProminent).disabled(meetingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.vertical, 16)
    }
    private var botPanel: some View {
        GroupBox("Meeting bots") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Meeting " + RecallController.meetingID(meeting)).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Change meeting") { meetingDraft = meeting; meetingReady = false }
                }
                Table(visibleBots, selection: $bot) {
                    TableColumn("Bot", value: \.name)
                    TableColumn("Status", value: \.status)
                    TableColumn("ID", value: \.shortID).width(85)
                }.frame(height: 125)
                HStack {
                    Button("Add bot") {
                        name = "BotSpeaker"; showingNamePrompt = true
                    }
                    Button("Refresh bots") { perform { try await refresh() } }
                    Button("Remove selected bot") { perform {
                        guard let bot else { return }
                        _ = try await model.recall.handle("remove", ["botId": bot], model: model)
                        try await refresh()
                    } }.disabled(bot == nil)
                    Spacer()
                    Text(meeting.isEmpty ? "Enter a meeting URL or ID." : "\(visibleBots.count) unfinished bots").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }
    private var speechPanel: some View {
        GroupBox("Speech") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text).frame(height: 125)
                Picker("Voice", selection: $voice) {
                    Text("Select a voice").tag("")
                    ForEach(model.voices) { item in
                        Text(item.detail.isEmpty ? item.name : "\(item.name) — \(item.detail)").tag(item.id)
                    }
                }.labelsHidden().accessibilityLabel("Voice").controlSize(.regular).padding(.vertical, 4)
                Button("New sample") { text = starter(visibleBots.first(where: { $0.id == bot })?.name ?? name) }
                if let message = model.voiceLoadError { Text(message).font(.caption).foregroundStyle(.red) }
                HStack(alignment: .center, spacing: 12) {
                    Text("Dispatch")
                    Picker("Dispatch time", selection: $schedule) {
                        Text("Now").tag(false)
                        Text("Schedule").tag(true)
                    }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                    if schedule {
                        DatePicker("Local time", selection: $dispatchDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                HStack {
                    Stepper("Repeat \(repeatCount)", value: $repeatCount, in: 1...10000).disabled(loop)
                    Toggle("Loop until cancelled", isOn: $loop)
                }
                HStack { Text("Extra gap (seconds)"); TextField("Seconds", value: $interval, format: .number).textFieldStyle(.roundedBorder).controlSize(.large).frame(width: 65, height: 28) }
                Button(schedule ? "Schedule speech" : "Speak now") { perform {
                    guard let bot else { return }
                    var body: [String: Any] = ["botId": bot, "text": text, "at": schedule ? ISO8601DateFormatter().string(from: dispatchDate) : "now", "loop": loop, "interval": interval, "voice": voice]
                    if !loop { body["repeat"] = repeatCount }
                    _ = try await model.recall.handle("speak", body, model: model)
                } }.disabled(bot == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.voices.contains(where: { $0.id == voice }))
                Text("Keep the app running and awake. Playback may start after dispatch. Cancel stops future sends; audio already sent may continue.").font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
    private var jobRows: some View {
        ForEach(model.recall.jobs.indices, id: \.self) { index in
            let job = model.recall.jobs[index]
            HStack {
                VStack(alignment: .leading) {
                    Text(job["text"] as? String ?? "").lineLimit(2)
                    Text("\(job["status"] as? String ?? "") · \(job["dispatched"] as? Int ?? 0) sent").font(.caption)
                    if let message = job["error"] as? String { Text(message).foregroundStyle(.red).font(.caption) }
                }
                Spacer()
                Button("Cancel") { perform { _ = try await model.recall.handle("cancel", ["id": job["id"] as? String ?? ""], model: model) } }
            }
        }
    }
    private func starter(_ name: String) -> String { "Hi I am \(name), \(Self.sentences.randomElement()!)" }
    private func refresh() async throws {
        guard !refreshingBots else { return }
        refreshingBots = true
        defer { refreshingBots = false }
        let scope = meeting
        guard !meeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { bots = []; bot = nil; return }
        let result = try await model.recall.handle("list", ["meetingId": scope], model: model)
        guard scope == meeting, !Task.isCancelled else { return }
        if error?.hasPrefix("Bot refresh failed: ") == true { error = nil }
        bots = (result["bots"] as? [[String: Any]] ?? []).map { item in
            BotRow(id: item["id"] as? String ?? "", name: item["bot_name"] as? String ?? "BotSpeaker", status: item["status"] as? String ?? "unknown", meetingID: item["meeting_id"] as? String ?? "")
        }
        if !visibleBots.contains(where: { $0.id == bot }) { bot = visibleBots.first?.id }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription }; busy = false }
    }
}

struct RecallConfigurationView: View {
    let model: AppModel
    @State private var key = ""
    @State private var region = "us-east-1"
    @State private var busy = false
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Recall API key (blank keeps existing key)", text: $key)
            Picker("Workspace region", selection: $region) {
                ForEach(RecallController.regions, id: \.self) { Text($0) }
            }
            Text("Uses RECALL_API_KEY or RECALL_AI_API_KEY when no key is saved. Entered keys are stored in Keychain.").font(.caption).foregroundStyle(.secondary)
            Button("Validate & save key") {
                busy = true; feedback = nil
                Task {
                    do {
                        _ = try await model.recall.handle("configure", ["apiKey": key, "region": region], model: model)
                        key = ""; feedback = "Recall configuration saved."
                    } catch { feedback = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy)
            if let feedback { Text(feedback).font(.caption) }
        }.onAppear { region = model.recall.region }
    }
}
