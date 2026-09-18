using System.IO.Compression;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace BotSpeaker.Cli;

internal static class CliUpgrade
{
    internal const string AssetName = "botspeaker-cli-windows-x64.zip";
    private const string Repository = "https://api.github.com/repos/DJBen/BotSpeaker";

    internal static async Task<JsonObject> RunAsync(bool check)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("BotSpeaker-CLI/" + CliVersion.Current);
        var release = JsonNode.Parse(await http.GetStringAsync(Repository + "/releases/latest"))!.AsObject();
        var latest = release["tag_name"]!.GetValue<string>().TrimStart('v');
        if (!Version.TryParse(latest, out var remote) || !Version.TryParse(CliVersion.Current, out var current))
            throw new InvalidDataException("Release has an unsupported version number.");
        var managed = File.Exists(Path.Combine(AppContext.BaseDirectory, "sq.version"));
        var result = new JsonObject
        {
            ["ok"] = true, ["currentVersion"] = CliVersion.Current, ["latestVersion"] = latest,
            ["updateAvailable"] = remote > current, ["path"] = Environment.ProcessPath,
            ["managed"] = managed, ["updated"] = false,
        };
        if (remote <= current) { result["message"] = "The CLI is up to date."; return result; }
        if (managed)
        {
            result["message"] = $"BotSpeaker {latest} is available. This CLI updates with the app. Use Check for Updates in the BotSpeaker tray menu, then Restart to update after playback and meetings have ended.";
            return result;
        }
        if (check) { result["message"] = $"CLI {latest} is available. Run `botspeaker-cli upgrade`."; return result; }
        var target = Environment.ProcessPath ?? throw new IOException("Cannot locate this CLI.");
        // Assembly.Location intentionally distinguishes published single-file builds.
#pragma warning disable IL3000
        if (!string.Equals(Path.GetFileName(target), "botspeaker-cli.exe", StringComparison.OrdinalIgnoreCase)
            || !string.IsNullOrEmpty(typeof(CliUpgrade).Assembly.Location))
            throw new IOException("Self-update requires the published single-file botspeaker-cli.exe. Rerun scripts/install-cli.ps1 for a development build.");
#pragma warning restore IL3000

        var assets = release["assets"]!.AsArray();
        string AssetUrl(string name)
        {
            var url = assets.SingleOrDefault(a => a?["name"]?.GetValue<string>() == name)?["browser_download_url"]?.GetValue<string>()
                ?? throw new IOException($"Release {latest} has no {name}.");
            if (!url.StartsWith("https://github.com/DJBen/BotSpeaker/releases/download/", StringComparison.Ordinal))
                throw new InvalidDataException("Unexpected release download URL.");
            return url;
        }
        var checksum = await http.GetStringAsync(AssetUrl(AssetName + ".sha256"));
        var bytes = await http.GetByteArrayAsync(AssetUrl(AssetName));
        VerifyChecksum(bytes, checksum);
        // Stage beside the target for a same-volume rename. Never extract arbitrary ZIP paths.
        var staged = target + "." + Guid.NewGuid().ToString("N") + ".new";
        var scheduled = false;
        try
        {
            using (var zip = new ZipArchive(new MemoryStream(bytes)))
            {
                var entry = zip.Entries.Single(e => e.Name.Equals("botspeaker-cli.exe", StringComparison.OrdinalIgnoreCase));
                entry.ExtractToFile(staged);
            }
            using var worker = StartReplacement(staged, target, Environment.ProcessId);
            scheduled = true;
        }
        finally { if (!scheduled && File.Exists(staged)) File.Delete(staged); }
        result["updateScheduled"] = true;
        result["message"] = $"CLI {latest} downloaded and verified. Replacement finishes after this command exits. Run `botspeaker-cli --version` to verify. Result log: {target}.update.log";
        return result;
    }

    internal static void VerifyChecksum(byte[] bytes, string checksum)
    {
        var expected = checksum.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (expected is null || expected.Length != 64 || !expected.All(Uri.IsHexDigit)
            || !Convert.ToHexString(SHA256.HashData(bytes)).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("CLI download failed SHA-256 verification; the installed CLI was not changed.");
    }

    internal static Process StartReplacement(string staged, string target, int parentPid)
    {
        // Single-file runtimes can lazily read their own bundle by pathname.
        // Wait until the CLI exits before replacing it, using an independent runtime.
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(new JsonObject
        { ["staged"] = staged, ["target"] = target, ["parent"] = parentPid }.ToJsonString()));
        var script = "$update = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + payload + "')) | ConvertFrom-Json\n" + """
            $ErrorActionPreference = 'Stop'
            $backup = $update.target + '.previous'
            $log = $update.target + '.update.log'
            try {
                $owner = $null
                try { $owner = [Diagnostics.Process]::GetProcessById($update.parent) } catch [ArgumentException] { }
                if ($owner) {
                    try { if (-not $owner.WaitForExit(30000)) { throw 'CLI did not exit within 30 seconds; retry the upgrade.' } }
                    finally { $owner.Dispose() }
                }
                if (-not [IO.File]::Exists($update.staged)) { throw 'Staged CLI is missing.' }
                if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
                [IO.File]::Move($update.target, $backup)
                try { [IO.File]::Move($update.staged, $update.target) }
                catch { [IO.File]::Move($backup, $update.target); throw }
                [IO.File]::WriteAllText($log, 'CLI update installed successfully.')
            } catch {
                [IO.File]::WriteAllText($log, 'CLI update failed: ' + $_.Exception.Message)
                exit 1
            } finally {
                try { if ([IO.File]::Exists($update.staged)) { [IO.File]::Delete($update.staged) } } catch { }
            }
            """;
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
        { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) })
            start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new IOException("Could not start the CLI update worker.");
    }
}
