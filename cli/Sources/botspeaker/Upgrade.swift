import ArgumentParser
import CommonCrypto
import Foundation

/// Replaces this binary with the CLI attached to a BotSpeaker GitHub release.
struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download the latest botspeaker CLI from GitHub Releases and replace this binary.",
        discussion: """
        The app updates itself through Sparkle, but the CLI is a separate binary. Run this after the app \
        updates (the CLI prints a reminder when the app is newer), or use --check to only look.
        """
    )

    static let repository = "DJBen/BotSpeaker"
    static let assetName = "botspeaker-cli-macos-universal.zip"

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Install a specific release tag instead of the latest (for example 0.4.0).")
    var version: String?

    @Flag(name: .long, help: "Report whether a newer CLI is available without installing it.")
    var check = false

    func run() async throws {
        do {
            let current = BotSpeakerCLIVersion.current
            let target = try await resolveTargetVersion()
            let comparison = BotSpeakerCLIVersion.compare(current, target)
            if check {
                let newer = comparison == .orderedAscending
                if global.json {
                    Output.json(["ok": true, "current": current, "latest": target, "upgradeAvailable": newer])
                } else if newer {
                    print("botspeaker \(current) installed; \(target) is available. Run `botspeaker upgrade`.")
                } else {
                    print("botspeaker \(current) is up to date (latest \(target)).")
                }
                return
            }
            if version == nil, comparison != .orderedAscending {
                if global.json {
                    Output.json(["ok": true, "current": current, "latest": target, "upgraded": false])
                } else {
                    print("botspeaker \(current) is already up to date.")
                }
                return
            }

            let installPath = try Self.installedBinaryPath()
            let binary = try await Self.downloadBinary(version: target)
            try Self.replace(at: installPath, with: binary)
            if global.json {
                Output.json(["ok": true, "previous": current, "current": target, "path": installPath, "upgraded": true])
            } else {
                print("Upgraded botspeaker \(current) -> \(target) at \(installPath)")
            }
        } catch {
            Output.fail(error, json: global.json)
        }
    }

    private func resolveTargetVersion() async throws -> String {
        if let version { return version.hasPrefix("v") ? String(version.dropFirst()) : version }
        let (data, response) = try await URLSession.shared.data(from: Self.latestReleaseAPIURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_lookup_failed",
                                        message: "Could not look up the latest release of \(Self.repository).")
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // MARK: - Download and verify

    static var downloadBase: String {
        ProcessInfo.processInfo.environment["BOTSPEAKER_CLI_DOWNLOAD_BASE"]
            ?? "https://github.com/\(repository)/releases/download"
    }

    static var latestReleaseAPIURL: URL {
        if let override = ProcessInfo.processInfo.environment["BOTSPEAKER_CLI_LATEST_URL"], let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Downloads and verifies the release zip, returning the path of the
    /// extracted `botspeaker` binary inside a temporary directory.
    static func downloadBinary(version: String) async throws -> String {
        let base = "\(downloadBase)/\(version)"
        guard let zipURL = URL(string: "\(base)/\(assetName)"),
              let sumURL = URL(string: "\(base)/\(assetName).sha256") else {
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_failed", message: "Invalid download URL for \(version).")
        }
        let zipData = try await fetch(zipURL, what: "CLI archive for \(version)")
        let sumData = try await fetch(sumURL, what: "checksum for \(version)")
        let expected = String(decoding: sumData, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let actual = sha256Hex(zipData)
        guard !expected.isEmpty, expected.lowercased() == actual else {
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_checksum_mismatch",
                                        message: "Checksum mismatch for \(assetName) (\(version)); refusing to install.")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("botspeaker-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let zipPath = workDir.appendingPathComponent(assetName)
        try zipData.write(to: zipPath)
        try run("/usr/bin/ditto", ["-xk", zipPath.path, workDir.path])
        let binary = workDir.appendingPathComponent("botspeaker").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_failed",
                                        message: "The downloaded archive did not contain a botspeaker binary.")
        }
        return binary
    }

    private static func fetch(_ url: URL, what: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_download_failed",
                                        message: "Could not download the \(what) (HTTP \(status)) from \(url.absoluteString).")
        }
        return data
    }

    // MARK: - Install

    /// The file this process is running from, with symlinks resolved.
    static func installedBinaryPath() throws -> String {
        let invoked = CommandLine.arguments[0]
        var path: String
        if invoked.contains("/") {
            path = URL(fileURLWithPath: invoked).standardizedFileURL.path
        } else {
            let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            path = directories.map { "\($0)/\(invoked)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? invoked
        }
        path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if path.contains("/.build/") {
            throw ControlClient.Failure(
                exitCode: 1, code: "upgrade_source_install",
                message: "This botspeaker was built from source (\(path)). Rebuild it with scripts/install-cli.sh --source, "
                    + "or reinstall the released CLI with scripts/install-cli.sh."
            )
        }
        return path
    }

    /// Atomically swaps the binary at `path` for `newBinary`.
    static func replace(at path: String, with newBinary: String) throws {
        let manager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        let staged = "\(path).new-\(ProcessInfo.processInfo.processIdentifier)"
        guard manager.isWritableFile(atPath: directory) else {
            throw ControlClient.Failure(
                exitCode: 1, code: "upgrade_permission_denied",
                message: "\(directory) is not writable. Re-run with sudo:\n  sudo botspeaker upgrade\n"
                    + "or reinstall to a user-owned directory with scripts/install-cli.sh --dest ~/.local/bin"
            )
        }
        try? manager.removeItem(atPath: staged)
        try manager.copyItem(atPath: newBinary, toPath: staged)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        if rename(staged, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(atPath: staged)
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_failed", message: "Could not replace \(path): \(reason)")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ControlClient.Failure(exitCode: 1, code: "upgrade_failed",
                                        message: "\(executable) failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256_Update(&context, buffer.baseAddress, CC_LONG(buffer.count))
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
