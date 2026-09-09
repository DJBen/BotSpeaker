using System.ComponentModel;

namespace BotSpeaker;

/// <summary>
/// Ad hoc speech requests — the attendee half of the macOS
/// OrchestrationController+SpeechRequests. The host (from its Speak popover
/// or the <c>botspeaker</c> CLI) writes a document under
/// <c>orchestrationRooms/{roomID}/speechRequests</c>; this PC polls the
/// collection, claims requests aimed at its participant UID, plays them with
/// its own ElevenLabs key and output, and mirrors the status back so the
/// host's <c>botspeaker speak --wait</c> returns. A scripted meeting turn
/// always preempts ad hoc speech on the same output.
/// </summary>
public sealed partial class OrchestrationController
{
    private const int SpeechRequestHistoryLimit = 50;

    private List<SpeechRequest> _speechRequests = [];
    /// <summary>Every request mirrored from the room, oldest first.</summary>
    public List<SpeechRequest> SpeechRequests { get => _speechRequests; private set => Set(ref _speechRequests, value); }

    private readonly Dictionary<string, SpeechRequest> _speechRequestsById = [];
    private string? _activeSpeechRequestId;
    private CancellationTokenSource? _speechExecutionCancellation;
    private bool _hasReportedSpeechStart;
    private string? _remoteControlStatusBeforeSpeech;

    public SpeechRequest? ActiveSpeechRequest =>
        _activeSpeechRequestId is string id ? _speechRequestsById.GetValueOrDefault(id) : null;

    // Firestore mirror

    private void ApplySpeechRequests(List<FirestoreDocument> documents)
    {
        var merged = new Dictionary<string, SpeechRequest>();
        foreach (var document in documents)
        {
            if (document.String("targetUID") is not string targetUid
                || document.String("text") is not string text)
            {
                continue;
            }
            var existing = _speechRequestsById.GetValueOrDefault(document.Id);
            var error = document.String("error");
            merged[document.Id] = new SpeechRequest(
                document.Id,
                targetUid,
                document.String("targetName") ?? existing?.TargetName ?? "Attendee",
                text,
                document.String("voiceID"),
                document.String("voiceName"),
                document.String("requestedBy") ?? "",
                SpeechRequestStatusExtensions.SpeechRequestStatusFromRaw(document.String("status")),
                document.Timestamp("createdAt") ?? existing?.CreatedAt ?? DateTime.UtcNow,
                document.Timestamp("startedAtClient") ?? document.Timestamp("startedAtServer"),
                document.Timestamp("endedAtClient") ?? document.Timestamp("endedAtServer"),
                string.IsNullOrEmpty(error) ? null : error,
                SpeechRequest.CyclesFromStored(document.Fields.GetValueOrDefault("cycles")),
                existing?.CompletedCycles ?? 0);
        }
        _speechRequestsById.Clear();
        foreach (var (id, request) in merged) _speechRequestsById[id] = request;
        TrimSpeechRequestHistory();
        PublishSpeechRequests();

        // The host cancelled (or deleted) the request this PC is playing.
        if (_activeSpeechRequestId is string activeId)
        {
            var active = _speechRequestsById.GetValueOrDefault(activeId);
            if (active is null || active.Status == SpeechRequestStatus.Cancelled)
            {
                _speechExecutionCancellation?.Cancel();
                _speechExecutionCancellation = null;
                _activeSpeechRequestId = null;
                _hasReportedSpeechStart = false;
                _model.StopOrchestratedTurn();
                RestoreSpeechControlStatus();
            }
        }
        PumpSpeechRequestQueue();
    }

    // Queue

    /// <summary>
    /// Starts the oldest runnable request when the output is free. Safe to call
    /// often; every poll and every completion pumps it.
    /// </summary>
    private void PumpSpeechRequestQueue()
    {
        if (_activeSpeechRequestId is not null
            || _activeExecutionTurnId is not null
            || ActiveMode != OrchestrationMode.Remote
            || _userId is not string uid
            || SessionId is not string sessionId)
        {
            return;
        }
        var next = SpeechRequests.FirstOrDefault(request =>
            request.Status == SpeechRequestStatus.Queued && request.TargetUid == uid);
        if (next is null) return;
        ExecuteSpeechRequest(sessionId, next);
    }

    /// <summary>Cancels the active request so a scripted turn (or the host) can take the output.</summary>
    private void PreemptActiveSpeechRequest(string reason)
    {
        if (_activeSpeechRequestId is not string id) return;
        _ = FinishSpeechRequestAsync(id, SpeechRequestStatus.Cancelled, reason, stopPlayback: true);
    }

