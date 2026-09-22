using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Net;

namespace BotSpeaker;

/// <summary>App-owned Recall jobs survive CLI exit, but not app shutdown. All access is on the UI thread.</summary>
public sealed class RecallController
{
    private readonly AppModel model;
    private readonly CredentialStore credentials = new("recall-credentials.bin");
    private static readonly HttpClient defaultHttp = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly HttpClient http;
    private readonly RecallRunManager meetings;
    private readonly Dictionary<string, (JsonObject State, CancellationTokenSource Cancel)> jobs = [];
    private readonly List<Task> runningJobs = [];
    public bool HasPendingJobs => meetings.HasActiveRuns || runningJobs.Any(task => !task.IsCompleted);
    public async Task CancelPendingJobsAsync()
    {
        await meetings.StopAllAsync();
        foreach (var job in jobs.Values) job.Cancel.Cancel();
        await Task.WhenAll(runningJobs);
    }
    private readonly Dictionary<string, SemaphoreSlim> botLocks = [];
    private readonly Dictionary<string, TaskCompletionSource> preparedStarts = [];
    private readonly Dictionary<string, string> knownMeetingUrls = [];
    public static readonly string[] Regions = ["us-east-1", "us-west-2", "eu-central-1", "ap-northeast-1"];
    private string RegionPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BotSpeaker", "recall-region.txt");
    public string Region { get; private set; } = "us-east-1";
    public RecallController(AppModel model, HttpClient? httpClient = null)
    {
        this.model = model;
        meetings = new(HandleAsync);
        http = httpClient ?? defaultHttp;
        if (File.Exists(RegionPath) && Regions.Contains(File.ReadAllText(RegionPath).Trim())) Region = File.ReadAllText(RegionPath).Trim();
    }
    private string? Key => credentials.Read() ?? Env("RECALL_API_KEY") ?? Env("RECALL_AI_API_KEY");
    private static string? Env(string name) => new[] { Environment.GetEnvironmentVariable(name), Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User) }.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
    public bool Configured => !string.IsNullOrWhiteSpace(Key);
    public JsonObject Status() => new() { ["ok"] = true, ["configured"] = Configured, ["region"] = Region, ["jobs"] = new JsonArray(jobs.Values.Select(j => (JsonNode)j.State.DeepClone()).ToArray()), ["meetings"] = meetings.Snapshots() };
    public async Task<JsonObject> HandleAsync(string action, JsonObject body)
    {
        if (action.StartsWith("meeting-", StringComparison.Ordinal)) return await meetings.HandleAsync(action, body);
        switch (action)
        {
            case "status": return Status();
            case "configure":
                var region = body["region"]?.GetValue<string>() ?? Region;
                if (!Regions.Contains(region)) throw new AppException("Choose a supported Recall region.");
                var key = body["apiKey"]?.GetValue<string>()?.Trim();
                if (string.IsNullOrWhiteSpace(key)) key = Key;
                if (string.IsNullOrWhiteSpace(key)) throw new AppException("Enter a Recall key or set RECALL_API_KEY.");
                await SendAsync("GET", "bot/?limit=1", null, default, key, region);
                credentials.Save(key);
                Region = region;
                Directory.CreateDirectory(Path.GetDirectoryName(RegionPath)!);
                File.WriteAllText(RegionPath, region);
                return Status();
            case "list":
                var results = new JsonArray();
                string? path = "bot/?limit=100";
                while (path != null)
                {
                    var page = await SendAsync("GET", path);
                    foreach (var bot in page["results"]?.AsArray() ?? []) {
                        var summary = Summary(bot!.AsObject());
                        if (JoinUrl(bot["meeting_url"]) is string knownUrl && summary["meeting_id"]?.GetValue<string>() is string knownId)
                            knownMeetingUrls[Region + ":" + MeetingId(knownId)] = knownUrl;
                        var scope = body["meetingId"]?.GetValue<string>();
                        if (string.IsNullOrWhiteSpace(scope) || summary["meeting_id"]?.GetValue<string>() == MeetingId(scope)) results.Add(summary);
                    }
                    var next = page["next"]?.GetValue<string>();
                    if (next == null) path = null;
                    else
                    {
                        var uri = new Uri(next);
                        if (uri.Scheme != "https" || uri.Host != $"{Region}.recall.ai" || !uri.AbsolutePath.StartsWith("/api/v1/bot/")) throw new AppException("Unexpected Recall pagination URL.");
                        path = uri.PathAndQuery[8..];
                    }
                }
                return new JsonObject { ["ok"] = true, ["bots"] = results };
            case "add":
            {
                var url = await ResolveMeetingUrlAsync(Required(body, "meetingUrl"), body["passcode"]?.GetValue<string>());
                // A silent MP3 enables Recall's prerecorded clip endpoint without an audible join sound.
                using var silenceStream = typeof(RecallController).Assembly.GetManifestResourceStream("BotSpeaker.recall-silence.mp3")
                    ?? throw new InvalidOperationException("Bundled Recall audio is missing.");
                using var silenceBytes = new MemoryStream();
                silenceStream.CopyTo(silenceBytes);
                var silence = Convert.ToBase64String(silenceBytes.ToArray());
                var created = await SendAsync("POST", "bot/", new JsonObject {
                    ["meeting_url"] = url, ["bot_name"] = body["name"]?.GetValue<string>() ?? "BotSpeaker",
                    ["automatic_audio_output"] = new JsonObject { ["in_call_recording"] = new JsonObject { ["data"] = new JsonObject { ["kind"] = "mp3", ["b64_data"] = silence } } }
                });
                return new JsonObject { ["ok"] = true, ["bot"] = Summary(created) };
            }
            case "remove":
                var botId = BotId(body);
                await meetings.StopForBotsAsync([botId]);
                foreach (var job in jobs.Values.Where(j => j.State["botId"]!.GetValue<string>() == botId)) job.Cancel.Cancel();
                await SendAsync("POST", $"bot/{botId}/leave_call/", new());
                return new JsonObject { ["ok"] = true };
            case "remove-all":
                var meetingId = MeetingId(Required(body, "meetingId"));
                var listed = await HandleAsync("list", new() { ["meetingId"] = meetingId });
                var removed = new JsonArray();
                var failures = new JsonArray();
                foreach (var bot in listed["bots"]!.AsArray().Where(bot => bot?["status"]?.GetValue<string>() is not ("done" or "fatal")))
                {
                    var removeId = bot!["id"]!.GetValue<string>();
                    try { await HandleAsync("remove", new() { ["botId"] = removeId }); removed.Add(removeId); }
                    catch (Exception error) { failures.Add(new JsonObject { ["botId"] = removeId, ["error"] = error.Message }); }
                }
                return new() { ["ok"] = failures.Count == 0, ["removed"] = removed, ["failures"] = failures };
            case "cancel":
                var id = Required(body, "id");
                if (!jobs.TryGetValue(id, out var pending)) throw new AppException("Unknown Recall job.");
                pending.Cancel.Cancel();
                return Status();
            case "speak": return Schedule(body);
            case "prepare": return Schedule(body, prepareOnly: true);
            case "dispatch":
                var preparedId = Required(body, "id");
                if (!jobs.TryGetValue(preparedId, out var prepared) || prepared.Cancel.IsCancellationRequested
                    || prepared.State["status"]?.GetValue<string>() != "prepared"
                    || !preparedStarts.TryGetValue(preparedId, out var start))
                    throw new AppException("Speech is not ready to dispatch.");
                prepared.State["status"] = "queued";
                prepared.State["held"] = false;
                start.TrySetResult();
                return new JsonObject { ["ok"] = true, ["job"] = prepared.State.DeepClone() };
            default: throw new AppException("Unknown Recall action.");
        }
    }
    private JsonObject Schedule(JsonObject body, bool prepareOnly = false)
    {
        if (!Configured) throw new AppException("Configure Recall first.");
        if (prepareOnly && body["at"] is not null)
            throw new AppException("Prepared speech is held until dispatch; omit at.");
        var botId = BotId(body);
        var text = Required(body, "text");
        var at = ParseTime(body["at"]?.GetValue<string>() ?? "now");
        bool loop = body["loop"]?.GetValue<bool>() ?? false;
        int repeat = body["repeat"]?.GetValue<int>() ?? 1;
        double interval = body["interval"]?.GetValue<double>() ?? 0;
        if (repeat < 1 || (loop && body["repeat"] != null) || !double.IsFinite(interval) || interval < 0 || interval > 86400) throw new AppException("Use --loop or --repeat N, and a nonnegative interval of at most 86400 seconds.");
        var id = Guid.NewGuid().ToString();
        var state = new JsonObject { ["id"] = id, ["botId"] = botId, ["text"] = text, ["at"] = at.ToString("O"), ["status"] = "preparing", ["sequence"] = jobs.Count, ["dispatched"] = 0, ["loop"] = loop };
        var cancel = new CancellationTokenSource();
        jobs.Add(id, (state, cancel));
        Task? start = null;
        if (prepareOnly)
        {
            var signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            preparedStarts.Add(id, signal);
            start = signal.Task;
            state["held"] = true;
        }
        runningJobs.RemoveAll(task => task.IsCompleted);
        runningJobs.Add(RunAsync(state, cancel.Token, body["voice"]?.GetValue<string>() ?? model.VoiceId, loop ? null : repeat, interval, at, Key!, Region, start));
        return new JsonObject { ["ok"] = true, ["job"] = state.DeepClone() };
    }
    public static DateTimeOffset ParseTime(string value)
    {
        var now = DateTimeOffset.UtcNow;
        if (value == "now" || string.IsNullOrWhiteSpace(value)) return now;
        if (value.StartsWith('+') && double.TryParse(value[1..], NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds) && seconds >= 0 && seconds <= 86400 * 30) return now.AddSeconds(seconds);
        if ((value.EndsWith('Z') || System.Text.RegularExpressions.Regex.IsMatch(value, @"[+-]\d{2}:\d{2}$")) && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) && date > now && date < now.AddDays(30)) return date;
        throw new AppException("Use now, +SECONDS, or a future ISO 8601 timestamp with timezone (within 30 days).");
    }
    private async Task RunAsync(JsonObject state, CancellationToken token, string voice, int? repeat, double gap, DateTimeOffset at, string recallKey, string recallRegion, Task? start)
    {
        SemaphoreSlim? gate = null;
        bool acquired = false;
        try
        {
            var key = new CredentialStore().Read() ?? throw new AppException("Configure ElevenLabs first.");
            var clip = await new ElevenLabsClient().SynthesizeAsync(state["text"]!.GetValue<string>(), voice, model.ModelId, key, "recall", false, token);
            var data = Convert.ToBase64String(await File.ReadAllBytesAsync(clip.AudioPath, token));
            if (data.Length > 1835008) throw new AppException("Recall clips must be shorter than about 85 seconds. Split this speech into shorter jobs.");
            double duration;
            using (var reader = new NAudio.Wave.Mp3FileReader(clip.AudioPath)) duration = reader.TotalTime.TotalSeconds;
            state["durationSeconds"] = duration;
            if (start is not null)
            {
                state["status"] = "prepared";
                await start.WaitAsync(token);
                at = DateTimeOffset.UtcNow;
                state["at"] = at.ToString("O");
            }
            state["status"] = "scheduled";
            if (at > DateTimeOffset.UtcNow) await Task.Delay(at - DateTimeOffset.UtcNow, token);
            var bot = state["botId"]!.GetValue<string>();
            if (!botLocks.TryGetValue(bot, out gate)) botLocks[bot] = gate = new(1);
            state["status"] = "queued";
            // Preserve due-time order even when a later job finishes synthesis first.
            while (jobs.Values.Any(j => j.State != state && j.State["botId"]!.GetValue<string>() == bot
                && j.State["held"]?.GetValue<bool>() != true
                && !new[] { "failed", "cancelled", "finished_dispatching" }.Contains(j.State["status"]!.GetValue<string>())
                && (DateTimeOffset.Parse(j.State["at"]!.GetValue<string>(), CultureInfo.InvariantCulture) < at
                    || (DateTimeOffset.Parse(j.State["at"]!.GetValue<string>(), CultureInfo.InvariantCulture) == at && j.State["sequence"]!.GetValue<int>() < state["sequence"]!.GetValue<int>()))))
                await Task.Delay(100, token);
            await gate.WaitAsync(token); acquired = true;
            for (int pass = 0; repeat == null || pass < repeat; pass++)
            {
                token.ThrowIfCancellationRequested();
                state["status"] = "dispatching";
                state["dispatchStartedAt"] = DateTimeOffset.UtcNow.ToString("O");
                await SendAsync("POST", $"bot/{bot}/output_audio/", new JsonObject { ["kind"] = "mp3", ["b64_data"] = data }, token, recallKey, recallRegion);
                var accepted = DateTimeOffset.UtcNow;
                state["acceptedAt"] = accepted.ToString("O");
                // Prepared meeting turns have no artificial pause. Keep the
                // conservative guard for standalone clip/repeat requests.
                var waitSeconds = duration + (start is null ? 2 : 0) + gap;
                state["estimatedEndAt"] = accepted.AddSeconds(waitSeconds).ToString("O");
                state["dispatched"] = pass + 1;
                state["status"] = "dispatched";
                await Task.Delay(TimeSpan.FromSeconds(waitSeconds), token);
            }
            state["status"] = "finished_dispatching";
        }
        catch (OperationCanceledException) { state["status"] = "cancelled"; }
        catch (Exception error) { state["status"] = "failed"; state["error"] = error.Message; }
        finally
        {
            preparedStarts.Remove(state["id"]!.GetValue<string>());
            if (acquired) gate!.Release();
        }
    }
    internal static (string Meeting, string Passcode) ParseMeetingInput(string value)
    {
        var text = WebUtility.HtmlDecode(value).Trim();
        // Only extract Teams join links, never download/help/options links in an invitation.
        var link = Regex.Match(text, @"https://teams\.(?:microsoft|live)\.com/(?:meet/|l/meetup-join/)[^\s<>""']+", RegexOptions.IgnoreCase);
        if (link.Success) return (link.Value, "");
        var id = Regex.Match(text, @"\bMeeting\s+ID\s*:\s*([0-9](?:[0-9\s]*[0-9])?)", RegexOptions.IgnoreCase);
        if (!id.Success) return (text, "");
        var passcode = Regex.Match(text, @"\bPasscode\s*:\s*([^\s<>]+)", RegexOptions.IgnoreCase);
        return (MeetingId(id.Groups[1].Value), passcode.Success ? passcode.Groups[1].Value : "");
    }

    public async Task<string> ResolveMeetingUrlAsync(string value, string? passcode = null)
    {
        var parsed = ParseMeetingInput(value);
        value = parsed.Meeting;
        passcode = string.IsNullOrWhiteSpace(passcode) ? parsed.Passcode : passcode.Trim();
        if (value.Length == 0) throw new AppException("Enter a meeting invite link or a previously used meeting ID.");
        if (Uri.TryCreate(value, UriKind.Absolute, out var url) && url.Scheme == "https") return value;
        if (value.Contains("://")) throw new AppException("Use an HTTPS meeting invite link.");

        if (!string.IsNullOrEmpty(passcode))
        {
            var id = MeetingId(value);
            if (!id.All(char.IsAsciiDigit)) throw new AppException("Enter a numeric Teams meeting ID with the passcode, or paste the full invitation.");
            return $"https://teams.microsoft.com/meet/{id}?p={Uri.EscapeDataString(passcode)}";
        }

        // Refresh metadata, including completed bots, to recover join credentials without guessing.
        await HandleAsync("list", new());
        if (knownMeetingUrls.TryGetValue(Region + ":" + MeetingId(value), out var resolved)) return resolved;
        throw new AppException("Enter the Teams passcode for this meeting ID, or paste the full invitation or join link.");
    }

    internal static string? JoinUrl(JsonNode? value)
    {
        if (value is JsonValue raw && raw.TryGetValue<string>(out var link))
            return Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme == "https" ? link : null;
        if (value is not JsonObject meeting) return null;
        string? Get(string key) => meeting[key]?.GetValue<string>();
        var platform = Get("platform");
        var id = Get("business_meeting_id") ?? Get("meeting_id");
        var password = Get("business_meeting_password") ?? Get("meeting_password");
        var query = string.IsNullOrEmpty(password) ? "" : "?p=" + Uri.EscapeDataString(password);
        if (platform is "microsoft_teams_live" or "microsoft_teams" && !string.IsNullOrEmpty(id) && id.All(char.IsAsciiDigit))
            return $"https://{(platform == "microsoft_teams_live" ? "teams.live.com" : "teams.microsoft.com")}/meet/{id}{query}";
        if (platform == "microsoft_teams" && Get("thread_id") is string thread && Get("message_id") is string message
            && Get("tenant_id") is string tenant && Get("organizer_id") is string organizer)
        {
            var context = new JsonObject { ["Tid"] = tenant, ["Oid"] = organizer }.ToJsonString();
            return $"https://teams.microsoft.com/l/meetup-join/{Uri.EscapeDataString(thread)}/{Uri.EscapeDataString(message)}?context={Uri.EscapeDataString(context)}";
        }
        if (platform == "google_meet" && !string.IsNullOrEmpty(id)) return "https://meet.google.com/" + Uri.EscapeDataString(id);
        if (platform == "zoom" && !string.IsNullOrEmpty(id)) return "https://zoom.us/j/" + Uri.EscapeDataString(id) + (string.IsNullOrEmpty(password) ? "" : "?pwd=" + Uri.EscapeDataString(password));
        return null;
    }
    public static string MeetingId(string value)
    {
        value = value.Trim();
        if (!Uri.TryCreate(value, UriKind.Absolute, out var url) || url.Scheme != "https") return string.Concat(value.Where(c => !char.IsWhiteSpace(c)));
        var parts = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (int i = 0; i < parts.Length - 1; i++)
            if (parts[i] is "meet" or "meetup-join" or "j" or "wc") return Uri.UnescapeDataString(parts[i + 1]);
        return Uri.UnescapeDataString(parts.LastOrDefault() ?? "");
    }
    private static JsonObject Summary(JsonObject bot) => new() {
        ["id"] = bot["id"]?.DeepClone(), ["bot_name"] = bot["bot_name"]?.DeepClone(),
        ["status"] = bot["status_changes"]?.AsArray().LastOrDefault()?["code"]?.DeepClone() ?? JsonValue.Create("unknown"),
        ["platform"] = (bot["meeting_url"] as JsonObject)?["platform"]?.DeepClone(),
        ["meeting_id"] = (bot["meeting_url"] as JsonObject)?["meeting_id"]?.DeepClone() ?? (bot["meeting_url"] as JsonObject)?["business_meeting_id"]?.DeepClone() ?? (bot["meeting_url"] as JsonObject)?["thread_id"]?.DeepClone() ?? (bot["meeting_url"] is JsonValue url ? JsonValue.Create(MeetingId(url.GetValue<string>())) : null),
        ["join_at"] = bot["join_at"]?.DeepClone()
    };
    private static string Required(JsonObject body, string name) => body[name]?.GetValue<string>()?.Trim() is { Length: > 0 } value ? value : throw new AppException($"{name} is required.");
    private static string BotId(JsonObject body) => Guid.TryParse(Required(body, "botId"), out var id) ? id.ToString() : throw new AppException("Use a Recall bot UUID.");
    private async Task<JsonObject> SendAsync(string method, string path, JsonObject? body = null, CancellationToken token = default, string? key = null, string? region = null)
    {
        key ??= Key ?? throw new AppException("Enter a Recall API key or set RECALL_API_KEY.");
        using var request = new HttpRequestMessage(new HttpMethod(method), $"https://{region ?? Region}.recall.ai/api/v1/{path}");
        request.Headers.Add("Authorization", "Token " + key);
        if (body != null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, token);
        if (!response.IsSuccessStatusCode) throw new AppException($"Recall returned HTTP {(int)response.StatusCode}. Check the key, region, bot status, and account limits.");
        var content = await response.Content.ReadAsStringAsync(token);
        return string.IsNullOrWhiteSpace(content) ? new() : JsonNode.Parse(content)?.AsObject() ?? new();
    }
}
