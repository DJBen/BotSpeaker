using System.Text.Json.Serialization;

namespace BotSpeaker;

public enum OrchestrationMode
{
    Host,
    Remote,
}

public enum OrchestrationSessionStatus
{
    Lobby,
    Running,
    Paused,
    Completed,
    Stopped,
}

public static class OrchestrationSessionStatusExtensions
{
    public static string RawValue(this OrchestrationSessionStatus status) => status switch
    {
        OrchestrationSessionStatus.Lobby => "lobby",
        OrchestrationSessionStatus.Running => "running",
        OrchestrationSessionStatus.Paused => "paused",
        OrchestrationSessionStatus.Completed => "completed",
        OrchestrationSessionStatus.Stopped => "stopped",
        _ => "lobby",
    };

    public static OrchestrationSessionStatus SessionStatusFromRaw(string? raw) => raw switch
    {
        "running" => OrchestrationSessionStatus.Running,
        "paused" => OrchestrationSessionStatus.Paused,
        "completed" => OrchestrationSessionStatus.Completed,
        "stopped" => OrchestrationSessionStatus.Stopped,
        _ => OrchestrationSessionStatus.Lobby,
    };

    public static string DisplayName(this OrchestrationSessionStatus status) => status switch
    {
        OrchestrationSessionStatus.Lobby => "Waiting for speakers",
        OrchestrationSessionStatus.Running => "Meeting in progress",
        OrchestrationSessionStatus.Paused => "Meeting paused",
        OrchestrationSessionStatus.Completed => "Meeting completed",
        OrchestrationSessionStatus.Stopped => "Meeting stopped",
        _ => "Waiting for speakers",
    };
}

public enum OrchestrationTurnStatus
{
    Queued,
    Assigned,
    Preparing,
    Speaking,
    Paused,
    Completed,
    Skipped,
    Failed,
    Stopped,
}

public static class OrchestrationTurnStatusExtensions
{
    public static string RawValue(this OrchestrationTurnStatus status) => status switch
    {
        OrchestrationTurnStatus.Queued => "queued",
        OrchestrationTurnStatus.Assigned => "assigned",
        OrchestrationTurnStatus.Preparing => "preparing",
        OrchestrationTurnStatus.Speaking => "speaking",
        OrchestrationTurnStatus.Paused => "paused",
        OrchestrationTurnStatus.Completed => "completed",
        OrchestrationTurnStatus.Skipped => "skipped",
        OrchestrationTurnStatus.Failed => "failed",
        OrchestrationTurnStatus.Stopped => "stopped",
        _ => "queued",
    };

    public static OrchestrationTurnStatus? TurnStatusFromRaw(string? raw) => raw switch
    {
        "queued" => OrchestrationTurnStatus.Queued,
        "assigned" => OrchestrationTurnStatus.Assigned,
        "preparing" => OrchestrationTurnStatus.Preparing,
        "speaking" => OrchestrationTurnStatus.Speaking,
        "paused" => OrchestrationTurnStatus.Paused,
        "completed" => OrchestrationTurnStatus.Completed,
        "skipped" => OrchestrationTurnStatus.Skipped,
        "failed" => OrchestrationTurnStatus.Failed,
        "stopped" => OrchestrationTurnStatus.Stopped,
        _ => null,
    };

    public static bool IsTerminal(this OrchestrationTurnStatus status) => status is
        OrchestrationTurnStatus.Completed
        or OrchestrationTurnStatus.Skipped
        or OrchestrationTurnStatus.Failed
        or OrchestrationTurnStatus.Stopped;
}

public sealed record OrchestrationParticipant(
    string Id,
    string DisplayName,
    string ScriptTitle,
    string VoiceName,
    int SegmentCount,
    int PreparedSegmentCount,
    string? PreparationError,
    bool SupportsPrefetch,
    string Status,
    bool IsConnected,
    DateTime? LastSeenAt,
    DateTime? JoinedAt)
{
    public bool IsRecentlyConnected =>
        IsConnected
        && LastSeenAt is DateTime seen
        && DateTime.UtcNow - seen < TimeSpan.FromSeconds(90);

    public bool IsFirstTurnPrepared => SegmentCount > 0 && PreparedSegmentCount > 0;
}

