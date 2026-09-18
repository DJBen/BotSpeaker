using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using BotSpeaker;

internal static class Program
{
    [STAThread]
    static int Main()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
        int exit = 0;
        dispatcher.InvokeAsync(async () => { try { await Run(); Console.WriteLine("All Recall tests passed."); } catch (Exception e) { Console.Error.WriteLine(e); exit = 1; } finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Normal); } });
        Dispatcher.Run(); return exit;
    }
    static void Check(bool condition, string label) { if (!condition) throw new Exception(label); Console.WriteLine("PASS " + label); }
    static async Task Reject(Func<Task> action, string label) { try { await action(); } catch (AppException) { Console.WriteLine("PASS " + label); return; } throw new Exception("Expected rejection: " + label); }
    static async Task Until(Func<bool> predicate) { for (int i = 0; i < 150 && !predicate(); i++) await Task.Delay(50); if (!predicate()) throw new Exception("Timed out"); }
    static async Task Run()
    {
        var handler = new FakeHttp();
        var controller = new RecallController(new AppModel(), new HttpClient(handler));
        string bot = Guid.NewGuid().ToString();
        JsonObject Speech(string text, string at = "now") => new() { ["botId"] = bot, ["text"] = text, ["at"] = at };
        JsonObject Job(string id) => controller.Status()["jobs"]!.AsArray().Select(x => x!.AsObject()).Single(x => x["id"]!.GetValue<string>() == id);
        string Id(JsonObject response) => response["job"]!["id"]!.GetValue<string>();
        Check(!controller.Status().ToJsonString().Contains("test-secret"), "status does not disclose credentials");
        await Reject(() => controller.HandleAsync("speak", Speech("bad", "2020-01-01T00:00:00Z")), "past timestamp rejected");
        await Reject(() => controller.HandleAsync("speak", Speech("bad", "2028-01-01T12:00:00")), "timezone required");
        var invalid = Speech("bad"); invalid["loop"] = true; invalid["repeat"] = 2;
        await Reject(() => controller.HandleAsync("speak", invalid), "loop and repeat conflict rejected");
        Check((RecallController.ParseTime("+5") - DateTimeOffset.UtcNow).TotalSeconds is > 4 and <= 5, "relative dispatch timestamp");
        var list = await controller.HandleAsync("list", new());
        Check(list["bots"]!.AsArray().Count == 2, "pagination includes both pages");
        Check(RecallController.MeetingId("https://teams.live.com/meet/123456?p=secret") == "123456", "Teams meeting URL normalized without password");
        Check(RecallController.MeetingId("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0") == "19:meeting_abc@thread.v2", "Teams thread meeting ID decoded");
        Check(RecallController.MeetingId("938 075 776 919 2") == "9380757769192", "spaced meeting ID normalized");
        Check(RecallController.MeetingId("938\u00a0075\t776\n919 2") == "9380757769192", "pasted Unicode whitespace normalized");
        var scoped = await controller.HandleAsync("list", new() { ["meetingId"] = "https://teams.live.com/meet/meeting-one?p=secret" });
        Check(scoped["bots"]!.AsArray().Count == 1 && scoped["bots"]![0]!["meeting_id"]!.GetValue<string>() == "meeting-one", "meeting-scoped listing excludes other meetings");
        handler.HostileNext = true;
        await Reject(() => controller.HandleAsync("list", new()), "foreign pagination host rejected before credentials leave Recall");
        handler.HostileNext = false;
        await controller.HandleAsync("add", new() { ["meetingUrl"] = "https://teams.example.test/meeting", ["name"] = "Test" });
        Check(handler.Created?["automatic_audio_output"]?["in_call_recording"]?["data"]?["kind"]?.GetValue<string>() == "mp3", "new bots enable audio output");
        handler.MeetingData = new JsonObject { ["platform"] = "microsoft_teams_live", ["meeting_id"] = "93274648695510", ["meeting_password"] = "test pass&code" };
        await controller.HandleAsync("add", new() { ["meetingUrl"] = "932 746 486 955 10", ["name"] = "Resolved" });
        Check(handler.Created?["meeting_url"]?.GetValue<string>() == "https://teams.live.com/meet/93274648695510?p=test%20pass%26code", "add resolves spaced known ID and preserves encoded passcode");
        Check(!controller.Status().ToJsonString().Contains("test pass"), "join passcode not exposed in status");
        await Reject(() => controller.HandleAsync("add", new() { ["meetingUrl"] = "1111111111" }), "unknown ID requires invite rather than guessing");
        handler.MeetingData = null;
        var cancelled = Id(await controller.HandleAsync("speak", Speech("cancel-me", "+60")));
        await controller.HandleAsync("cancel", new() { ["id"] = cancelled });
        await Until(() => Job(cancelled)["status"]!.GetValue<string>() == "cancelled");
        Check(handler.Sent.Count == 0, "cancelled scheduled job never sent");
        var first = Id(await controller.HandleAsync("speak", Speech("slow-first")));
        var second = Id(await controller.HandleAsync("speak", Speech("fast-second")));
        await Until(() => handler.Sent.Count >= 2);
        Check(handler.Sent.SequenceEqual(new[] { "slow-first", "fast-second" }), "generation completion does not reorder due speech");
        await Until(() => Job(second)["status"]!.GetValue<string>() == "finished_dispatching");
        var repeating = Speech("repeat"); repeating["repeat"] = 2;
        var repeatId = Id(await controller.HandleAsync("speak", repeating));
        await Until(() => Job(repeatId)["status"]!.GetValue<string>() == "finished_dispatching");
        Check(handler.Sent.Count(x => x == "repeat") == 2, "finite repeats send exactly N clips");
        var looping = Speech("loop"); looping["loop"] = true;
        var loopId = Id(await controller.HandleAsync("speak", looping));
        await Until(() => handler.Sent.Contains("loop"));
        await controller.HandleAsync("cancel", new() { ["id"] = loopId });
        await Until(() => Job(loopId)["status"]!.GetValue<string>() == "cancelled");
        Check(handler.Sent.Count(x => x == "loop") == 1, "loop cancellation stops future sends");
        handler.FailAudio = true;
        var failed = Id(await controller.HandleAsync("speak", Speech("failure")));
        await Until(() => Job(failed)["status"]!.GetValue<string>() == "failed");
        Check(!Job(failed).ToJsonString().Contains("test-secret"), "API failures are reported without secret response bodies");
        var removed = Id(await controller.HandleAsync("speak", Speech("remove-me", "+60")));
        await controller.HandleAsync("remove", new() { ["botId"] = bot });
        await Until(() => Job(removed)["status"]!.GetValue<string>() == "cancelled");
        Check(handler.Left, "remove leaves call and cancels pending jobs");
        var speaker = new OrchestratedSpeakerConfiguration { Slot = 1, Role = "Product Manager", VoiceName = "Adam - Dominant, Firm" };
        Check(speaker.Name == "Adam" && speaker.CustomName == "", "unnamed speaker uses voice name without saving a custom override");
        speaker.VoiceName = "Alice — Clear and Engaging";
        Check(speaker.Name == "Alice", "default speaker name follows voice changes");
        speaker.Name = "  Taylor  "; speaker.VoiceName = "Brian - Warm";
        Check(speaker.Name == "Taylor" && speaker.CustomName == "Taylor", "user name survives voice changes and is available for per-template persistence");
        var restoredSpeaker = new OrchestratedSpeakerConfiguration { Slot = 1, Role = speaker.Role, VoiceName = speaker.VoiceName, Name = speaker.CustomName };
        Check(restoredSpeaker.Name == "Taylor", "saved custom name restores independently of voice name");
        speaker.Name = " ";
        Check(speaker.Name == "Brian" && speaker.CustomName == "", "clearing custom name restores the selected voice default");

        var sentTurns = new List<string>();
        var polls = 0;
        var currentJob = "";
        var fail = false;
        var cancellationSent = false;
        using var stopRun = new CancellationTokenSource();
        var cancelOnPoll = false;
        Task<JsonObject> MeetingRequest(string action, JsonObject body) {
            if (action == "speak") {
                Check(currentJob.Length == 0, "next speaker waits for prior clip completion");
                currentJob = Guid.NewGuid().ToString(); polls = 0;
                sentTurns.Add(body["botId"]!.GetValue<string>());
                return Task.FromResult(new JsonObject { ["job"] = new JsonObject { ["id"] = currentJob } });
            }
            if (action == "cancel") { currentJob = ""; cancellationSent = true; return Task.FromResult(new JsonObject()); }
            var id = currentJob;
            var state = fail ? "failed" : ++polls >= 3 ? "finished_dispatching" : "dispatched";
            if (state == "finished_dispatching") currentJob = "";
            if (cancelOnPoll) stopRun.Cancel();
            return Task.FromResult(new JsonObject { ["jobs"] = new JsonArray(new JsonObject { ["id"] = id, ["status"] = state }) });
        }
        RecallMeetingTurn[] plan = [new("speaker-one", "voice-one", "First"), new("speaker-two", "voice-two", "Second")];
        await RecallTurnRunner.RunAsync(plan, MeetingRequest, _ => {}, default);
        Check(sentTurns.SequenceEqual(new[] { "speaker-one", "speaker-two" }), "meeting dispatches speakers in turn order");
        sentTurns.Clear(); cancellationSent = false;
        bool skipTurn = false;
        await RecallTurnRunner.RunAsync(plan, MeetingRequest, index => skipTurn = index == 0, default, () => skipTurn);
        Check(cancellationSent && sentTurns.SequenceEqual(new[] { "speaker-one", "speaker-two" }), "skip cancels only current turn and continues with next speaker");
        sentTurns.Clear(); cancellationSent = false;
        await RecallTurnRunner.RunAsync(plan, MeetingRequest, index => skipTurn = index == 1, default, () => skipTurn);
        Check(cancellationSent && sentTurns.Count == 2, "skipping final turn finishes the run without an extra dispatch");

        sentTurns.Clear(); fail = true;
        try { await RecallTurnRunner.RunAsync(plan, MeetingRequest, _ => {}, default); throw new Exception("Expected speech failure"); }
        catch (InvalidOperationException) { Check(sentTurns.Count == 1, "speech failure prevents later turns"); }
        currentJob = ""; sentTurns.Clear(); fail = false; cancelOnPoll = true;
        try { await RecallTurnRunner.RunAsync(plan, MeetingRequest, _ => {}, stopRun.Token); throw new Exception("Expected cancellation"); }
        catch (OperationCanceledException) { Check(cancellationSent && sentTurns.Count == 1, "stopping cancels active speech and prevents later turns"); }

    }
}

