using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BotSpeaker.Cli;

/// <summary>
/// Locates the running BotSpeaker app through its discovery file and talks to
/// its loopback control API — the Windows counterpart of the macOS CLI's
/// ControlClient.
/// </summary>
public sealed class ControlClient
{
    public sealed record Discovery(string Url, int Port, string Token, int Pid, string Version, string? Exe);

    /// <summary>Where the CLI remembers the last app it talked to, so it can relaunch it.</summary>
    private static string MemoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BotSpeaker", "cli.json");

    public sealed class Failure(int exitCode, string code, string message) : Exception(message)
    {
        public int ExitCode { get; } = exitCode;
        public string Code { get; } = code;
    }

    public Uri BaseUrl { get; }
    public string Token { get; }
    public Discovery? Found { get; }

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromHours(1) };
    private static readonly TimeSpan LaunchTimeout = TimeSpan.FromSeconds(20);

    private ControlClient(Uri baseUrl, string token, Discovery? found)
    {
        BaseUrl = baseUrl;
        Token = token;
        Found = found;
    }

    public static IEnumerable<string> DiscoveryCandidates
    {
        get
        {
            var overridePath = Environment.GetEnvironmentVariable("BOTSPEAKER_CONTROL_FILE");
            if (!string.IsNullOrEmpty(overridePath)) yield return overridePath;
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BotSpeaker", "control.json");
        }
    }

    /// <summary>Returns a client for a live app instance, or null (plus any stale pid seen).</summary>
    public static (ControlClient? Client, int? StalePid) FindRunning()
    {
        int? stalePid = null;
        foreach (var candidate in DiscoveryCandidates)
        {
            Discovery? discovery;
            try
            {
                if (!File.Exists(candidate)) continue;
                var node = JsonNode.Parse(File.ReadAllText(candidate)) as JsonObject;
                if (node is null) continue;
                discovery = new Discovery(
                    node["url"]?.GetValue<string>() ?? "",
                    node["port"]?.GetValue<int>() ?? 0,
                    node["token"]?.GetValue<string>() ?? "",
                    node["pid"]?.GetValue<int>() ?? 0,
                    node["version"]?.GetValue<string>() ?? "",
                    node["exe"]?.GetValue<string>());
            }
            catch (Exception)
            {
                continue;
            }
            if (discovery.Url.Length == 0 || discovery.Token.Length == 0) continue;
            if (!IsProcessAlive(discovery.Pid))
            {
                stalePid = discovery.Pid;
                continue;
            }
            RememberApp(discovery.Exe);
            return (new ControlClient(new Uri(discovery.Url), discovery.Token, discovery), null);
        }
        return (null, stalePid);
    }

    private static void RememberApp(string? exe)
    {
        if (string.IsNullOrEmpty(exe) || RememberedApp() == exe) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(MemoryPath)!);
            File.WriteAllText(MemoryPath, new JsonObject { ["lastApp"] = exe }.ToJsonString());
        }
        catch (Exception)
        {
            // Purely a convenience; launching falls back to the fixed candidates.
        }
    }

    private static string? RememberedApp()
    {
        try
        {
            if (!File.Exists(MemoryPath)) return null;
            return (JsonNode.Parse(File.ReadAllText(MemoryPath)) as JsonObject)?["lastApp"]?.GetValue<string>();
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static bool IsProcessAlive(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    /// Finds the running app, launching it in the background first when it is
    /// not running. Set BOTSPEAKER_NO_LAUNCH=1 to fail instead of launching,
    /// and BOTSPEAKER_APP=C:\path\to\BotSpeaker.exe to launch a specific copy.
    /// </summary>
    public static async Task<ControlClient> LocateAsync()
    {
        var url = Environment.GetEnvironmentVariable("BOTSPEAKER_CONTROL_URL");
        var token = Environment.GetEnvironmentVariable("BOTSPEAKER_TOKEN");
        if (!string.IsNullOrEmpty(url) && !string.IsNullOrEmpty(token))
        {
            return new ControlClient(new Uri(url), token, null);
        }
        var found = FindRunning();
        var noLaunch = Environment.GetEnvironmentVariable("BOTSPEAKER_NO_LAUNCH");
        bool mayLaunch = string.IsNullOrEmpty(noLaunch) || noLaunch == "0";
        if (found.Client is null && mayLaunch)
        {
            LaunchApp();
            var deadline = DateTime.UtcNow + LaunchTimeout;
            while (found.Client is null && DateTime.UtcNow < deadline)
            {
                await Task.Delay(250);
                found = FindRunning();
            }
            if (found.Client is null)
            {
                throw new Failure(2, "app_unreachable",
                    $"Launched BotSpeaker but it did not publish a control file within {(int)LaunchTimeout.TotalSeconds} seconds. "
                    + "Check that the installed app is 0.4.1 or newer (a build that has the control API), or point BOTSPEAKER_APP at the right BotSpeaker.exe.");
            }
        }
        if (found.Client is ControlClient client)
        {
            client.WarnIfAppIsNewer();
            return client;
        }
        var detail = found.StalePid is int stale
            ? $"the last control.json belongs to pid {stale}, which has exited"
            : "no control.json found";
        throw new Failure(2, "app_unreachable",
            $"BotSpeaker is not running ({detail}). Launch the BotSpeaker app, then retry. Looked in: {string.Join(", ", DiscoveryCandidates)}");
    }

    /// <summary>
    /// Candidate app locations, most specific first: BOTSPEAKER_APP, the app
    /// this CLI last talked to, a BotSpeaker.exe beside this CLI, the standard
    /// install location, and a Desktop copy (how the portable zip is usually
    /// run).
    /// </summary>
    public static IEnumerable<string> AppCandidates
    {
        get
        {
            var explicitPath = Environment.GetEnvironmentVariable("BOTSPEAKER_APP");
            if (!string.IsNullOrEmpty(explicitPath)) yield return explicitPath;
            if (RememberedApp() is string remembered) yield return remembered;
            yield return Path.Combine(AppContext.BaseDirectory, "BotSpeaker.exe");
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "BotSpeaker", "BotSpeaker.exe");
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "BotSpeaker.exe");
        }
    }

    private static void LaunchApp()
    {
        var exe = AppCandidates.FirstOrDefault(File.Exists)
            ?? throw new Failure(2, "app_launch_failed",
                "BotSpeaker.exe was not found. Start the BotSpeaker app once by hand (the CLI remembers where it is), "
                + "put it beside this CLI, or set BOTSPEAKER_APP to its path. Looked in: "
                + string.Join(", ", AppCandidates));
        try
        {
            var info = new ProcessStartInfo(exe, "--background")
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(exe) ?? "",
            };
            Process.Start(info);
        }
        catch (Exception error)
        {
            throw new Failure(2, "app_launch_failed", $"Could not launch {exe}: {error.Message}");
        }
    }

    /// <summary>
    /// Nudges the user to upgrade when the app is newer than this binary.
    /// Printed to stderr so JSON output on stdout stays clean. Set
    /// BOTSPEAKER_NO_UPGRADE_HINT=1 to silence it.
    /// </summary>
    private void WarnIfAppIsNewer()
    {
        if (Found is null || Environment.GetEnvironmentVariable("BOTSPEAKER_NO_UPGRADE_HINT") is not null) return;
        if (Version.TryParse(Found.Version, out var app) && Version.TryParse(CliVersion.Current, out var cli) && cli < app)
        {
            Console.Error.WriteLine($"note: BotSpeaker app is {Found.Version} but this CLI is {CliVersion.Current}. Rebuild or reinstall the CLI from the matching release.");
        }
    }

    public Task<JsonObject> GetAsync(string path, Dictionary<string, string>? query = null) =>
        SendAsync(HttpMethod.Get, path, query, null);

    public Task<JsonObject> PostAsync(string path, JsonObject? body = null) =>
        SendAsync(HttpMethod.Post, path, null, body ?? []);

    private async Task<JsonObject> SendAsync(HttpMethod method, string path, Dictionary<string, string>? query, JsonObject? body)
    {
        var builder = new UriBuilder(BaseUrl) { Path = path };
        if (query is { Count: > 0 })
        {
            builder.Query = string.Join("&", query.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        }
        using var request = new HttpRequestMessage(method, builder.Uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
        if (body is not null)
        {
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        }

        HttpResponseMessage response;
        string text;
        try
        {
            response = await Http.SendAsync(request);
            text = await response.Content.ReadAsStringAsync();
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            throw new Failure(2, "app_unreachable", $"Could not reach BotSpeaker at {BaseUrl}: {error.Message} Is the app running?");
        }
        int status = (int)response.StatusCode;
        JsonObject payload;
        try { payload = JsonNode.Parse(text) as JsonObject ?? []; }
        catch (JsonException) { payload = []; }
        if (status == 401)
        {
            throw new Failure(2, "unauthorized", "BotSpeaker rejected the control token. Restart the app or clear BOTSPEAKER_TOKEN.");
        }
        bool notOk = payload["ok"] is JsonValue okValue && okValue.TryGetValue<bool>(out var ok) && !ok;
        if ((status >= 400 || notOk) && payload["error"] is JsonObject errorBody)
        {
            throw new Failure(1,
                errorBody["code"]?.GetValue<string>() ?? "error",
                errorBody["message"]?.GetValue<string>() ?? $"Request failed with HTTP {status}.");
        }
        if (status >= 400)
        {
            throw new Failure(1, $"http_{status}", $"Request failed with HTTP {status}.");
        }
        return payload;
    }
}

public static class CliVersion
{
    public static string Current =>
        typeof(CliVersion).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
            .FirstOrDefault()?.InformationalVersion.Split('+')[0]
        ?? typeof(CliVersion).Assembly.GetName().Version?.ToString(3)
        ?? "0.0.0";
}
