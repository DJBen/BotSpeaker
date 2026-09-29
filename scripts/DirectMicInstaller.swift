import AppKit
import Foundation

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.presentInstaller() }
    }

    private func presentInstaller() {
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.terminate(nil) }
        let confirmation = NSAlert()
        confirmation.messageText = "Install DirectMic?"
        confirmation.informativeText = "Installation requires administrator authorization and briefly interrupts audio in all apps. End active calls and recordings first. After installation, select DirectMic as your meeting microphone."
        confirmation.addButton(withTitle: "Install")
        confirmation.addButton(withTitle: "Cancel")
        if confirmation.runModal() == .alertFirstButtonReturn {
            let error: String?
            if let driver = Bundle.main.url(forResource: "DirectMic", withExtension: "driver") {
                error = DirectMicInstaller.install(driverPath: driver.path)
            } else {
                error = "The bundled driver is missing. Download BotSpeaker again."
            }
            NSApp.activate(ignoringOtherApps: true)
            let result = NSAlert()
            result.messageText = error == nil ? "DirectMic installed" : "Installation did not complete"
            result.informativeText = error ?? "Select DirectMic as the microphone in your meeting app. If it is not listed, reopen the meeting app. Return to BotSpeaker and choose Refresh status."
            result.addButton(withTitle: "OK")
            result.runModal()
        }
        
    }
}

let app = NSApplication.shared
let delegate = InstallerDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

enum DirectMicInstaller {
    nonisolated static func install(driverPath: String) -> String? {
        // Copy to root-owned staging, then verify the exact payload before installing.
        let source = "'" + driverPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        set -eu
        destination=/Library/Audio/Plug-Ins/HAL/DirectMic.driver
        requirement='anchor apple generic and certificate leaf[subject.OU] = "52RD2GH5DP" and identifier "com.local.DirectMic.driver"'
        work=$(/usr/bin/mktemp -d /private/tmp/BotSpeaker-DirectMic.XXXXXX)
        trap '/bin/rm -rf "$work"' EXIT
        /usr/bin/ditto \(source) "$work/DirectMic.driver"
        /usr/bin/codesign --verify --deep --strict -R "=$requirement" "$work/DirectMic.driver"
        /usr/sbin/chown -R root:wheel "$work/DirectMic.driver"
        /bin/chmod -R go-w "$work/DirectMic.driver"
        /bin/mkdir -p /Library/Audio/Plug-Ins/HAL
        if [ -L "$destination" ]; then
            echo 'Refusing to replace a symbolic link at the DirectMic installation path.' >&2
            exit 1
        fi
        if [ -e "$destination" ]; then
            /usr/bin/codesign --verify --deep --strict -R "=$requirement" "$destination"
            /bin/mv "$destination" "$work/previous.driver"
        fi
        if ! /bin/mv "$work/DirectMic.driver" "$destination"; then
            if [ -d "$work/previous.driver" ]; then /bin/mv "$work/previous.driver" "$destination"; fi
            exit 1
        fi
        /usr/bin/killall coreaudiod || true
        """
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let output = Pipe()
        process.standardError = output
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "Installation did not complete: " + String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch { return "Could not start installation: \(error.localizedDescription)" }
    }
}
