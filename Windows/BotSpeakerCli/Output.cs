using System.Text.Json;
using System.Text.Json.Nodes;

namespace BotSpeaker.Cli;

public static class Output
{
    private static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };

    public static void Json(JsonNode? value) => Console.WriteLine(value?.ToJsonString(Pretty) ?? "{}");

    public static int Fail(ControlClient.Failure failure, bool json)
    {
        if (json)
        {
            Json(new JsonObject { ["ok"] = false, ["error"] = new JsonObject { ["code"] = failure.Code, ["message"] = failure.Message } });
        }
        else
        {
            Console.Error.WriteLine($"error: {failure.Message}");
        }
        return failure.ExitCode;
    }

    public static int Fail(Exception error, bool json) =>
        Fail(error as ControlClient.Failure ?? new ControlClient.Failure(1, "error", error.Message), json);

    public static string String(JsonNode? value) => value switch
    {
        null => "-",
        JsonValue v when v.TryGetValue<string>(out var text) => text,
        JsonValue v when v.TryGetValue<bool>(out var flag) => flag ? "yes" : "no",
        JsonValue v when v.TryGetValue<double>(out var number) => number.ToString(System.Globalization.CultureInfo.InvariantCulture),
        _ => value.ToJsonString(),
    };

    public static bool? Bool(JsonNode? value) =>
        value is JsonValue v && v.TryGetValue<bool>(out var flag) ? flag : null;

    public static int? Int(JsonNode? value) =>
        value is JsonValue v && v.TryGetValue<int>(out var number) ? number : null;

    /// <summary>"2/5" for a counted repeat, "3/∞" for a loop, null for a single pass.</summary>
    public static string? Cycles(JsonObject request)
    {
        int completed = Int(request["completedCycles"]) ?? 0;
        if (Bool(request["loop"]) == true) return $"{completed}/∞";
        int? cycles = Int(request["cycles"]);
        if (cycles is null || cycles == 1) return null;
        return $"{completed}/{cycles}";
    }

    public static void Table(List<string[]> rows)
    {
        if (rows.Count == 0) return;
        var widths = new int[rows[0].Length];
        foreach (var row in rows)
        {
            for (int index = 0; index < widths.Length && index < row.Length; index++)
            {
                widths[index] = Math.Max(widths[index], row[index].Length);
            }
        }
        foreach (var row in rows)
        {
            var cells = row.Select((cell, index) => index == row.Length - 1 ? cell : cell.PadRight(widths[index]));
            Console.WriteLine(string.Join("  ", cells));
        }
    }
}
