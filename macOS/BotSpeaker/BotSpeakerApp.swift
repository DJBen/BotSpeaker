import SwiftUI

@main
struct BotSpeakerApp: App {
    @State private var model: AppModel
    @State private var orchestration: OrchestrationController
    @State private var updates = UpdateController()
    @State private var controlServer: ControlServer

    init() {
        let model = AppModel()
        let orchestration = OrchestrationController(model: model)
        let api = ControlAPI(model: model, orchestration: orchestration)
        let server = ControlServer { request in await api.handle(request) }
        _model = State(initialValue: model)
        _orchestration = State(initialValue: orchestration)
        _controlServer = State(initialValue: server)
        server.start()
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
