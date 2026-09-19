using System.Text.Json.Nodes;

namespace BotSpeaker;

public sealed record RecallMeetingTurn(string BotId, string Voice, string Text);

/// <summary>Prepares all clips before starting, then advances on estimated clip completion.</summary>
public static class RecallTurnRunner
{
    public static async Task RunAsync(IReadOnlyList<RecallMeetingTurn> turns,
        Func<string, JsonObject, Task<JsonObject>> request, Action<int> progress, CancellationToken token,
        Func<bool>? skipRequested = null, Action<int>? preparing = null)
    {
        var ids = new List<string>();
        var completed = new HashSet<string>();
        try
        {
            // Bound synthesis concurrency to one and never send partial meetings
            // when a later clip fails to prepare.
            foreach (var (turn, index) in turns.Select((turn, index) => (turn, index)))
            {
                token.ThrowIfCancellationRequested();
                preparing?.Invoke(index);
                var response = await request("prepare", new() { ["botId"] = turn.BotId, ["voice"] = turn.Voice, ["text"] = turn.Text });
                var id = response["job"]?["id"]?.GetValue<string>() ?? throw new InvalidOperationException("Recall did not return a speech job.");
                ids.Add(id);
                await WaitFor(id, "prepared", allowSkip: false);
            }
            for (int index = 0; index < ids.Count; index++)
            {
                token.ThrowIfCancellationRequested();
                progress(index);
                await request("dispatch", new() { ["id"] = ids[index] });
                await WaitFor(ids[index], "finished_dispatching", allowSkip: true);
                completed.Add(ids[index]);
            }
        }
        finally
        {
            // Also release preloaded clips on Stop, synthesis failure, or dispatch failure.
            foreach (var id in ids.Where(id => !completed.Contains(id)))
            {
                try { await request("cancel", new() { ["id"] = id }); }
                catch (Exception error) { System.Diagnostics.Trace.TraceWarning("Recall job cleanup failed: {0}", error.Message); }
            }
        }

        async Task WaitFor(string id, string expected, bool allowSkip)
        {
            while (true)
            {
                token.ThrowIfCancellationRequested();
                if (allowSkip && skipRequested?.Invoke() == true)
                {
                    await request("cancel", new() { ["id"] = id });
                    return;
                }
                var status = await request("status", new());
                var job = status["jobs"]!.AsArray().FirstOrDefault(j => j?["id"]?.GetValue<string>() == id)
                    ?? throw new InvalidOperationException("Speech job was lost.");
                var state = job["status"]?.GetValue<string>();
                if (state == expected) return;
                if (state is "failed" or "cancelled") throw new InvalidOperationException(job["error"]?.GetValue<string>() ?? "Speech was cancelled.");
                await Task.Delay(20, token);
            }
        }
    }
}
