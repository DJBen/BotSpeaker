using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using BotSpeaker;
using BotSpeaker.Cli;

static class RecallCoverage
{
    static void Check(bool value, string message) { if (!value) throw new Exception(message); Console.WriteLine("PASS " + message); }
    static async Task Reject<T>(Func<Task> action) where T : Exception
    { try { await action(); } catch (T) { return; } throw new Exception("Expected " + typeof(T).Name); }
    public static async Task Run()
    {
        await Manager();
        await Cli();
    }
    static async Task Manager()
    {
        var bot = Guid.NewGuid().ToString();
        var ready = new TaskCompletionSource<JsonObject>();
        var jobs = new Dictionary<string, string>();
        var sent = new List<string>();
        bool finish = false, fail = false;
        Task<JsonObject> Request(string action, JsonObject body)
        {
            if (action == "list") return ready.Task;
            if (action == "prepare") {
                var id = Guid.NewGuid().ToString(); jobs[id] = "prepared";
                return Task.FromResult(new JsonObject { ["job"] = new JsonObject { ["id"] = id } });
            }
            if (action == "dispatch") { var id = body["id"]!.GetValue<string>(); sent.Add(id); jobs[id] = "dispatched"; }
            if (action == "cancel") jobs[body["id"]!.GetValue<string>()] = "cancelled";
            return Task.FromResult(new JsonObject { ["jobs"] = new JsonArray(jobs.Select(pair => (JsonNode)new JsonObject {
                ["id"] = pair.Key, ["status"] = pair.Value == "dispatched" ? fail ? "failed" : finish ? "finished_dispatching" : pair.Value : pair.Value
            }).ToArray()) });
        }
        var manager = new RecallRunManager(Request);
        async Task<string> Create() => (await manager.HandleAsync("meeting-create", new() { ["turns"] = new JsonArray(
            new JsonObject { ["botId"] = bot, ["voice"] = "voice", ["text"] = "first" },
            new JsonObject { ["botId"] = bot, ["voice"] = "voice", ["text"] = "second" }) }))["meeting"]!["id"]!.GetValue<string>();
        string State(string id) => manager.Snapshots().Single(node => node!["id"]!.GetValue<string>() == id)!["status"]!.GetValue<string>();
        async Task Until(Func<bool> predicate) { for (int i = 0; i < 200 && !predicate(); i++) await Task.Delay(10); Check(predicate(), "meeting reaches expected state"); }
        var id = await Create();
        await manager.HandleAsync("meeting-start", new() { ["id"] = id });
        Check(manager.HasActiveRuns && State(id) == "starting", "readiness checks count as active work");
        await Reject<AppException>(() => manager.HandleAsync("meeting-start", new() { ["id"] = id }));
        await manager.HandleAsync("meeting-stop", new() { ["id"] = id });
        Check(!manager.HasActiveRuns && State(id) == "stopped" && jobs.Count == 0, "stop cancels startup before synthesis");
        ready.SetResult(new() { ["bots"] = new JsonArray(new JsonObject { ["id"] = bot, ["status"] = "in_call_recording" }) });
        await manager.HandleAsync("meeting-start", new() { ["id"] = id });
        await Until(() => State(id) == "running");
        var second = await Create();
        await Reject<AppException>(() => manager.HandleAsync("meeting-start", new() { ["id"] = second }));
        Check(jobs.Count == 2 && sent.Count == 1, "plan prepares every turn and dispatches one at a time");
        await manager.HandleAsync("meeting-skip", new() { ["id"] = id });
        await Until(() => sent.Count == 2);
        Check(jobs[sent[0]] == "cancelled", "CLI skip cancels current turn");
        await manager.StopForBotsAsync([bot]);
        Check(State(id) == "stopped" && jobs.Values.All(s => s == "cancelled"), "removing a speaker stops plan and releases prepared jobs");
        finish = true;
        await manager.HandleAsync("meeting-start", new() { ["id"] = second });
        await Until(() => State(second) == "finished");
        fail = true;
        await manager.HandleAsync("meeting-start", new() { ["id"] = second });
        await Until(() => State(second) == "failed");
        await manager.StopAllAsync();
        Check(!manager.HasActiveRuns, "shutdown waits for plan cleanup");
        await Reject<AppException>(() => manager.HandleAsync("meeting-create", new() { ["turns"] = new JsonArray() }));
        await Reject<AppException>(() => manager.HandleAsync("meeting-status", new() { ["id"] = "unknown" }));
    }
    static async Task Cli()
    {
        await Reject<TimeoutException>(() => RecallCommands.WaitAsync("j", false, false, .02,
            (_, _) => new TaskCompletionSource<JsonObject>().Task));
        foreach (var state in new[] { "failed", "cancelled", "stopped" })
            await Reject<InvalidOperationException>(() => RecallCommands.WaitAsync("j", false, false, 1,
                (_, _) => Task.FromResult(new JsonObject { ["jobs"] = new JsonArray(new JsonObject { ["id"] = "j", ["status"] = state }) })));
        var exe = Environment.GetEnvironmentVariable("BOTSPEAKER_TEST_CLI") ?? Path.GetFullPath("Windows/BotSpeakerCli/bin/Debug/net10.0/botspeaker-cli.exe");
        Check(File.Exists(exe), "real CLI executable exists (build Windows/BotSpeakerCli first)");
        var sandbox = Path.Combine(Path.GetTempPath(), "recall-cli-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sandbox);
        using var reserve = new TcpListener(IPAddress.Loopback, 0);
        reserve.Start(); var port = ((IPEndPoint)reserve.LocalEndpoint).Port; reserve.Stop();
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/"); listener.Start();
        var discovery = Path.Combine(sandbox, "control.json");
        await File.WriteAllTextAsync(discovery, new JsonObject { ["url"] = $"http://127.0.0.1:{port}", ["token"] = "fixture-token", ["pid"] = Environment.ProcessId }.ToJsonString());
        var requests = new List<(string Path, JsonObject Body)>();
        JsonObject reply = new() { ["ok"] = true };
        var server = Serve();
        async Task Serve()
        {
            try { while (listener.IsListening) {
                var context = await listener.GetContextAsync();
                Check(context.Request.Headers["Authorization"] == "Bearer fixture-token", "CLI authenticates request");
                var body = await new StreamReader(context.Request.InputStream).ReadToEndAsync();
                requests.Add((context.Request.Url!.AbsolutePath, JsonNode.Parse(body)!.AsObject()));
                var bytes = Encoding.UTF8.GetBytes(reply.ToJsonString());
                context.Response.ContentType = "application/json";
                await context.Response.OutputStream.WriteAsync(bytes); context.Response.Close();
            }} catch (HttpListenerException) { } catch (ObjectDisposedException) { }
        }
        Task<int> Call(params string[] arguments) => CallInput(null, arguments);
        async Task<int> CallInput(string? input, params string[] arguments)
        {
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
            start.ArgumentList.Add("recall"); foreach (var arg in arguments) start.ArgumentList.Add(arg);
            start.Environment["BOTSPEAKER_CONTROL_FILE"] = discovery; start.Environment["BOTSPEAKER_NO_LAUNCH"] = "1";
            using var child = Process.Start(start)!;
            if (input != null) await child.StandardInput.WriteAsync(input);
            child.StandardInput.Close();
            var stdout = child.StandardOutput.ReadToEndAsync(); var stderr = child.StandardError.ReadToEndAsync();
            try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); }
            catch { if (!child.HasExited) child.Kill(); throw; }
            await stdout; await stderr; return child.ExitCode;
        }
        try
        {
            Check(await Call("add", "939 683 252 925 1", "--passcode", "fixture", "--name", "Speaker") == 0 && requests[^1].Body["passcode"]!.GetValue<string>() == "fixture", "CLI forwards Teams ID and passcode");
            var invite = Path.Combine(sandbox, "invite.txt"); await File.WriteAllTextAsync(invite, "Meeting ID: 123 456\nPasscode: abc");
            Check(await Call("add", "--file", invite) == 0 && requests[^1].Body["meetingUrl"]!.GetValue<string>().Contains("Passcode"), "CLI reads invitation files");
            Check(await CallInput("Meeting ID: 123 456\nPasscode: abc", "add", "--file", "-") == 0 && requests[^1].Body["meetingUrl"]!.GetValue<string>().Contains("Passcode"), "CLI accepts clipboard text piped through stdin");
            Check(await Call("list", "--meeting", "123") == 0 && requests[^1].Body["meetingId"]!.GetValue<string>() == "123", "CLI scopes bot listing");
            int count = requests.Count;
            Check(await Call("remove-all") == 2 && requests.Count == count, "CLI refuses unscoped bulk removal without sending a request");
            reply = new() { ["ok"] = false, ["failures"] = new JsonArray() };
            Check(await Call("remove-all", "--meeting", "123") == 1 && requests[^1].Path.EndsWith("/remove-all"), "partial bulk failures exit nonzero");
            reply = new() { ["ok"] = true, ["job"] = new JsonObject { ["id"] = "j" }, ["jobs"] = new JsonArray(new JsonObject { ["id"] = "j", ["status"] = "prepared" }) };
            Check(await Call("prepare", "bot", "hello", "--voice", "voice", "--wait") == 0 && requests[^2].Path.EndsWith("/prepare") && requests[^2].Body["at"] == null, "prepare waits without scheduling or dispatching");
            reply["jobs"]![0]!["status"] = "finished_dispatching";
            Check(await Call("speak", "bot", "hello", "--repeat", "2", "--interval", "1.5", "--wait") == 0 && requests[^2].Body["repeat"]!.GetValue<int>() == 2, "existing speech scheduling supports waits");
            Check(await Call("dispatch", "j", "--wait") == 0, "dispatch waits for completion");
            Check(await Call("wait", "j") == 0 && requests[^1].Path.EndsWith("/status"), "standalone wait polls app status");
            var plan = Path.Combine(sandbox, "plan.json"); await File.WriteAllTextAsync(plan, "{\"turns\":[{\"botId\":\"bot\",\"voice\":\"voice\",\"text\":\"hello\"}]}");
            Check(await Call("meeting-create", "--file", plan) == 0 && requests[^1].Body["turns"]!.AsArray().Count == 1, "CLI forwards JSON meeting plans");
            reply = new() { ["ok"] = true, ["meeting"] = new JsonObject { ["id"] = "m", ["status"] = "finished" } };
            Check(await Call("meeting-start", "m", "--wait") == 0 && requests[^1].Path.EndsWith("/meeting-status"), "CLI starts and waits for meeting plan");
            foreach (var action in new[] { "meeting-stop", "meeting-skip", "meeting-status" })
                Check(await Call(action, "m") == 0 && requests[^1].Path.EndsWith("/" + action), "CLI routes " + action);
            count = requests.Count;
            foreach (var args in new[] { new[] { "prepare", "bot", "hi", "--at", "+1" }, new[] { "speak", "bot", "hi", "--interval", "NaN" }, new[] { "list", "--wait" }, new[] { "speak", "bot", "hi", "--loop", "--repeat", "2" } })
                Check(await Call(args) == 2 && requests.Count == count, "invalid options fail before network request");
        }
        finally { listener.Stop(); await server; Directory.Delete(sandbox, true); }
    }
}
