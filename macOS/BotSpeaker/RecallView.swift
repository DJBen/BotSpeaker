import SwiftUI

struct RecallView: View {
    let model: AppModel
    let orchestration: OrchestrationController
    @State private var speechTarget = ""
    @State private var shortSampleIndex = 0
    @State private var longSampleIndex = 1
    @State private var meeting = ""
    @State private var name = "BotSpeaker"
    @AppStorage("recallLastMeeting") private var lastMeeting = ""
    @State private var meetingDraft = ""
    @State private var passcode = ""
    @State private var meetingReady = false
    @State private var showingNamePrompt = false
    @State private var bots: [BotRow] = []
    @State private var bot: String?
    @State private var text = "Ready to help test the meeting audio."
    @State private var drafts: [String: SpeakerDraft] = [:]
    @State private var voice = ""
    @State private var schedule = false
    @State private var dispatchDate = Date().addingTimeInterval(300)
    @State private var repeatCount = 1
    @State private var loop = false
    @State private var interval = 0.0
    @State private var error: String?
    @State private var refreshingBots = false
    @State private var busy = false

    private struct SpeakerDraft {
        let text: String
        let voice: String
        let shortSampleIndex: Int
        let longSampleIndex: Int
    }

    private struct BotRow: Identifiable {
        let id: String
        let name: String
        let status: String
        let meetingID: String
        var shortID: String { String(id.prefix(8)) }
    }
    private var localHost: Bool { speechTarget == "local-host" }
    private var speakerName: String {
        localHost ? "Myself" : visibleBots.first(where: { $0.id == speechTarget })?.name ?? "Select a speaker"
    }
    private var canSpeak: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.voices.contains(where: { $0.id == voice })
            && (localHost ? (!model.isLocalPlaybackLocked && !model.selectedDeviceUID.isEmpty)
                : visibleBots.contains(where: { $0.id == speechTarget }))
    }
    private var visibleBots: [BotRow] {
        let scope = RecallController.meetingID(meeting)
        return bots.filter { !scope.isEmpty && $0.meetingID == scope && !["done", "fatal"].contains($0.status) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Meeting audio").font(.title.bold())
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                }
                if !model.recall.configured { RecallConfigurationView(model: model) }
                if let error { Text(error).foregroundStyle(.red) }
                if model.recall.configured {
                    if meetingReady {
                        botPanel
                        RecallScreenShareView(model: model, bots: visibleBots.map { .init(id: $0.id, name: $0.name, status: $0.status) }, selectedBot: bot ?? "")
                        speechPanel
                        historyPanel
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
            if text == "Ready to help test the meeting audio." { text = starter() }
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
        .onChange(of: bot) { _, new in
            if !localHost { speechTarget = new ?? "" }
        }
        .onChange(of: speechTarget) { old, new in
            drafts[old] = SpeakerDraft(
                text: text, voice: voice,
                shortSampleIndex: shortSampleIndex, longSampleIndex: longSampleIndex
            )
            let draft = drafts[new]
            text = draft?.text ?? starter()
            voice = draft?.voice ?? voice
            shortSampleIndex = draft?.shortSampleIndex ?? 0
            longSampleIndex = draft?.longSampleIndex ?? 1
            if !localHost, visibleBots.contains(where: { $0.id == new }) { bot = new }
        }
        .onChange(of: meeting) { _, _ in
            if !visibleBots.contains(where: { $0.id == bot }) { bot = nil }
        }
    }
    private var meetingSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a meeting").font(.title2)
            TextEditor(text: $meetingDraft).frame(height: 100).border(.secondary.opacity(0.3))
            SecureField("Teams passcode (for a meeting ID)", text: $passcode).textFieldStyle(.roundedBorder)
            Text("Paste a full Teams invitation, meeting link, or meeting ID and passcode. Known IDs reuse their saved join details.").foregroundStyle(.secondary)
            Button("Continue") { perform {
                let value = try await model.recall.resolveMeetingURL(meetingDraft, passcode: passcode, model: model)
                passcode = ""
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
                    Button("Remove all bots") { perform {
                        let result = try await model.recall.handle("remove-all", ["meetingId": meeting], model: model)
                        try await refresh()
                        if let failures = result["failures"] as? [[String: String]], !failures.isEmpty {
                            throw AppError(failures.map { ($0["botId"] ?? "") + ": " + ($0["error"] ?? "Removal failed") }.joined(separator: "\n"))
                        }
                    } }.disabled(visibleBots.isEmpty)
                    Spacer()
                    Text(meeting.isEmpty ? "Enter a meeting URL or ID." : "\(visibleBots.count) unfinished bots").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }
    private var speechPanel: some View {
        GroupBox("Speech") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speak as").font(.subheadline.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    speakerPicker.pickerStyle(.segmented)
                    speakerPicker.pickerStyle(.menu)
                }
                Picker("Voice", selection: $voice) {
                    Text("Select a voice").tag("")
                    ForEach(model.voices) { item in
                        Text(item.detail.isEmpty ? item.name : "\(item.name) — \(item.detail)").tag(item.id)
                    }
                }.controlSize(.regular)
                Divider()
                HStack {
                    Text("Message").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("New short sample") {
                        text = RecallSpeechSamples.short[shortSampleIndex]
                        shortSampleIndex = (shortSampleIndex + 1) % RecallSpeechSamples.short.count
                    }
                    Button("New long sample") {
                        text = RecallSpeechSamples.long[longSampleIndex]
                        longSampleIndex = (longSampleIndex + 1) % RecallSpeechSamples.long.count
                    }
                }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .frame(height: 150)
                    .accessibilityLabel("Text to speak")
                Text("\(text.split(whereSeparator: \.isWhitespace).count) words").font(.caption).foregroundStyle(.secondary)
                if let message = model.voiceLoadError { Text(message).font(.caption).foregroundStyle(.red) }
                Divider()
                Text("Playback").font(.subheadline.weight(.semibold))
                if !localHost {
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
                }
                HStack {
                    Stepper("Repeat \(repeatCount)", value: $repeatCount, in: 1...10000).disabled(loop)
                    Toggle("Loop until cancelled", isOn: $loop)
                }
                if !localHost {
                    HStack { Text("Extra gap (seconds)"); TextField("Seconds", value: $interval, format: .number).textFieldStyle(.roundedBorder).controlSize(.large).frame(width: 65, height: 28) }
                }
                HStack {
                    Text(localHost ? (model.localPlaybackLockReason ?? (model.selectedDeviceUID.isEmpty ? "Choose an audio destination in Settings." : "Uses the audio destination selected in Settings.")) : "Send audio to \(speakerName)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        submitSpeech()
                    } label: {
                        Label(!localHost && schedule ? "Schedule for \(speakerName)" : "Speak as \(speakerName)", systemImage: !localHost && schedule ? "clock" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSpeak)
                }
                if !localHost {
                    Text("Keep the app running and awake. Playback may start after dispatch. Cancel stops future sends; audio already sent may continue.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }
    private var speakerPicker: some View {
        Picker("Speak as", selection: $speechTarget) {
            Text("Myself").tag("local-host")
            if speechTarget.isEmpty { Text("Choose a bot").tag("") }
            ForEach(visibleBots) { item in
                Text(item.name).tag(item.id)
            }
        }.labelsHidden()
    }
    private func submitSpeech() {
        guard canSpeak else { return }
        perform {
            if localHost {
                try await orchestration.speak(text: text, target: .local, voiceID: voice, cycles: loop ? nil : repeatCount)
                return
            }
            var body: [String: Any] = ["botId": speechTarget, "text": text, "at": schedule ? ISO8601DateFormatter().string(from: dispatchDate) : "now", "loop": loop, "interval": interval, "voice": voice]
            if !loop { body["repeat"] = repeatCount }
            _ = try await model.recall.handle("speak", body, model: model)
        }
    }
    private var historyPanel: some View {
        GroupBox("Speech history") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.recall.jobs.isEmpty && !orchestration.speechRequests.contains(where: { $0.target == .local }) {
                        Text("Speech requests and playback status will appear here.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if orchestration.speechRequests.contains(where: { $0.target == .local }) {
                        Text("Myself").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(orchestration.speechRequests.filter { $0.target == .local }.reversed()) { request in
                        SpeechRequestRow(request: request, onCancel: {
                            perform { try await orchestration.cancelSpeech(id: request.id) }
                        })
                        Divider()
                    }
                    if !model.recall.jobs.isEmpty {
                        Text("Bots").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    jobRows
                }.padding(8)
            }.frame(height: 180)
        }
    }
    private var jobRows: some View {
        ForEach(model.recall.jobs.indices.reversed(), id: \.self) { index in
            let job = model.recall.jobs[index]
            HStack {
                VStack(alignment: .leading) {
                    Text(job["text"] as? String ?? "").lineLimit(2)
                    Text("\(job["botName"] as? String ?? visibleBots.first(where: { $0.id == job["botId"] as? String })?.name ?? "Bot") · \((job["status"] as? String ?? "").replacingOccurrences(of: "_", with: " ").capitalized) · \(job["dispatched"] as? Int ?? 0) sent").font(.caption)
                    if let message = job["error"] as? String { Text(message).foregroundStyle(.red).font(.caption) }
                }
                Spacer()
                if !["finished_dispatching", "cancelled", "failed"].contains(job["status"] as? String ?? "") {
                    Button("Cancel") { perform { _ = try await model.recall.handle("cancel", ["id": job["id"] as? String ?? ""], model: model) } }
                }
            }
            Divider()
        }
    }
    private func starter() -> String { RecallSpeechSamples.long[0] }
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
