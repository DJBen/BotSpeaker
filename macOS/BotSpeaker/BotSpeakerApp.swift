import SwiftUI

@main
struct BotSpeakerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("Bot Speaker", id: "composer") {
            MainWindowView(model: model)
        }
        .defaultSize(width: 560, height: 620)

        Window("Custom Script", id: "script-editor") {
            CustomScriptEditorWindow(model: model)
        }
        .defaultSize(width: 620, height: 560)

        MenuBarExtra {
            MenuBarView(model: model)
            Divider()
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
        } label: {
            Image(systemName: model.player.isPlaying ? "waveform.circle.fill" : "waveform")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Bot Speaker")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
