using System.ComponentModel;
using System.IO;

namespace BotSpeaker;

/// <summary>
/// Ad hoc speech requests — the Windows counterpart of the macOS
/// OrchestrationController+SpeechRequests. Local requests never touch
/// Firestore. When this PC hosts, requests for an attendee are written to
/// <c>orchestrationRooms/{roomID}/speechRequests</c> and mirrored back by
/// polling; when this PC is an attendee it claims requests aimed at its
/// participant UID, plays them with its own ElevenLabs key and output, and
/// reports status back. A scripted meeting turn always preempts ad hoc speech
/// on the same output.
/// </summary>
public sealed partial class OrchestrationController
{
    private const int SpeechRequestHistoryLimit = 50;

    private List<SpeechRequest> _speechRequests = [];
    /// <summary>Every request this process knows about, oldest first.</summary>
    public List<SpeechRequest> SpeechRequests { get => _speechRequests; private set => Set(ref _speechRequests, value); }

    private readonly Dictionary<string, SpeechRequest> _speechRequestsById = [];
    private string? _activeSpeechRequestId;
    private CancellationTokenSource? _speechExecutionCancellation;
    private bool _hasReportedSpeechStart;
    private string? _remoteControlStatusBeforeSpeech;

    public SpeechRequest? ActiveSpeechRequest =>
        _activeSpeechRequestId is string id ? _speechRequestsById.GetValueOrDefault(id) : null;

    public SpeechRequest? FindSpeechRequest(string id) => _speechRequestsById.GetValueOrDefault(id);

    public bool HasPendingSpeech => _speechRequestsById.Values.Any(request => !request.Status.IsTerminal());

    // Public API

