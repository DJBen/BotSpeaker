using System.IO;
using System.Text.Json;
using BotSpeaker;
using Velopack;
using Velopack.Locators;

// Exercise real Velopack feed/package verification in an isolated directory.
// No installation, app restart, GitHub access, or user settings are needed.
if (args.Length != 1) throw new ArgumentException("Pass the build-only output's velopack directory.");
VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
var feedDirectory = Path.GetFullPath(args[0]);
using var feed = JsonDocument.Parse(File.ReadAllText(Path.Combine(feedDirectory, "releases.win.json")));
var asset = feed.RootElement.GetProperty("Assets").EnumerateArray()
    .Single(a => a.GetProperty("Type").GetString() == "Full");
var version = asset.GetProperty("Version").GetString()!;
var packageName = asset.GetProperty("FileName").GetString()!;
var sandbox = Path.Combine(Path.GetTempPath(), "botspeaker-update-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(sandbox);
try
{
    using (var portable = new WindowsUpdater())
    {
        Require(!portable.IsInstalled, "test executable must not be installed");
        Require((await portable.CheckAsync(true))!.Contains("installer"), "portable build explains manual migration");
    }

    using (var current = CreateUpdater(feedDirectory, version))
    {
        Require((await current.CheckAsync(true)) == "BotSpeaker is up to date.", "same-version feed has no update");
        Require(current.PendingUpdate is null && !current.IsBusy, "same-version check leaves no pending update");
    }

    using (var older = CreateUpdater(feedDirectory, "0.0.1"))
    {
        int notifications = 0;
        older.UpdateReady += _ => notifications++;
        await older.CheckAsync(false);
        Require(older.PendingUpdate?.Version.ToString() == version, "older install downloads and verifies full package");
        Require(!older.IsBusy, "download clears busy state");
        await older.CheckAsync(false);
        Require(notifications == 1, "background checks notify once per version");
        Require((await older.CheckAsync(true))!.Contains("ready"), "manual check reports downloaded update");
    }

    var brokenFeed = Path.Combine(sandbox, "broken-feed");
    Directory.CreateDirectory(brokenFeed);
    File.WriteAllText(Path.Combine(brokenFeed, "releases.win.json"), "invalid feed response");
    using (var offline = CreateUpdater(brokenFeed, "0.0.1"))
    {
        Require(await offline.CheckAsync(false) is null, "background failure is silent");
        Require(!offline.IsBusy, "failure permits retry");
        Require((await offline.CheckAsync(true))!.Contains("Could not"), "manual failure explains retry");
        Require(offline.PendingUpdate is null, "failed check cannot enable restart");
    }

    var corruptFeed = Path.Combine(sandbox, "corrupt-feed");
    Directory.CreateDirectory(corruptFeed);
    File.Copy(Path.Combine(feedDirectory, "releases.win.json"), Path.Combine(corruptFeed, "releases.win.json"));
    File.WriteAllText(Path.Combine(corruptFeed, packageName), "not a valid update package");
    using (var corrupt = CreateUpdater(corruptFeed, "0.0.1"))
    {
        Require((await corrupt.CheckAsync(true))!.Contains("Could not"), "corrupt package is rejected");
        Require(corrupt.PendingUpdate is null && !corrupt.IsBusy, "corruption never becomes installable");
    }
    Console.WriteLine("All Windows updater integration checks passed.");
}
finally
{
    Directory.Delete(sandbox, recursive: true);
}

WindowsUpdater CreateUpdater(string source, string installedVersion)
{
    var root = Path.Combine(sandbox, Guid.NewGuid().ToString("N"));
    var packages = Path.Combine(root, "packages");
    Directory.CreateDirectory(packages);
    var locator = new TestVelopackLocator("BotSpeaker.Windows", installedVersion, packages,
        appDir: root, rootDir: root, updateExe: Path.Combine(root, "Update.exe"), channel: "win");
    return new WindowsUpdater(new UpdateManager(source, locator: locator));
}

static void Require(bool condition, string message)
{
    if (!condition) throw new Exception("FAIL: " + message);
    Console.WriteLine("PASS: " + message);
}