    /// <summary>
    /// Drops mirrored requests when the session ends. Any active request is
    /// cancelled locally because the player is about to reset; the room is
    /// gone for this PC, so nothing is written back.
    /// </summary>
    private void ClearRemoteSpeechRequests()
    {
        if (_activeSpeechRequestId is string id)
        {
            _speechExecutionCancellation?.Cancel();
            _speechExecutionCancellation = null;
            _activeSpeechRequestId = null;
            _hasReportedSpeechStart = false;
            _remoteControlStatusBeforeSpeech = null;
            if (_speechRequestsById.TryGetValue(id, out var request))
            {
                _speechRequestsById[id] = request with
                {
                    Status = SpeechRequestStatus.Cancelled,
                    Error = "The meeting session ended.",
                    EndedAt = DateTime.UtcNow,
                };
            }
        }
        _speechRequestsById.Clear();
        PublishSpeechRequests();
    }

    // Execution

    private void ExecuteSpeechRequest(string sessionId, SpeechRequest request)
    {
        _activeSpeechRequestId = request.Id;
        _hasReportedSpeechStart = false;
        _speechExecutionCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _speechExecutionCancellation = cancellation;
        _ = RunSpeechRequestAsync(sessionId, request, cancellation);
    }

    private async Task RunSpeechRequestAsync(string sessionId, SpeechRequest request, CancellationTokenSource cancellation)
    {
        try
        {
            // Claiming moves the document to `preparing`. The rules refuse the
            // write once the host has cancelled the request, which is how a
            // race with a cancellation resolves without a transaction.
            try
            {
                await _database.CommitAsync(new FirestoreWrite
                {
                    DocumentPath = SpeechRequestPath(sessionId, request.Id),
                    Fields = new() { ["status"] = SpeechRequestStatus.Preparing.RawValue() },
                    UpdateMask = ["status"],
                    ServerTimestampFields = ["updatedAt"],
                    MustExist = true,
                }, cancellation.Token);
            }
            catch (Exception error) when (IsStaleWrite(error))
            {
                if (_activeSpeechRequestId == request.Id)
                {
                    _activeSpeechRequestId = null;
                    _hasReportedSpeechStart = false;
                    UpdateSpeechRequest(request.Id, current => current with { Status = SpeechRequestStatus.Cancelled });
                    PumpSpeechRequestQueue();
                }
                return;
            }
            if (_activeSpeechRequestId != request.Id) return;

            UpdateSpeechRequest(request.Id, current => current with { Status = SpeechRequestStatus.Preparing });
            SetSpeechControlStatus("Preparing speech from the host");
            cancellation.Token.ThrowIfCancellationRequested();
            await _model.PlayOrchestratedTurnAsync(
                request.Text,
                "adhoc",
                cancellation.Token,
                ResolveLocalVoiceId(request.VoiceId));
            // Playback continues; SpeechPlaybackDidFinish completes the request.
            if (_activeSpeechRequestId == request.Id && !_model.Player.HasAudio)
            {
                await FinishSpeechRequestAsync(request.Id, SpeechRequestStatus.Failed, "No audio was produced.", stopPlayback: false);
            }
        }
        catch (OperationCanceledException)
        {
            // Cancelled by the host, a scripted turn, or session teardown; state is already finalized.
        }
        catch (Exception error)
        {
            if (_activeSpeechRequestId != request.Id) return;
            await FinishSpeechRequestAsync(request.Id, SpeechRequestStatus.Failed, error.Message, stopPlayback: false);
        }
        finally
        {
            if (_speechExecutionCancellation == cancellation) _speechExecutionCancellation = null;
        }
    }

