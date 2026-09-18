using System.Text.Json.Nodes;

namespace BotSpeaker;

public sealed record RecallMeetingTurn(string BotId, string Voice, string Text);

/// <summary>Advances only after the previous clip's duration guard has elapsed.</summary>
public static class RecallTurnRunner
{
    public static async Task RunAsync(IReadOnlyList<RecallMeetingTurn> turns,
        Func<string, JsonObject, Task<JsonObject>> request, Action<int> progress, CancellationToken token, Func<bool>? skipRequested = null)
    {
        foreach (var (turn, index) in turns.Select((turn, index) => (turn, index)))
        {
            token.ThrowIfCancellationRequested();
            progress(index);
            var response = await request("speak", new() { ["botId"] = turn.BotId, ["voice"] = turn.Voice, ["text"] = turn.Text });
            var id = response["job"]?["id"]?.GetValue<string>() ?? throw new InvalidOperationException("Recall did not return a speech job.");
            try
            {
                while (true)
                {
                    token.ThrowIfCancellationRequested();
                    if (skipRequested?.Invoke() == true) {
                        await request("cancel", new() { ["id"] = id });
                        break;
                    }
                    var status = await request("status", new());
                    var job = status["jobs"]!.AsArray().FirstOrDefault(j => j?["id"]?.GetValue<string>() == id)
                        ?? throw new InvalidOperationException("Speech job was lost.");
                    var state = job["status"]?.GetValue<string>();
                    if (state == "finished_dispatching") break;
                    if (state is "failed" or "cancelled") throw new InvalidOperationException(job["error"]?.GetValue<string>() ?? "Speech was cancelled.");
                    await Task.Delay(100, token);
                }
            }
            finally
            {
                if (token.IsCancellationRequested) await request("cancel", new() { ["id"] = id });
            }
        }
    }
}
