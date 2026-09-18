import SwiftUI
import Darwin

@main
enum BotSpeakerEntryPoint {
    @MainActor
    static func main() {
        do {
            guard let executableURL = Bundle.main.executableURL else {
                NSLog("Unable to determine BotSpeaker's executable path.")
                exit(EXIT_FAILURE)
            }
            guard let instance = try SingleInstanceGuard.acquire(executableURL: executableURL) else {
                return
            }
            // Acquire before SwiftUI constructs models, audio, updates, or the control server.
            withExtendedLifetime(instance) {
                BotSpeakerApp.main()
            }
        } catch {
            NSLog("Unable to acquire BotSpeaker's instance lock: %@", error.localizedDescription)
            exit(EXIT_FAILURE)
        }
    }
}

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
