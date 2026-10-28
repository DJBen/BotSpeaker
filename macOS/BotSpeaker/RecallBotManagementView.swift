import SwiftUI

/// Account-wide cleanup, independent of the selected meeting or script.
struct RecallBotManagementView: View {
    let model: AppModel
    @State private var bots: [Bot] = []
    @State private var selection: Set<String> = []
    @State private var leaveRequested: Set<String> = []
    @State private var loadedRegion: String?
    @State private var refreshedAt: Date?
    @State private var refreshing = false
    @State private var removing = false
    @State private var refreshError: String?
    @State private var removalError: String?

    private struct Bot: Identifiable {
        let id: String
        let name: String
        let status: String
        let meeting: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage Bots").font(.title.bold())
                Spacer()
                if refreshing || removing { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(!model.recall.configured || refreshing || removing)
            }
            Text("Unfinished bots across all meetings in your Recall workspace (\(model.recall.region)). Joining and waiting-room bots are included; bots that have left their calls are hidden.")
                .foregroundStyle(.secondary)
            if !model.recall.configured {
                RecallConfigurationView(model: model)
            } else {
                if let error = removalError ?? refreshError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Table(bots, selection: $selection) {
                    TableColumn("Bot") { bot in
                        VStack(alignment: .leading) {
                            Text(bot.name)
                            Text(String(bot.id.prefix(8))).font(.caption).foregroundStyle(.secondary)
                        }.help(bot.id)
                    }
                    TableColumn("Status") { bot in
                        VStack(alignment: .leading) {
                            Text(bot.status.replacingOccurrences(of: "_", with: " "))
                            if leaveRequested.contains(bot.id) {
                                Text("Leave requested").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Meeting", value: \.meeting)
                    TableColumn("Actions") { bot in
                        Button(leaveRequested.contains(bot.id) ? "Retry removal" : "Remove bot") {
                            remove([bot.id])
                        }
                        .disabled(removing || refreshing || loadedRegion != model.recall.region)
                    }.width(110)
                }
                .overlay {
                    if bots.isEmpty {
                        if refreshing && refreshedAt == nil {
                            Text("Loading bots…").foregroundStyle(.secondary)
                        } else if refreshedAt != nil && refreshError == nil {
                            ContentUnavailableView("No unfinished bots", systemImage: "checkmark.circle", description: Text("There are no active bots in this Recall workspace."))
                        }
                    }
                }
                HStack {
                    Button("Remove selected (\(selection.count))") { remove(selection) }
                        .disabled(selection.isEmpty || removing || refreshing || loadedRegion != model.recall.region)
                    Spacer()
                    if let refreshedAt {
                        Text("\(bots.count) unfinished · Updated \(refreshedAt, style: .time)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Removing a bot makes it leave its meeting and cancels its queued speech. Bots remain visible until Recall reports that they have left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .task(id: "\(model.recall.configured)-\(model.recall.region)") {
            bots = []; selection = []; leaveRequested = []; refreshedAt = nil; loadedRegion = nil
            guard model.recall.configured else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if !removing { await refresh() }
            }
        }
    }

    @MainActor private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let region = model.recall.region
        do {
            let response = try await model.recall.handle("list", ["activeOnly": true], model: model)
            guard !Task.isCancelled, region == model.recall.region else { return }
            bots = (response["bots"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return Bot(id: id, name: item["bot_name"] as? String ?? "BotSpeaker",
                           status: item["status"] as? String ?? "unknown",
                           meeting: item["meeting_id"] as? String ?? "Unknown meeting")
            }.sorted { ($0.meeting, $0.name, $0.id) < ($1.meeting, $1.name, $1.id) }
            let ids = Set(bots.map(\.id))
            selection.formIntersection(ids)
            leaveRequested.formIntersection(ids)
            loadedRegion = region
            refreshedAt = Date()
            refreshError = nil
        } catch {
            if !Task.isCancelled { refreshError = "Could not refresh bots: " + error.localizedDescription }
        }
    }

    private func remove(_ ids: Set<String>) {
        guard !removing, !refreshing, loadedRegion == model.recall.region else { return }
        let targets = bots.filter { ids.contains($0.id) }
        let region = model.recall.region
        removing = true
        removalError = nil
        Task { @MainActor in
            defer { removing = false }
            var failures: [String] = []
            for bot in targets {
                guard model.recall.region == region else {
                    failures.append("Recall region changed. Refresh before removing more bots.")
                    break
                }
                do {
                    _ = try await model.recall.handle("remove", ["botId": bot.id], model: model)
                    leaveRequested.insert(bot.id)
                } catch { failures.append("\(bot.name) (\(bot.id.prefix(8))): \(error.localizedDescription)") }
            }
            removalError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            await refresh()
        }
    }
}
