namespace BotSpeaker;

/// <summary>Lifecycle of an ad hoc speech request — the Windows counterpart of the macOS SpeechRequestStatus.</summary>
public enum SpeechRequestStatus
{
    Queued,
    Preparing,
    Speaking,
    Completed,
    Failed,
    Cancelled,
}

public static class SpeechRequestStatusExtensions
{
    public static string RawValue(this SpeechRequestStatus status) => status switch
    {
        SpeechRequestStatus.Queued => "queued",
        SpeechRequestStatus.Preparing => "preparing",
        SpeechRequestStatus.Speaking => "speaking",
        SpeechRequestStatus.Completed => "completed",
        SpeechRequestStatus.Failed => "failed",
        SpeechRequestStatus.Cancelled => "cancelled",
        _ => "queued",
    };

    public static SpeechRequestStatus SpeechRequestStatusFromRaw(string? raw) => raw switch
    {
        "preparing" => SpeechRequestStatus.Preparing,
        "speaking" => SpeechRequestStatus.Speaking,
        "completed" => SpeechRequestStatus.Completed,
        "failed" => SpeechRequestStatus.Failed,
        "cancelled" => SpeechRequestStatus.Cancelled,
        _ => SpeechRequestStatus.Queued,
    };

    public static bool IsTerminal(this SpeechRequestStatus status) => status is
        SpeechRequestStatus.Completed
        or SpeechRequestStatus.Failed
        or SpeechRequestStatus.Cancelled;
}

/// <summary>
/// One-off speech the host sends to this PC outside the scripted timeline,
/// mirrored from the room's <c>speechRequests</c> collection. The host writes
/// it (from the Speak popover or the <c>botspeaker</c> CLI), this attendee
/// claims and plays it, and the status fields flow back to the host.
/// </summary>
public sealed record SpeechRequest(
    string Id,
    string TargetUid,
    string TargetName,
    string Text,
    string? VoiceId,
    string? VoiceName,
    string RequestedBy,
    SpeechRequestStatus Status,
    DateTime CreatedAt,
    DateTime? StartedAt,
    DateTime? EndedAt,
    string? Error,
    /// <summary>Number of passes to play. 1 plays once; null repeats until cancelled.</summary>
    int? Cycles,
    /// <summary>Passes that have finished so far on this PC.</summary>
    int CompletedCycles)
{
    public bool IsLooping => Cycles != 1;

    /// <summary>
    /// Firestore stores endless loops as 0 because the host must set a value the
    /// attendee can distinguish from an absent (single-pass) field.
    /// </summary>
    public static int? CyclesFromStored(object? stored) => stored switch
    {
        long value => value <= 0 ? null : (int)value,
        _ => 1,
    };
}