public sealed record OrchestrationTurn(
    string Id,
    int Index,
    string ParticipantUid,
    string SpeakerName,
    string ScriptTitle,
    int SegmentIndex,
    OrchestrationTurnStatus Status,
    string? Text,
    DateTime? StartedAtClient,
    DateTime? StartedAtServer,
    DateTime? EndedAtClient,
    DateTime? EndedAtServer,
    string? Error);

/// <summary>Matches the macOS OrchestrationTranscript JSON schema exactly.</summary>
public sealed record OrchestrationTranscript(
    [property: JsonPropertyName("schemaVersion")] int SchemaVersion,
    [property: JsonPropertyName("sessionID")] string SessionId,
    [property: JsonPropertyName("pairingCode")] string PairingCode,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("startedAt")] DateTime? StartedAt,
    [property: JsonPropertyName("endedAt")] DateTime? EndedAt,
    [property: JsonPropertyName("exportedAt")] DateTime ExportedAt,
    [property: JsonPropertyName("speakers")] List<OrchestrationTranscript.Speaker> Speakers,
    [property: JsonPropertyName("turns")] List<OrchestrationTranscript.Turn> Turns)
{
    public sealed record Speaker(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("scriptTitle")] string ScriptTitle,
        [property: JsonPropertyName("voiceName")] string VoiceName);

    public sealed record Turn(
        [property: JsonPropertyName("index")] int Index,
        [property: JsonPropertyName("speakerID")] string SpeakerId,
        [property: JsonPropertyName("speakerName")] string SpeakerName,
        [property: JsonPropertyName("scriptTitle")] string ScriptTitle,
        [property: JsonPropertyName("segmentIndex")] int SegmentIndex,
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("startedAt")] DateTime? StartedAt,
        [property: JsonPropertyName("endedAt")] DateTime? EndedAt,
        [property: JsonPropertyName("serverReceivedStartedAt")] DateTime? ServerReceivedStartedAt,
        [property: JsonPropertyName("serverReceivedEndedAt")] DateTime? ServerReceivedEndedAt,
        [property: JsonPropertyName("durationMilliseconds")] int? DurationMilliseconds,
        [property: JsonPropertyName("error")] string? Error);
}

/// <summary>
/// Splits a script into meeting turns at paragraph boundaries, falling back to
/// sentence groups for oversized paragraphs — mirrors the macOS
/// OrchestrationScriptSegmenter so both clients produce identical turn counts
/// for identical text.
/// </summary>
public static class OrchestrationScriptSegmenter
{
    private const int FallbackTargetLength = 900;

    public static List<string> Segments(string text)
    {
        var normalized = text.Replace("\r\n", "\n");
        var paragraphs = normalized
            .Split("\n\n")
            .Select(p => p.Trim())
            .Where(p => p.Length > 0)
            .ToList();

        if (paragraphs.Count > 1)
        {
            return paragraphs.SelectMany(SplitOversizedParagraph).ToList();
        }
        return SplitOversizedParagraph(normalized.Trim());
    }

    private static List<string> SplitOversizedParagraph(string paragraph)
    {
        if (paragraph.Length <= FallbackTargetLength * 2)
        {
            return paragraph.Length == 0 ? [] : [paragraph];
        }

        var segments = new List<string>();
        var current = "";
        foreach (var sentence in Sentences(paragraph))
        {
            if (current.Length > 0 && current.Length + sentence.Length > FallbackTargetLength)
            {
                segments.Add(current);
                current = sentence;
            }
            else
            {
                current = current.Length == 0 ? sentence : $"{current} {sentence}";
            }
        }
        if (current.Length > 0) segments.Add(current);
        return segments.Count == 0 ? [paragraph] : segments;
    }

    private static IEnumerable<string> Sentences(string paragraph)
    {
        int start = 0;
        for (int index = 0; index < paragraph.Length; index++)
        {
            char character = paragraph[index];
            if (character is not ('.' or '!' or '?' or '\n')) continue;
            // Consume any run of closing punctuation after the terminator.
            int end = index + 1;
            while (end < paragraph.Length && paragraph[end] is '"' or '”' or '\'' or ')' or ']') end++;
            var sentence = paragraph[start..end].Trim();
            if (sentence.Length > 0) yield return sentence;
            start = end;
            index = end - 1;
        }
        var tail = paragraph[start..].Trim();
        if (tail.Length > 0) yield return tail;
    }
}