sealed class FakeHttp : HttpMessageHandler
{
    public bool HostileNext, FailAudio, Left;
    public JsonObject? Created;
    public JsonObject? MeetingData;
    public List<string> Sent = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        if (request.Headers.Authorization?.Parameter != "test-secret") throw new Exception("Missing auth");
        var path = request.RequestUri!.AbsolutePath;
        if (request.Method == HttpMethod.Get)
        {
            var next = request.RequestUri.Query.Contains("cursor") ? null : HostileNext ? "https://evil.example/api/v1/bot/" : request.RequestUri.GetLeftPart(UriPartial.Authority) + "/api/v1/bot/?cursor=2";
            return Ok(new JsonObject { ["results"] = new JsonArray(new JsonObject { ["id"] = Guid.NewGuid().ToString(), ["meeting_url"] = MeetingData?.DeepClone() ?? new JsonObject { ["meeting_id"] = request.RequestUri.Query.Contains("cursor") ? "meeting-two" : "meeting-one" } }), ["next"] = next });
        }
        var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(token))!.AsObject();
        if (path.EndsWith("output_audio/"))
        {
            if (FailAudio) return new(HttpStatusCode.TooManyRequests) { Content = new StringContent("test-secret") };
            Sent.Add(System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(body["b64_data"]!.GetValue<string>())));
        }
        else if (path.EndsWith("leave_call/")) Left = true;
        else Created = body;
        return Ok(new() { ["id"] = Guid.NewGuid().ToString() });
    }
    static HttpResponseMessage Ok(JsonObject body) => new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString()) };
}
