import SwiftUI

@main
struct BotSpeakerApp: App {
    @StateObject private var model: AppModel
    @StateObject private var orchestration: OrchestrationController
    @StateObject private var updates = UpdateController()

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _orchestration = StateObject(wrappedValue: OrchestrationController(model: model))
    }

    var body: some Scene {
        WindowGroup("Bot Speaker", id: "composer") {
            MainWindowView(model: model)
        }
        .defaultSize(width: 1040, height: 720)

        Window("Meeting Orchestrator", id: "orchestrator") {
            OrchestrationView(model: model, controller: orchestration)
        }
        .defaultSize(width: 820, height: 680)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.player.isPlaying ? "waveform.circle.fill" : "waveform")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Bot Speaker")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, updates: updates)
        }
    }
}
