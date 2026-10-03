using System.Text.Json.Nodes;
using BotSpeaker;
using BotSpeaker.Cli;

static class HostCoverage
{
    public static async Task Run()
    {
        var bot = Guid.NewGuid().ToString();
        var state = new Dictionary<string, string>();
        var prepared = new List<string>();
        var dispatched = new List<string>();
        bool hostFinished = false;
        Task<JsonObject> Request(string action, JsonObject body)
        {
            if (action == "list") return Task.FromResult(new JsonObject { ["bots"] = new JsonArray(new JsonObject { ["id"] = bot, ["status"] = "in_call_recording" }) });
            if (action == "prepare") {
                var id = body["text"]!.GetValue<string>(); prepared.Add(id); state[id] = "prepared";
                return Task.FromResult(new JsonObject { ["job"] = new JsonObject { ["id"] = id } });
            }
            if (action == "dispatch") {
                if (prepared.Count < 3) throw new Exception("Started before all speakers prepared");
                var id = body["id"]!.GetValue<string>(); dispatched.Add(id); state[id] = id == "self" ? "dispatched" : "finished_dispatching";
            }
            if (action == "cancel") state[body["id"]!.GetValue<string>()] = "cancelled";
            return Task.FromResult(new JsonObject { ["jobs"] = new JsonArray(state.Select(pair => (JsonNode)new JsonObject {
                ["id"] = pair.Key, ["status"] = pair.Key == "self" && hostFinished ? "finished_dispatching" : pair.Value
            }).ToArray()) });
        }
        var adapter = new TestSpeech(Request);
        var manager = new RecallRunManager(Request, _ => adapter);
        JsonObject Plan() => new() { ["turns"] = new JsonArray(
            new JsonObject { ["botId"] = bot, ["voice"] = "remote", ["text"] = "first" },
            new JsonObject { ["botId"] = "local", ["voice"] = "self-voice", ["text"] = "self" },
            new JsonObject { ["botId"] = bot, ["voice"] = "remote", ["text"] = "last" }) };
        var id = (await manager.HandleAsync("meeting-create", Plan()))["meeting"]!["id"]!.GetValue<string>();
        await manager.HandleAsync("meeting-start", new() { ["id"] = id });
        await Until(() => dispatched.Count == 2);
        await Task.Delay(60);
        Check(dispatched.SequenceEqual(new[] { "first", "self" }), "mixed run waits for actual host completion");
        hostFinished = true;
        await Until(() => !manager.HasActiveRuns);
        Check(dispatched.SequenceEqual(new[] { "first", "self", "last" }) && adapter.Disposed, "mixed turn order and adapter cleanup");
        var localLists = 0;
        Task<JsonObject> LocalRequest(string action, JsonObject body) { if (action == "list") localLists++; return Request(action, body); }
        var localManager = new RecallRunManager(LocalRequest, _ => new TestSpeech(Request));
        var localPlan = Plan(); localPlan["turns"]!.AsArray().RemoveAt(2); localPlan["turns"]!.AsArray().RemoveAt(0);
        var localId = (await localManager.HandleAsync("meeting-create", localPlan))["meeting"]!["id"]!.GetValue<string>();
        hostFinished = false;
        await localManager.HandleAsync("meeting-start", new() { ["id"] = localId });
        await Until(() => dispatched.Count == 4);
        hostFinished = true;
        await Until(() => !localManager.HasActiveRuns);
        Check(localLists == 0, "local-only CLI plan needs no Recall readiness request");
        var converted = RecallCommands.Build(new[] { "meeting-create" }, new Dictionary<string, string?> { ["file"] = "plan", ["include-host"] = null }, _ => Plan().ToJsonString()).Body;
        Check(converted["turns"]!.AsArray().Count(t => t!["botId"]!.GetValue<string>() == "local") == 3, "include-host converts every first-speaker turn");
    }
    static void Check(bool condition, string label) { if (!condition) throw new Exception(label); Console.WriteLine("PASS " + label); }
    static async Task Until(Func<bool> condition) { for (int i = 0; i < 200 && !condition(); i++) await Task.Delay(10); Check(condition(), "host run reaches expected state"); }
    sealed class TestSpeech(Func<string, JsonObject, Task<JsonObject>> request) : IRecallMeetingSpeech
    {
        public bool Disposed;
        public Task<JsonObject> HandleAsync(string action, JsonObject body) => request(action, body);
        public void Dispose() => Disposed = true;
    }
}
