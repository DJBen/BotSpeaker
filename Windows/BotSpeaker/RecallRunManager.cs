using System.Text.Json.Nodes;

namespace BotSpeaker;

/// <summary>App-owned CLI meeting plans; navigation and CLI exit do not interrupt a run.</summary>
public sealed class RecallRunManager(Func<string, JsonObject, Task<JsonObject>> request)
{
    private sealed class Run(RecallMeetingTurn[] turns)
    {
        public readonly RecallMeetingTurn[] Turns = turns;
        public readonly string Id = Guid.NewGuid().ToString();
        public string Status = "created";
        public string? Error;
        public int Index = -1;
        public bool Skip;
        public CancellationTokenSource? Cancellation;
        public Task? Task;
        public JsonObject Snapshot() => new() { ["id"] = Id, ["status"] = Status,
            ["turnIndex"] = Index, ["turnCount"] = Turns.Length, ["error"] = Error };
    }
    private readonly Dictionary<string, Run> runs = [];
    public bool HasActiveRuns => runs.Values.Any(run => run.Task is { IsCompleted: false });
    public JsonArray Snapshots() => new(runs.Values.Select(run => (JsonNode)run.Snapshot()).ToArray());
    public async Task StopAllAsync()
    {
        foreach (var run in runs.Values) run.Cancellation?.Cancel();
        await Task.WhenAll(runs.Values.Select(run => run.Task ?? Task.CompletedTask));
    }
    public async Task StopForBotsAsync(HashSet<string> bots)
    {
        var affected = runs.Values.Where(run => run.Turns.Any(turn => bots.Contains(turn.BotId))).ToArray();
        foreach (var run in affected) run.Cancellation?.Cancel();
        await Task.WhenAll(affected.Select(run => run.Task ?? Task.CompletedTask));
    }
    public async Task<JsonObject> HandleAsync(string action, JsonObject body)
    {
        if (action == "meeting-create")
        {
            var items = body["turns"] as JsonArray ?? throw new AppException("Provide a JSON plan with a turns array.");
            if (items.Count is < 1 or > 450) throw new AppException("Provide between 1 and 450 turns.");
            var turns = items.Select(item => {
                if (!Guid.TryParse(item?["botId"]?.GetValue<string>(), out var bot)) throw new AppException("Every turn needs a bot UUID.");
                var voice = item?["voice"]?.GetValue<string>()?.Trim();
                var text = item?["text"]?.GetValue<string>()?.Trim();
                if (string.IsNullOrEmpty(voice) || string.IsNullOrEmpty(text)) throw new AppException("Every turn needs voice and text.");
                return new RecallMeetingTurn(bot.ToString(), voice, text);
            }).ToArray();
            var created = new Run(turns);
            runs.Add(created.Id, created);
            return new() { ["ok"] = true, ["meeting"] = created.Snapshot() };
        }
        var id = body["id"]?.GetValue<string>() ?? "";
        if (!runs.TryGetValue(id, out var current)) throw new AppException("Unknown Recall meeting plan.");
        switch (action)
        {
            case "meeting-status": break;
            case "meeting-start":
                if (current.Task is { IsCompleted: false } || current.Status == "starting") throw new AppException("Meeting is already running.");
                if (runs.Values.Any(run => run.Task is { IsCompleted: false } &&
                    run.Turns.Any(turn => current.Turns.Any(other => other.BotId == turn.BotId))))
                    throw new AppException("A speaker bot is already used by another running meeting plan.");
                current.Status = "starting";
                current.Cancellation = new();
                current.Error = null; current.Index = -1; current.Skip = false;
                current.Task = ExecuteAsync(current);
                break;
            case "meeting-stop":
                current.Cancellation?.Cancel();
                if (current.Task != null) await current.Task;
                else current.Status = "stopped";
                break;
            case "meeting-skip":
                if (current.Status != "running") throw new AppException("A turn must be running to skip it.");
                current.Skip = true;
                break;
            default: throw new AppException("Unknown Recall meeting action.");
        }
        return new() { ["ok"] = true, ["meeting"] = current.Snapshot() };
    }
    private async Task ExecuteAsync(Run run)
    {
        try
        {
            var token = run.Cancellation!.Token;
            var response = await request("list", new()).WaitAsync(token);
            token.ThrowIfCancellationRequested();
            var ready = response["bots"]!.AsArray().Where(bot => bot?["status"]?.GetValue<string>() == "in_call_recording")
                .Select(bot => bot!["id"]!.GetValue<string>()).ToHashSet();
            if (run.Turns.Any(turn => !ready.Contains(turn.BotId))) throw new AppException("Every speaker bot must be in_call_recording before starting.");
            run.Status = "preparing";
            await RecallTurnRunner.RunAsync(run.Turns, request, index => {
                run.Index = index; run.Skip = false; run.Status = "running";
            }, run.Cancellation!.Token, () => run.Skip, index => run.Index = index);
            run.Status = "finished";
        }
        catch (OperationCanceledException) { run.Status = "stopped"; }
        catch (Exception error) { run.Status = "failed"; run.Error = error.Message; }
        finally { run.Cancellation?.Dispose(); run.Cancellation = null; }
    }
}