    /// <summary>
    /// Queues text (or a recorded file) for playback and returns the request
    /// ID. <paramref name="targetUid"/> is <see cref="SpeechRequest.LocalTarget"/>
    /// or an attendee's participant UID; remote targets require a hosted
    /// session, and this PC's own UID is treated as local. <paramref name="cycles"/>
    /// is how many times to play; null loops until cancelled.
    /// </summary>
    public async Task<string> SpeakAsync(string text, string targetUid, string? voiceId, int? cycles, string? audioPath = null)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) throw new AppException("Nothing to speak: the text is empty.");
        if (cycles is < 1) throw new AppException("The repeat count must be at least 1.");

        var resolvedTarget = targetUid == _userId ? SpeechRequest.LocalTarget : targetUid;
        if (audioPath is not null && resolvedTarget != SpeechRequest.LocalTarget)
        {
            throw new AppException("Audio files play on this PC only. Use target \"local\", or speak text to reach an attendee.");
        }
        var effectiveVoiceId = string.IsNullOrWhiteSpace(voiceId) ? null : voiceId.Trim();

        if (resolvedTarget == SpeechRequest.LocalTarget)
        {
            if (audioPath is null && !_model.HasApiKey) throw new AppException("Add your ElevenLabs API key in Settings.");
            if (string.IsNullOrEmpty(_model.SelectedDeviceId)) throw new AppException("Choose an audio output in Settings.");
            var id = "local-" + Guid.NewGuid().ToString().ToLowerInvariant();
            var request = new SpeechRequest(
                id,
                SpeechRequest.LocalTarget,
                "This PC",
                trimmed,
                audioPath is null ? effectiveVoiceId : null,
                audioPath is null ? (VoiceName(effectiveVoiceId) ?? _model.SelectedVoiceName) : null,
                _userId ?? "local",
                SpeechRequestStatus.Queued,
                DateTime.UtcNow,
                null, null, null,
                cycles,
                0,
                audioPath);
            StoreSpeechRequest(request);
            PumpSpeechRequestQueue();
            return id;
        }

        if (!IsHost || SessionId is not string sessionId)
        {
            throw new AppException("Remote speech needs a hosted meeting. Start hosting and pair the target machine first.");
        }
        var participant = Participants.FirstOrDefault(p => p.Id == resolvedTarget)
            ?? throw new AppException($"No attendee with ID {resolvedTarget} is in this meeting.");
        if (!participant.IsRecentlyConnected)
        {
            throw new AppException($"{participant.DisplayName} is not connected right now.");
        }
        var hostUid = await _database.EnsureSignedInAsync();
        var requestId = Guid.NewGuid().ToString("N");
        var now = DateTime.UtcNow;
        var fields = new Dictionary<string, object?>
        {
            ["targetUID"] = resolvedTarget,
            ["targetName"] = participant.DisplayName,
            ["text"] = trimmed,
            ["requestedBy"] = hostUid,
            ["status"] = SpeechRequestStatus.Queued.RawValue(),
            ["createdAt"] = now,
        };
        string? remoteVoiceName = null;
        if (effectiveVoiceId is not null)
        {
            remoteVoiceName = VoiceName(effectiveVoiceId) ?? effectiveVoiceId;
            fields["voiceID"] = effectiveVoiceId;
            fields["voiceName"] = remoteVoiceName;
        }
        if (cycles != 1) fields["cycles"] = cycles ?? 0;
        await _database.CommitAsync(
        [
            new FirestoreWrite
            {
                DocumentPath = SpeechRequestPath(sessionId, requestId),
                Fields = fields,
                ServerTimestampFields = ["updatedAt"],
                MustExist = false,
            },
            RoomActivityBump(sessionId),
        ]);
        // The next poll overwrites this with the server copy.
        StoreSpeechRequest(new SpeechRequest(
            requestId, resolvedTarget, participant.DisplayName, trimmed, effectiveVoiceId, remoteVoiceName,
            hostUid, SpeechRequestStatus.Queued, now, null, null, null, cycles, 0));
        return requestId;
    }

    /// <summary>
    /// Cancels a queued or in-flight request. Remote requests are cancelled by
    /// marking the document; the attendee stops playback when it sees the change.
    /// </summary>
    public async Task CancelSpeechAsync(string id)
    {
        var request = _speechRequestsById.GetValueOrDefault(id)
            ?? throw new AppException($"Unknown speech request {id}.");
        if (request.Status.IsTerminal()) return;

        if (!request.IsRemote)
        {
            await FinishSpeechRequestAsync(id, SpeechRequestStatus.Cancelled, null, stopPlayback: true);
        }
        else if (IsHost && SessionId is string sessionId)
        {
            await _database.CommitAsync(new FirestoreWrite
            {
                DocumentPath = SpeechRequestPath(sessionId, id),
                Fields = new()
                {
                    ["status"] = SpeechRequestStatus.Cancelled.RawValue(),
                    ["endedAtClient"] = DateTime.UtcNow,
                },
                UpdateMask = ["status", "endedAtClient"],
                ServerTimestampFields = ["endedAtServer", "updatedAt"],
                MustExist = true,
            });
            UpdateSpeechRequest(id, current => current with { Status = SpeechRequestStatus.Cancelled, EndedAt = DateTime.UtcNow });
        }
        else if (_activeSpeechRequestId == id)
        {
            // An attendee cancelling what it is currently speaking.
            await FinishSpeechRequestAsync(id, SpeechRequestStatus.Cancelled, null, stopPlayback: true);
        }
        else
        {
            throw new AppException("Only the host can cancel a remote speech request.");
        }
    }

    /// <summary>Cancels everything that is queued or playing.</summary>
    public async Task CancelAllSpeechAsync()
    {
        foreach (var request in SpeechRequests.Where(r => !r.Status.IsTerminal()).ToList())
        {
            try { await CancelSpeechAsync(request.Id); } catch (AppException) { }
        }
    }

    /// <summary>
    /// Suspends until the request reaches a terminal state or the timeout
    /// elapses. Returns the latest snapshot either way.
    /// </summary>
    public async Task<SpeechRequest?> WaitForSpeechRequestAsync(string id, TimeSpan timeout, CancellationToken cancellation = default)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (true)
        {
            var request = _speechRequestsById.GetValueOrDefault(id);
            if (request is null) return null;
            if (request.Status.IsTerminal() || DateTime.UtcNow >= deadline || cancellation.IsCancellationRequested) return request;
            await Task.Delay(150, CancellationToken.None);
        }
    }

    // Firestore mirror

    private void ApplySpeechRequests(List<FirestoreDocument> documents)
    {
        var merged = _speechRequestsById.Where(pair => !pair.Value.IsRemote).ToDictionary(pair => pair.Key, pair => pair.Value);
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
            if (active is null || (active.IsRemote && active.Status == SpeechRequestStatus.Cancelled))
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

    /// <summary>True while a poll should re-list the speechRequests collection every tick.</summary>
    private bool WantsFrequentSpeechRequestSync =>
        _activeSpeechRequestId is not null
        || (IsHost && _speechRequestsById.Values.Any(request => request.IsRemote && !request.Status.IsTerminal()));

    // Queue

    /// <summary>
    /// Starts the oldest runnable request when the output is free. Safe to call
    /// often; every poll and every completion pumps it.
    /// </summary>
    private void PumpSpeechRequestQueue()
    {
        if (_activeSpeechRequestId is not null || _activeExecutionTurnId is not null) return;
        var next = SpeechRequests.FirstOrDefault(request =>
            request.Status == SpeechRequestStatus.Queued
            && (!request.IsRemote || (ActiveMode == OrchestrationMode.Remote && request.TargetUid == _userId)));
        if (next is null) return;
        ExecuteSpeechRequest(next);
    }

    /// <summary>Cancels the active request so a scripted turn (or the host) can take the output.</summary>
    private void PreemptActiveSpeechRequest(string reason)
    {
        if (_activeSpeechRequestId is not string id) return;
        _ = FinishSpeechRequestAsync(id, SpeechRequestStatus.Cancelled, reason, stopPlayback: true);
    }

    /// <summary>
    /// Drops mirrored remote requests when the session ends. Any active
    /// request, local or remote, is cancelled because the player is about to
    /// reset; the room is gone for this PC, so nothing is written back.
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
        foreach (var remoteId in _speechRequestsById.Where(pair => pair.Value.IsRemote).Select(pair => pair.Key).ToList())
        {
            _speechRequestsById.Remove(remoteId);
        }
        PublishSpeechRequests();
    }

    // Execution

    private void ExecuteSpeechRequest(SpeechRequest request)
    {
        _activeSpeechRequestId = request.Id;
        _hasReportedSpeechStart = false;
        _speechExecutionCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _speechExecutionCancellation = cancellation;
        _ = RunSpeechRequestAsync(request, cancellation);
    }

    private async Task RunSpeechRequestAsync(SpeechRequest request, CancellationTokenSource cancellation)
    {
        try
        {
            if (request.IsRemote)
            {
                if (SessionId is not string sessionId) return;
                // Claiming moves the document to `preparing`. The rules refuse
                // the write once the host has cancelled the request, which is
                // how a race with a cancellation resolves without a transaction.
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
            }

            UpdateSpeechRequest(request.Id, current => current with { Status = SpeechRequestStatus.Preparing });
            SetSpeechControlStatus(request.IsRemote ? "Preparing speech from the host" : "Preparing ad hoc speech");
            cancellation.Token.ThrowIfCancellationRequested();
            if (request.AudioPath is string audioPath)
            {
                _model.PlayAudioFile(audioPath, request.Text);
            }
            else
            {
                await _model.PlayOrchestratedTurnAsync(
                    request.Text,
                    "adhoc",
                    cancellation.Token,
                    ResolveLocalVoiceId(request.VoiceId));
            }
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
        var request = _speechRequestsById.GetValueOrDefault(id);
        if (wasActive)
        {
            _speechExecutionCancellation?.Cancel();
            _speechExecutionCancellation = null;
            _activeSpeechRequestId = null;
            _hasReportedSpeechStart = false;
            if (stopPlayback) _model.StopOrchestratedTurn();
            RestoreSpeechControlStatus();
            _model.FinishAdHocSpeech();
        }
        UpdateSpeechRequest(id, current => current with
        {
            Status = status,
            Error = error,
            EndedAt = DateTime.UtcNow,
        });
        if (request?.AudioPath is string audioPath)
        {
            // The uploaded copy is only needed for this one request; the
            // player has already decoded it into memory.
            try { File.Delete(audioPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        PumpSpeechRequestQueue();

        if (request is null || !request.IsRemote || SessionId is not string sessionId) return;
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
            || _speechRequestsById.GetValueOrDefault(id) is not SpeechRequest request)
        {
            return;
        }
        _hasReportedSpeechStart = true;
        var clientTime = DateTime.UtcNow;
        UpdateSpeechRequest(id, current => current with { Status = SpeechRequestStatus.Speaking, StartedAt = clientTime });
        SetSpeechControlStatus(request.IsRemote ? "Speaking for the host" : "Speaking ad hoc text");
        if (request.IsRemote && SessionId is string sessionId)
        {
            _ = ReportSpeechStartAsync(sessionId, id, clientTime);
        }
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

    private void StoreSpeechRequest(SpeechRequest request)
    {
        _speechRequestsById[request.Id] = request;
        TrimSpeechRequestHistory();
        PublishSpeechRequests();
    }

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

    private string? VoiceName(string? voiceId) =>
        voiceId is null ? null : _model.Voices.FirstOrDefault(voice => voice.Id == voiceId)?.Name;

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
