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
/// One-off speech outside the scripted timeline. Local requests (target
/// <see cref="LocalTarget"/>) live only in memory; requests aimed at a paired
/// attendee are mirrored from the room's <c>speechRequests</c> collection.
/// The host writes them (from the <c>botspeaker</c> CLI on either platform or
/// the macOS Speak popover), the targeted attendee claims and plays them, and
/// the status fields flow back to the host.
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
    /// <summary>Passes that have finished so far on the machine doing the playing.</summary>
    int CompletedCycles,
    /// <summary>A pre-recorded file to play instead of synthesizing <see cref="Text"/>. Local only.</summary>
    string? AudioPath = null)
{
    public const string LocalTarget = "local";

    public bool IsRemote => TargetUid != LocalTarget;
    public bool IsLooping => Cycles != 1;
    public bool IsAudioFile => AudioPath is not null;

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
