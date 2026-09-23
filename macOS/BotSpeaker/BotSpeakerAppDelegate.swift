import AppKit

/// All quit paths (menu bar, Cmd-Q, system termination) share the same cleanup.
@MainActor
final class BotSpeakerAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var orchestration: OrchestrationController?
    private var server: ControlServer?
    private var quitting = false

    func configure(model: AppModel, orchestration: OrchestrationController, server: ControlServer) {
        self.model = model; self.orchestration = orchestration; self.server = server
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        guard let model, let orchestration else { return .terminateNow }
        if model.isGenerating || model.player.isPlaying || model.player.isBuffering
            || orchestration.isActive || orchestration.isBusy || model.recall.hasPendingJobs
            || model.hasRecallMeetingWork || orchestration.speechRequests.contains(where: { !$0.status.isTerminal }) {
            let alert = NSAlert()
            alert.messageText = "Quit Bot Speaker?"
            alert.informativeText = "Quitting stops playback, cancels pending speech, closes the remote session, and removes orchestration speaker bots."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        quitting = true
        model.isShuttingDown = true
        Task {
            do {
                try await orchestration.prepareForExit()
                try await model.prepareRecallMeetingsForExit()
                await model.recall.cancelPendingJobs()
                model.stop()
                server?.stop()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                model.isShuttingDown = false
                quitting = false
                let alert = NSAlert()
                alert.messageText = "Couldn’t quit"
                alert.informativeText = "Bot Speaker could not finish closing the session. The app will stay open so you can retry.\n\n" + error.localizedDescription
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