    private async Task FinishSpeechRequestAsync(string id, SpeechRequestStatus status, string? error, bool stopPlayback)
    {
        bool wasActive = _activeSpeechRequestId == id;
        if (wasActive)
        {
            _speechExecutionCancellation?.Cancel();
            _speechExecutionCancellation = null;
            _activeSpeechRequestId = null;
            _hasReportedSpeechStart = false;
            if (stopPlayback) _model.StopOrchestratedTurn();
            RestoreSpeechControlStatus();
        }
        UpdateSpeechRequest(id, current => current with
        {
            Status = status,
            Error = error,
            EndedAt = DateTime.UtcNow,
        });
        PumpSpeechRequestQueue();

        if (SessionId is not string sessionId) return;
        var fields = new Dictionary<string, object?>
        {
            ["status"] = status.RawValue(),
            ["endedAtClient"] = DateTime.UtcNow,
        };
        var mask = new List<string> { "status", "endedAtClient" };
        if (error is not null)
        {
            fields["error"] = error;
            mask.Add("error");
        }
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = SpeechRequestPath(sessionId, id),
                    Fields = fields,
                    UpdateMask = mask,
                    ServerTimestampFields = ["endedAtServer", "updatedAt"],
                    MustExist = true,
                },
                RoomActivityBump(sessionId),
            ]);
        }
        catch (Exception reportError) when (IsStaleWrite(reportError))
        {
            // The host already cancelled it; the mirror will catch up.
        }
        catch (Exception reportError)
        {
            ErrorMessage = reportError.Message;
        }
    }

    // Playback callbacks (routed from PlaybackDidStart / PlaybackDidFinish)

    private void SpeechPlaybackDidStart()
    {
        if (_activeSpeechRequestId is not string id
            || _hasReportedSpeechStart
            || !_speechRequestsById.ContainsKey(id)
            || SessionId is not string sessionId)
        {
            return;
        }
        _hasReportedSpeechStart = true;
        var clientTime = DateTime.UtcNow;
        UpdateSpeechRequest(id, current => current with { Status = SpeechRequestStatus.Speaking, StartedAt = clientTime });
        SetSpeechControlStatus("Speaking for the host");
        _ = ReportSpeechStartAsync(sessionId, id, clientTime);
    }

    private async Task ReportSpeechStartAsync(string sessionId, string id, DateTime clientTime)
    {
        try
        {
            await _database.CommitAsync(new FirestoreWrite
            {
                DocumentPath = SpeechRequestPath(sessionId, id),
                Fields = new()
                {
                    ["status"] = SpeechRequestStatus.Speaking.RawValue(),
                    ["startedAtClient"] = clientTime,
                },
                UpdateMask = ["status", "startedAtClient"],
                ServerTimestampFields = ["startedAtServer", "updatedAt"],
                MustExist = true,
            });
        }
        catch (Exception error) when (IsStaleWrite(error))
        {
            // The host cancelled before playback started; the next poll stops us.
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
    }

    private void SpeechPlaybackDidFinish()
    {
        if (_activeSpeechRequestId is not string id
            || _speechRequestsById.GetValueOrDefault(id) is not SpeechRequest request)
        {
            return;
        }
        int completedCycles = request.CompletedCycles + 1;
        UpdateSpeechRequest(id, current => current with { CompletedCycles = completedCycles });

        // Looping requests start over instead of finishing. The player has
        // finished the sequence, so Play() rewinds and schedules it again.
        bool wantsAnotherPass = request.Cycles is int cycles ? completedCycles < cycles : true;
        if (wantsAnotherPass && _model.Player.HasAudio)
        {
            _model.Player.Play();
            return;
        }
        _ = FinishSpeechRequestAsync(id, SpeechRequestStatus.Completed, null, stopPlayback: false);
    }

    /// <summary>The user stopped or replaced playback from the app itself.</summary>
    private void SpeechPlaybackWasTakenOver()
    {
        if (_activeSpeechRequestId is not string id) return;
        _ = FinishSpeechRequestAsync(id, SpeechRequestStatus.Cancelled, "Playback was stopped in the app.", stopPlayback: false);
    }

    // Helpers

    private void UpdateSpeechRequest(string id, Func<SpeechRequest, SpeechRequest> mutate)
    {
        if (!_speechRequestsById.TryGetValue(id, out var request)) return;
        _speechRequestsById[id] = mutate(request);
        PublishSpeechRequests();
    }

    private void PublishSpeechRequests()
    {
        var ordered = _speechRequestsById.Values.OrderBy(request => request.CreatedAt).ToList();
        if (!ordered.SequenceEqual(SpeechRequests)) SpeechRequests = ordered;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ActiveSpeechRequest)));
    }

    private void TrimSpeechRequestHistory()
    {
        var terminal = _speechRequestsById.Values
            .Where(request => request.Status.IsTerminal())
            .OrderBy(request => request.CreatedAt)
            .ToList();
        int overflow = terminal.Count - SpeechRequestHistoryLimit;
        for (int index = 0; index < overflow; index++)
        {
            _speechRequestsById.Remove(terminal[index].Id);
        }
    }

    /// <summary>
    /// The host may send a voice name instead of an ID when it does not share
    /// this PC's voice library; map it against the local list.
    /// </summary>
    private string? ResolveLocalVoiceId(string? requested)
    {
        if (string.IsNullOrWhiteSpace(requested)) return null;
        if (_model.Voices.Any(voice => voice.Id == requested)) return requested;
        var byName = _model.Voices.FirstOrDefault(voice =>
            string.Equals(voice.Name, requested, StringComparison.OrdinalIgnoreCase));
        return byName?.Id ?? requested;
    }

    private void SetSpeechControlStatus(string status)
    {
        if (!_model.IsRemoteControlled) return;
        _remoteControlStatusBeforeSpeech ??= _model.RemoteControlStatus;
        _model.UpdateRemoteControlStatus(status);
    }

    private void RestoreSpeechControlStatus()
    {
        if (_remoteControlStatusBeforeSpeech is not string previous) return;
        _remoteControlStatusBeforeSpeech = null;
        _model.UpdateRemoteControlStatus(previous);
    }
}
