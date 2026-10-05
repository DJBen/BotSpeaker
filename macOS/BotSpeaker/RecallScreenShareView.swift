import SwiftUI

/// Shares the controller with CLI/API requests; independent of speech preparation and playback.
struct RecallScreenShareView: View {
    struct Bot: Identifiable {
        let id: String
        let name: String
        let status: String
    }
    let model: AppModel
    let bots: [Bot]
    var selectedBot: String? = nil
    @State private var selection = ""
    @State private var error: String?

    private var target: Bot? { bots.first { $0.id == (selectedBot ?? selection) } }
    private var state: String { target.flatMap { model.recall.screenShare($0.id)?["state"] as? String } ?? "" }
    private var busy: Bool { ["starting", "stopping"].contains(state) }

    var body: some View {
        GroupBox("Screen share") {
            VStack(alignment: .leading, spacing: 8) {
                if selectedBot == nil {
                    Picker("Presenting bot", selection: $selection) {
                        Text("Select a bot").tag("")
                        ForEach(bots) { bot in Text(bot.name).tag(bot.id) }
                    }
                } else if let target { Text("Presenting bot: \(target.name)") }
                HStack {
                    Button("Share test screen") { request("screenshare-start") }
                        .disabled(target == nil || busy || !["in_call_recording", "in_call_not_recording"].contains(target?.status ?? ""))
                    Button("Stop sharing") { request("screenshare-stop") }
                        .disabled(target == nil || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !state.isEmpty { Text(state.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption) }
                if let message = error ?? target.flatMap({ model.recall.screenShare($0.id)?["error"] as? String }) {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                Text("Shows a test card from a remote bot. Sharing works independently of speech. Check the meeting to confirm it is visible; the host must allow this bot to present.").font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
        .onChange(of: bots.map(\.id), initial: true) { _, ids in
            if !ids.contains(selection) { selection = ids.first ?? "" }
        }
        .onChange(of: target?.id) { _, _ in error = nil }
    }

    private func request(_ action: String) {
        guard let target else { return }
        error = nil
        Task { @MainActor in
            do { _ = try await model.recall.handle(action, ["botId": target.id], model: model) }
            catch { self.error = error.localizedDescription }
        }
    }
}
