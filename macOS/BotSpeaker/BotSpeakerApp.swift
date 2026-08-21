import SwiftUI

@main
struct BotSpeakerApp: App {
    @State private var model: AppModel
    @State private var orchestration: OrchestrationController
    @State private var updates = UpdateController()

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _orchestration = State(initialValue: OrchestrationController(model: model))
    }

    var body: some Scene {
        WindowGroup("Bot Speaker", id: "composer") {
            MainWindowView(model: model, orchestration: orchestration)
        }
        .defaultSize(width: 1040, height: 720)

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
