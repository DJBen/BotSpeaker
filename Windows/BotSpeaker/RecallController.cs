using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Globalization;

namespace BotSpeaker;

/// <summary>App-owned Recall jobs survive CLI exit, but not app shutdown. All access is on the UI thread.</summary>
public sealed class RecallController
{
    private readonly AppModel model;
    private readonly CredentialStore credentials = new("recall-credentials.bin");
    private static readonly HttpClient defaultHttp = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly HttpClient http;
    private readonly Dictionary<string, (JsonObject State, CancellationTokenSource Cancel)> jobs = [];
    private readonly Dictionary<string, SemaphoreSlim> botLocks = [];
    private readonly Dictionary<string, string> knownMeetingUrls = [];
    public static readonly string[] Regions = ["us-east-1", "us-west-2", "eu-central-1", "ap-northeast-1"];
    private string RegionPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BotSpeaker", "recall-region.txt");
    public string Region { get; private set; } = "us-east-1";
    public RecallController(AppModel model, HttpClient? httpClient = null)
    {
        this.model = model;
        http = httpClient ?? defaultHttp;
        if (File.Exists(RegionPath) && Regions.Contains(File.ReadAllText(RegionPath).Trim())) Region = File.ReadAllText(RegionPath).Trim();
    }
    private string? Key => credentials.Read() ?? Env("RECALL_API_KEY") ?? Env("RECALL_AI_API_KEY");
    private static string? Env(string name) => new[] { Environment.GetEnvironmentVariable(name), Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User) }.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
    public bool Configured => !string.IsNullOrWhiteSpace(Key);
    public JsonObject Status() => new() { ["ok"] = true, ["configured"] = Configured, ["region"] = Region, ["jobs"] = new JsonArray(jobs.Values.Select(j => (JsonNode)j.State.DeepClone()).ToArray()) };
    public async Task<JsonObject> HandleAsync(string action, JsonObject body)
    {
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
                var url = Required(body, "meetingUrl");
                if (!Uri.TryCreate(url, UriKind.Absolute, out var meeting) || meeting.Scheme != "https")
                {
                    var requestedMeetingId = MeetingId(url);
                    // Refresh metadata, including completed bots, to recover join credentials without guessing.
                    await HandleAsync("list", new());
                    if (!knownMeetingUrls.TryGetValue(Region + ":" + requestedMeetingId, out var resolved))
                        throw new AppException("No saved join details were found for this meeting ID. Use Change meeting to paste its invite link once; the link includes any required passcode.");
                    url = resolved;
                }
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
                foreach (var job in jobs.Values.Where(j => j.State["botId"]!.GetValue<string>() == botId)) job.Cancel.Cancel();
                await SendAsync("POST", $"bot/{botId}/leave_call/", new());
                return new JsonObject { ["ok"] = true };
            case "cancel":
                var id = Required(body, "id");
                if (!jobs.TryGetValue(id, out var pending)) throw new AppException("Unknown Recall job.");
                pending.Cancel.Cancel();
                return Status();
            case "speak": return Schedule(body);
            default: throw new AppException("Unknown Recall action.");
        }
    }
    private JsonObject Schedule(JsonObject body)
    {
        if (!Configured) throw new AppException("Configure Recall first.");
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
        _ = RunAsync(state, cancel.Token, body["voice"]?.GetValue<string>() ?? model.VoiceId, loop ? null : repeat, interval, at, Key!, Region);
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
    private async Task RunAsync(JsonObject state, CancellationToken token, string voice, int? repeat, double gap, DateTimeOffset at, string recallKey, string recallRegion)
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
            state["status"] = "scheduled";
            if (at > DateTimeOffset.UtcNow) await Task.Delay(at - DateTimeOffset.UtcNow, token);
            var bot = state["botId"]!.GetValue<string>();
            if (!botLocks.TryGetValue(bot, out gate)) botLocks[bot] = gate = new(1);
            state["status"] = "queued";
            // Preserve due-time order even when a later job finishes synthesis first.
            while (jobs.Values.Any(j => j.State != state && j.State["botId"]!.GetValue<string>() == bot
                && !new[] { "failed", "cancelled", "finished_dispatching" }.Contains(j.State["status"]!.GetValue<string>())
                && (DateTimeOffset.Parse(j.State["at"]!.GetValue<string>(), CultureInfo.InvariantCulture) < at
                    || (DateTimeOffset.Parse(j.State["at"]!.GetValue<string>(), CultureInfo.InvariantCulture) == at && j.State["sequence"]!.GetValue<int>() < state["sequence"]!.GetValue<int>()))))
                await Task.Delay(100, token);
            await gate.WaitAsync(token); acquired = true;
            for (int pass = 0; repeat == null || pass < repeat; pass++)
            {
                token.ThrowIfCancellationRequested();
                state["status"] = "dispatching";
                await SendAsync("POST", $"bot/{bot}/output_audio/", new JsonObject { ["kind"] = "mp3", ["b64_data"] = data }, token, recallKey, recallRegion);
                state["dispatched"] = pass + 1;
                state["status"] = "dispatched";
                await Task.Delay(TimeSpan.FromSeconds(duration + 2 + gap), token);
            }
            state["status"] = "finished_dispatching";
        }
        catch (OperationCanceledException) { state["status"] = "cancelled"; }
        catch (Exception error) { state["status"] = "failed"; state["error"] = error.Message; }
        finally { if (acquired) gate!.Release(); }
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
