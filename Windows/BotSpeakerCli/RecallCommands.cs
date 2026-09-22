using System.Globalization;
using System.Text.Json.Nodes;

namespace BotSpeaker.Cli;

public static class RecallCommands
{
    public static (string Action, JsonObject Body) Build(IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string?> options, Func<string, string> read)
    {
        var action = arguments.FirstOrDefault() ?? "status";
        string? Option(string key) => options.GetValueOrDefault(key);
        string Required(int index, string label) => arguments.ElementAtOrDefault(index) is { Length: > 0 } value
            ? value : throw new ArgumentException(label + " is required.");
        var allowed = new HashSet<string>(["json", "wait", "w", "timeout"]);
        void Allow(params string[] names) { foreach (var name in names) allowed.Add(name); }
        var body = new JsonObject();
        var maxArguments = 1;
        switch (action)
        {
            case "status": break;
            case "list": Allow("meeting"); if (Option("meeting") is string scope) body["meetingId"] = scope; break;
            case "add":
                Allow("name", "passcode", "file", "f"); maxArguments = 2;
                body["meetingUrl"] = (Option("file") ?? Option("f")) is string invite ? read(invite) : Required(1, "Meeting URL or ID");
                body["name"] = Option("name") ?? "BotSpeaker";
                if (Option("passcode") is string passcode) body["passcode"] = passcode;
                break;
            case "remove-all":
                Allow("meeting"); body["meetingId"] = Option("meeting") ?? throw new ArgumentException("--meeting is required for remove-all."); break;
            case "remove": maxArguments = 2; body["botId"] = Required(1, "Bot ID"); break;
            case "cancel": case "dispatch": case "wait":
            case "meeting-start": case "meeting-stop": case "meeting-skip": case "meeting-status": case "meeting-wait":
                maxArguments = 2; body["id"] = Required(1, "ID"); break;
            case "meeting-create":
                Allow("file", "f");
                body = JsonNode.Parse(read(Option("file") ?? Option("f") ?? throw new ArgumentException("--file is required."))) as JsonObject
                    ?? throw new ArgumentException("Meeting plan must be a JSON object.");
                break;
            case "speak": case "prepare":
                Allow("voice", "file", "f");
                if (action == "speak") Allow("at", "loop", "l", "repeat", "r", "interval");
                maxArguments = int.MaxValue;
                body["botId"] = Required(1, "Bot ID");
                body["text"] = (Option("file") ?? Option("f")) is string file ? read(file) : string.Join(" ", arguments.Skip(2));
                if (string.IsNullOrWhiteSpace(body["text"]!.GetValue<string>())) throw new ArgumentException("Speech text is required.");
                if (Option("voice") is string voice) body["voice"] = voice;
                if (action == "speak")
                {
                    bool loop = options.ContainsKey("loop") || options.ContainsKey("l");
                    var repeat = Option("repeat") ?? Option("r");
                    if (loop && repeat != null) throw new ArgumentException("Use --loop or --repeat, not both.");
                    if (repeat != null) {
                        if (!int.TryParse(repeat, out var count) || count < 1) throw new ArgumentException("--repeat must be positive.");
                        body["repeat"] = count;
                    }
                    body["loop"] = loop; body["at"] = Option("at") ?? "now";
                    if (Option("interval") is string gap) {
                        if (!double.TryParse(gap, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) || !double.IsFinite(seconds) || seconds < 0)
                            throw new ArgumentException("--interval must be finite, nonnegative seconds.");
                        body["interval"] = seconds;
                    }
                }
                break;
            default: throw new ArgumentException("Unknown Recall action. Use recall --help.");
        }
        if (arguments.Count > maxArguments) throw new ArgumentException("Unexpected positional arguments.");
        foreach (var option in options.Keys) if (!allowed.Contains(option)) throw new ArgumentException($"--{option} is not supported for recall {action}.");
        if ((options.ContainsKey("wait") || options.ContainsKey("w")) && action is not ("speak" or "prepare" or "dispatch" or "meeting-start"))
            throw new ArgumentException("--wait is supported for speak, prepare, dispatch, and meeting-start.");
        return (action, body);
    }

    public static async Task<JsonObject> WaitAsync(string id, bool meeting, bool prepared, double timeout,
        Func<string, JsonObject, Task<JsonObject>> request)
    {
        if (!double.IsFinite(timeout) || timeout <= 0) throw new ArgumentException("--timeout must be finite and positive.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        try
        {
            while (true)
            {
                var response = await request(meeting ? "meeting-status" : "status", new() { ["id"] = id }).WaitAsync(deadline.Token);
                var item = meeting ? response["meeting"] : response["jobs"]?.AsArray().FirstOrDefault(job => job?["id"]?.GetValue<string>() == id);
                if (item == null) throw new InvalidOperationException("Unknown Recall job or meeting.");
                var status = item["status"]?.GetValue<string>();
                if (status is "failed" or "cancelled" or "stopped") throw new InvalidOperationException(item["error"]?.GetValue<string>() ?? $"Recall work was {status}.");
                if (status == (meeting ? "finished" : prepared ? "prepared" : "finished_dispatching"))
                    return new() { ["ok"] = true, [meeting ? "meeting" : "job"] = item.DeepClone() };
                await Task.Delay(100, deadline.Token);
            }
        }
        catch (OperationCanceledException) { throw new TimeoutException("Timed out waiting for Recall. Work continues in the app; use cancel or meeting-stop to stop it."); }
    }
}
