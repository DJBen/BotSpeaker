import SwiftUI

@main
struct BotSpeakerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("Bot Speaker", id: "composer") {
            MainWindowView(model: model)
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
