using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace BotSpeaker;

/// <summary>
/// Multi-client meeting orchestration over Firestore — the Windows counterpart
/// of the macOS OrchestrationController. The macOS app receives document
/// changes through Firebase SDK snapshot listeners; Windows polls the same
/// documents over REST on a short interval, so both clients drive the identical
/// room/participant/turn protocol and satisfy the same security rules.
/// </summary>
public sealed class OrchestrationController : INotifyPropertyChanged
{
    private const int MaximumTurnCount = 450;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1.5);
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan PairingLifetime = TimeSpan.FromHours(4);
    private static readonly TimeSpan CollectionResyncInterval = TimeSpan.FromSeconds(30);

    public event PropertyChangedEventHandler? PropertyChanged;

    private OrchestrationMode _setupMode = OrchestrationMode.Host;
    public OrchestrationMode SetupMode { get => _setupMode; set => Set(ref _setupMode, value); }

    private string _speakerName;
    public string SpeakerName { get => _speakerName; set => Set(ref _speakerName, value); }

    private string _pairingCodeInput = "";
    public string PairingCodeInput { get => _pairingCodeInput; set => Set(ref _pairingCodeInput, value); }

    private string _meetingScriptText = OrchestratedMeetingTemplate.LaunchReadiness.Text;
    public string MeetingScriptText { get => _meetingScriptText; set => Set(ref _meetingScriptText, value); }

    private OrchestratedMeetingTemplate _selectedTemplate = OrchestratedMeetingTemplate.LaunchReadiness;
    public OrchestratedMeetingTemplate SelectedTemplate { get => _selectedTemplate; private set => Set(ref _selectedTemplate, value); }

    private string _meetingScriptTitle = OrchestratedMeetingTemplate.LaunchReadiness.Title;
    public string MeetingScriptTitle { get => _meetingScriptTitle; private set => Set(ref _meetingScriptTitle, value); }

    public List<OrchestratedSpeakerConfiguration> SpeakerConfigurations { get; }

    private OrchestrationMode? _activeMode;
    public OrchestrationMode? ActiveMode { get => _activeMode; private set => Set(ref _activeMode, value); }

    private string? _sessionId;
    public string? SessionId { get => _sessionId; private set => Set(ref _sessionId, value); }

    private string _pairingCode = "";
    public string PairingCode { get => _pairingCode; private set => Set(ref _pairingCode, value); }

    private OrchestrationSessionStatus _sessionStatus = OrchestrationSessionStatus.Lobby;
    public OrchestrationSessionStatus SessionStatus { get => _sessionStatus; private set => Set(ref _sessionStatus, value); }

    private bool _pairingOpen;
    public bool PairingOpen { get => _pairingOpen; private set => Set(ref _pairingOpen, value); }

    private List<OrchestrationParticipant> _participants = [];
    public List<OrchestrationParticipant> Participants { get => _participants; private set => Set(ref _participants, value); }

    private List<string> _participantOrder = [];
    public List<string> ParticipantOrder { get => _participantOrder; private set => Set(ref _participantOrder, value); }

    private List<OrchestrationTurn> _turns = [];
    public List<OrchestrationTurn> Turns { get => _turns; private set => Set(ref _turns, value); }

    private int _activeTurnIndex = -1;
    public int ActiveTurnIndex { get => _activeTurnIndex; private set => Set(ref _activeTurnIndex, value); }

    private DateTime? _startedAt;
    public DateTime? StartedAt { get => _startedAt; private set => Set(ref _startedAt, value); }

    private DateTime? _endedAt;
    public DateTime? EndedAt { get => _endedAt; private set => Set(ref _endedAt, value); }

    private int _preparedLocalSegmentCount;
    public int PreparedLocalSegmentCount { get => _preparedLocalSegmentCount; private set => Set(ref _preparedLocalSegmentCount, value); }

    private string _preparationStatus = "Not prepared";
    public string PreparationStatus { get => _preparationStatus; private set => Set(ref _preparationStatus, value); }

    private string? _preparationError;
    public string? PreparationError { get => _preparationError; private set => Set(ref _preparationError, value); }

    private bool _isBusy;
    public bool IsBusy { get => _isBusy; private set => Set(ref _isBusy, value); }

    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; private set => Set(ref _errorMessage, value); }

    private readonly AppModel _model;
    private readonly FirestoreClient _database = new();
    private string? _userId;
    private string? _hostUid;
    private List<string> _localSegments = [];
    private string _localScriptTitle = "";
    private string _localVoiceName = "";
    private string? _activeExecutionTurnId;
    private bool _hasReportedPlaybackStart;
    private bool _isAdvancing;
    private bool _isPolling;
    private string? _lastRoomActivityMarker;
    private DateTime _lastCollectionSyncUtc = DateTime.MinValue;
    private OrchestrationSessionStatus _previousSessionStatus = OrchestrationSessionStatus.Lobby;
    private readonly DispatcherTimer _pollTimer;
    private readonly DispatcherTimer _heartbeatTimer;
    private CancellationTokenSource? _turnExecutionCancellation;
    private readonly HashSet<int> _preparedLocalSegments = [];
    private CancellationTokenSource? _prefetchCancellation;
    private Task? _prefetchTask;
    private int? _prefetchSegmentIndex;
    private string? _defaultVoicesAppliedForTemplateId;

    public OrchestrationController(AppModel model)
    {
        _model = model;
        _speakerName = string.IsNullOrWhiteSpace(model.Settings.OrchestrationSpeakerName)
            ? Environment.MachineName
            : model.Settings.OrchestrationSpeakerName;
        SpeakerConfigurations = LoadSpeakerConfigurations(OrchestratedMeetingTemplate.LaunchReadiness);
        if (model.Settings.OrchestratedMeetingSpeakers.ContainsKey(OrchestratedMeetingTemplate.LaunchReadiness.Id))
        {
            _defaultVoicesAppliedForTemplateId = OrchestratedMeetingTemplate.LaunchReadiness.Id;
        }

        _pollTimer = new DispatcherTimer { Interval = PollInterval };
        _pollTimer.Tick += async (_, _) => await PollAsync();
        _heartbeatTimer = new DispatcherTimer { Interval = HeartbeatInterval };
        _heartbeatTimer.Tick += async (_, _) => await SendHeartbeatAsync();

        _model.Player.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AudioPlaybackController.IsPlaying) && _model.Player.IsPlaying)
            {
                PlaybackDidStart();
            }
        };
        _model.Player.PlaybackFinished += PlaybackDidFinish;
    }

    public bool IsActive => ActiveMode is not null;
    public bool IsHost => ActiveMode == OrchestrationMode.Host;
    public string? LocalParticipantId => _userId;
    public int LocalAssignedSegmentCount => _localSegments.Count;

    public OrchestrationTurn? ActiveTurn =>
        ActiveTurnIndex >= 0 && ActiveTurnIndex < Turns.Count ? Turns[ActiveTurnIndex] : null;

    public bool CanStartMeeting
    {
        get
        {
            var connected = Participants.Where(p => p.IsRecentlyConnected).ToList();
            var assignedIds = Turns.Select(t => t.ParticipantUid).ToHashSet();
            return IsHost
                && SessionStatus == OrchestrationSessionStatus.Lobby
                && Turns.Count > 0
                && assignedIds.All(id => connected.FirstOrDefault(p => p.Id == id)?.IsFirstTurnPrepared == true)
                && !IsBusy;
        }
    }

    public bool CanPrepareMeeting =>
        IsHost
        && SessionStatus == OrchestrationSessionStatus.Lobby
        && Turns.Count == 0
        && Participants.Count(p => p.IsRecentlyConnected) >= SelectedTemplate.SpeakerCount
        && !IsBusy;

    public bool IsSpeakerConfigurationComplete =>
        SpeakerConfigurations.Count == SelectedTemplate.SpeakerCount
        && SpeakerConfigurations.All(configuration =>
            !string.IsNullOrWhiteSpace(configuration.Name)
            && !string.IsNullOrWhiteSpace(configuration.VoiceId));

    public string ConfiguredScriptPreview => SpeakerConfigurations.Aggregate(
        MeetingScriptText,
        (preview, configuration) => preview.Replace(
            configuration.Placeholder,
            string.IsNullOrWhiteSpace(configuration.Name) ? configuration.Placeholder : configuration.Name.Trim(),
            StringComparison.Ordinal));

    public void PrepareHostSetup()
    {
        SetupMode = OrchestrationMode.Host;
        ErrorMessage = null;
    }

    public void PrepareRemoteSetup()
    {
        SetupMode = OrchestrationMode.Remote;
        PairingCodeInput = "";
        ErrorMessage = null;
    }

    public void SelectTemplate(OrchestratedMeetingTemplate template)
    {
        if (IsActive || template.Id == SelectedTemplate.Id) return;
        SelectedTemplate = template;
        MeetingScriptText = template.Text;
        MeetingScriptTitle = template.Title;
        SpeakerConfigurations.Clear();
        SpeakerConfigurations.AddRange(LoadSpeakerConfigurations(template));
        _defaultVoicesAppliedForTemplateId = _model.Settings.OrchestratedMeetingSpeakers.ContainsKey(template.Id)
            ? template.Id
            : null;
        ApplyDefaultTemplateVoices();
        NotifySpeakerConfigurationChanged();
    }

    public void ApplyDefaultTemplateVoices()
    {
        if (_defaultVoicesAppliedForTemplateId == SelectedTemplate.Id || _model.Voices.Count == 0) return;
        var usedVoiceIds = new HashSet<string>(StringComparer.Ordinal);
        for (int index = 0; index < SpeakerConfigurations.Count; index++)
        {
            string? preferredGender = index < SelectedTemplate.DefaultVoiceGenders.Count
                ? SelectedTemplate.DefaultVoiceGenders[index]
                : null;
            var matchingUnused = _model.Voices.FirstOrDefault(voice =>
                preferredGender is not null
                && !usedVoiceIds.Contains(voice.Id)
                && string.Equals(voice.Labels?.GetValueOrDefault("gender"), preferredGender, StringComparison.OrdinalIgnoreCase));
            var matching = _model.Voices.FirstOrDefault(voice =>
                preferredGender is not null
                && string.Equals(voice.Labels?.GetValueOrDefault("gender"), preferredGender, StringComparison.OrdinalIgnoreCase));
            var fallback = _model.Voices.FirstOrDefault(voice => !usedVoiceIds.Contains(voice.Id)) ?? _model.Voices[0];
            var selectedVoice = matchingUnused ?? matching ?? fallback;
            SpeakerConfigurations[index].VoiceId = selectedVoice.Id;
            SpeakerConfigurations[index].VoiceName = selectedVoice.Name;
            usedVoiceIds.Add(selectedVoice.Id);
        }
        _defaultVoicesAppliedForTemplateId = SelectedTemplate.Id;
        PersistSpeakerConfigurations();
        NotifySpeakerConfigurationChanged();
    }

    public void UpdateSpeakerName(int slot, string name)
    {
        var configuration = SpeakerConfigurations.First(item => item.Slot == slot);
        configuration.Name = name.Trim();
        PersistSpeakerConfigurations();
        NotifySpeakerConfigurationChanged();
    }

    public void UpdateSpeakerVoice(int slot, string voiceId)
    {
        var configuration = SpeakerConfigurations.First(item => item.Slot == slot);
        configuration.VoiceId = voiceId;
        configuration.VoiceName = _model.Voices.FirstOrDefault(voice => voice.Id == voiceId)?.Name
            ?? $"Voice ID {voiceId[..Math.Min(8, voiceId.Length)]}…";
        PersistSpeakerConfigurations();
        NotifySpeakerConfigurationChanged();
    }

    private List<OrchestratedSpeakerConfiguration> LoadSpeakerConfigurations(OrchestratedMeetingTemplate template)
    {
        _model.Settings.OrchestratedMeetingSpeakers.TryGetValue(template.Id, out var saved);
        var savedBySlot = (saved ?? []).ToDictionary(item => item.Slot);
        return template.SpeakerRoles.Select((role, index) =>
        {
            int slot = index + 1;
            savedBySlot.TryGetValue(slot, out var preference);
            return new OrchestratedSpeakerConfiguration
            {
                Slot = slot,
                Role = role,
                Name = preference?.Name ?? "",
                VoiceId = preference?.VoiceId ?? _model.VoiceId,
                VoiceName = preference?.VoiceName ?? _model.SelectedVoiceName,
            };
        }).ToList();
    }

    private void PersistSpeakerConfigurations()
    {
        _model.Settings.OrchestratedMeetingSpeakers[SelectedTemplate.Id] = SpeakerConfigurations.Select(configuration =>
            new OrchestratedSpeakerPreference
            {
                Slot = configuration.Slot,
                Name = configuration.Name,
                VoiceId = configuration.VoiceId,
                VoiceName = configuration.VoiceName,
            }).ToList();
        _model.Settings.Save();
    }

    private void NotifySpeakerConfigurationChanged()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SpeakerConfigurations)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSpeakerConfigurationComplete)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ConfiguredScriptPreview)));
    }

    public bool CanExportTranscript =>
        IsHost
        && SessionStatus is OrchestrationSessionStatus.Completed or OrchestrationSessionStatus.Stopped
        && Turns.Count > 0;

    // Session lifecycle

    public async Task StartHostingAsync()
    {
        await PerformBusyOperationAsync(async () =>
        {
            var local = PrepareLocalSpeaker();
            var uid = await _database.EnsureSignedInAsync();
            _userId = uid;
            var roomId = Guid.NewGuid().ToString().ToLowerInvariant();
            var code = MakePairingCode();

            await _database.CommitAsync(new FirestoreWrite
            {
                DocumentPath = RoomPath(roomId),
                Fields = new()
                {
                    ["hostUID"] = uid,
                    ["pairingCode"] = code,
                    ["pairingOpen"] = true,
                    ["status"] = OrchestrationSessionStatus.Lobby.RawValue(),
                    ["activeTurnIndex"] = -1,
                    ["totalTurns"] = 0,
                    ["scriptTemplateID"] = SelectedTemplate.Id,
                    ["scriptTitle"] = SelectedTemplate.Title,
                    ["scriptText"] = MeetingScriptText,
                },
                ServerTimestampFields = ["createdAt", "updatedAt", "activityAt"],
                MustExist = false,
            });

            await _database.CommitAsync(new FirestoreWrite
            {
                DocumentPath = PairingPath(code),
                Fields = new()
                {
                    ["code"] = code,
                    ["roomID"] = roomId,
                    ["hostUID"] = uid,
                    ["isOpen"] = true,
                    ["expiresAt"] = DateTime.UtcNow + PairingLifetime,
                },
                ServerTimestampFields = ["createdAt"],
                MustExist = false,
            });

            await WriteLocalParticipantAsync(roomId, code, uid, local);
            ActivateSession(roomId, code, OrchestrationMode.Host, uid, local);
        });
    }

    public async Task JoinMeetingAsync()
    {
        await PerformBusyOperationAsync(async () =>
        {
            var local = PrepareLocalSpeaker();
            var uid = await _database.EnsureSignedInAsync();
            _userId = uid;
            var code = new string(PairingCodeInput.ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());
            if (code.Length != 6) throw new AppException("Enter the six-character pairing code.");

            var pairing = await _database.GetDocumentAsync(PairingPath(code));
            if (pairing is null
                || !pairing.Bool("isOpen")
                || pairing.String("roomID") is not string roomId
                || pairing.String("hostUID") is not string hostUid)
            {
                throw new AppException("That pairing code is not active.");
            }

            await WriteLocalParticipantAsync(roomId, code, uid, local);
            ActivateSession(roomId, code, OrchestrationMode.Remote, hostUid, local);
        });
    }

    public async Task SetPairingOpenAsync(bool isOpen)
    {
        if (!IsHost || SessionId is not string sessionId) return;
        await PerformBusyOperationAsync(() => _database.CommitAsync(
        [
            new FirestoreWrite
            {
                DocumentPath = RoomPath(sessionId),
                Fields = new() { ["pairingOpen"] = isOpen },
                UpdateMask = ["pairingOpen"],
                ServerTimestampFields = ["updatedAt", "activityAt"],
                MustExist = true,
            },
            new FirestoreWrite
            {
                DocumentPath = PairingPath(PairingCode),
                Fields = new() { ["isOpen"] = isOpen },
                UpdateMask = ["isOpen"],
                MustExist = true,
            },
        ]));
    }

    public void MoveParticipant(string id, int offset)
    {
        if (Turns.Count > 0) return;
        var order = new List<string>(ParticipantOrder);
        int source = order.IndexOf(id);
        if (source < 0) return;
        int destination = source + offset;
        if (destination < 0 || destination >= order.Count) return;
        (order[source], order[destination]) = (order[destination], order[source]);
        ParticipantOrder = order;
    }

    public async Task PrepareMeetingAsync()
    {
        if (!IsHost || SessionId is not string sessionId) return;
        await PerformBusyOperationAsync(async () =>
        {
            var template = SelectedTemplate;
            var parsedTurns = template.ParseTurns(MeetingScriptText);
            if (parsedTurns.Count > MaximumTurnCount)
            {
                throw new AppException(
                    $"This script has {parsedTurns.Count} turns. Shorten it to {MaximumTurnCount} turns or fewer.");
            }
            var connectedById = Participants.Where(p => p.IsRecentlyConnected).ToDictionary(p => p.Id);
            var assigned = ParticipantOrder
                .Where(connectedById.ContainsKey)
                .Select(id => connectedById[id])
                .Take(template.SpeakerCount)
                .ToList();
            if (assigned.Count < template.SpeakerCount)
            {
                throw new AppException($"Pair {template.SpeakerCount} speakers before preparing this meeting.");
            }
            if (!IsSpeakerConfigurationComplete)
            {
                throw new AppException("Configure all speaker names and voices in the main window first.");
            }

            var segmentCounts = new int[template.SpeakerCount];
            var writes = new List<FirestoreWrite>();
            for (int index = 0; index < parsedTurns.Count; index++)
            {
                var parsed = parsedTurns[index];
                var participant = assigned[parsed.SpeakerIndex];
                var speakerConfiguration = SpeakerConfigurations[parsed.SpeakerIndex];
                int segmentIndex = segmentCounts[parsed.SpeakerIndex]++;
                var resolvedText = parsed.Text;
                foreach (var configuration in SpeakerConfigurations)
                {
                    resolvedText = resolvedText.Replace(
                        configuration.Placeholder,
                        configuration.Name.Trim(),
                        StringComparison.Ordinal);
                }
                writes.Add(new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, index.ToString("00000")),
                    Fields = new()
                    {
                        ["index"] = index,
                        ["participantUID"] = participant.Id,
                        ["speakerName"] = speakerConfiguration.Name.Trim(),
                        ["speakerSlot"] = parsed.SpeakerIndex + 1,
                        ["voiceID"] = speakerConfiguration.VoiceId,
                        ["voiceName"] = speakerConfiguration.VoiceName,
                        ["scriptTitle"] = template.Title,
                        ["segmentIndex"] = segmentIndex,
                        ["text"] = resolvedText,
                        ["status"] = OrchestrationTurnStatus.Queued.RawValue(),
                    },
                    ServerTimestampFields = ["createdAt", "updatedAt"],
                });
            }
            for (int speakerIndex = 0; speakerIndex < assigned.Count; speakerIndex++)
            {
                var configuration = SpeakerConfigurations[speakerIndex];
                writes.Add(new FirestoreWrite
                {
                    DocumentPath = ParticipantPath(sessionId, assigned[speakerIndex].Id),
                    Fields = new()
                    {
                        ["displayName"] = configuration.Name.Trim(),
                        ["scriptTitle"] = template.Title,
                        ["voiceName"] = configuration.VoiceName,
                        ["segmentCount"] = segmentCounts[speakerIndex],
                        ["preparedSegmentCount"] = 0,
                        ["preparationError"] = "",
                        ["status"] = "preparing",
                    },
                    UpdateMask = ["displayName", "scriptTitle", "voiceName", "segmentCount", "preparedSegmentCount", "preparationError", "status"],
                    MustExist = true,
                });
            }
            writes.Add(new FirestoreWrite
            {
                DocumentPath = RoomPath(sessionId),
                Fields = new()
                {
                    ["scriptTemplateID"] = template.Id,
                    ["scriptTitle"] = template.Title,
                    ["scriptText"] = MeetingScriptText,
                    ["totalTurns"] = parsedTurns.Count,
                    ["orderedParticipantIDs"] = assigned.Select(p => p.Id).ToList(),
                    ["planRevision"] = Guid.NewGuid().ToString(),
                },
                UpdateMask = ["scriptTemplateID", "scriptTitle", "scriptText", "totalTurns", "orderedParticipantIDs", "planRevision"],
                ServerTimestampFields = ["updatedAt", "activityAt"],
                MustExist = true,
            });
            await _database.CommitAsync(writes);
            await PollAsync();
        });
    }

    public async Task StartMeetingAsync()
    {
        if (!IsHost || SessionId is not string sessionId) return;
        await PerformBusyOperationAsync(async () =>
        {
            if (Turns.Count == 0) throw new AppException("Prepare the orchestrated script first.");
            var connected = Participants.Where(p => p.IsRecentlyConnected).ToList();
            var assignedIds = Turns.Select(t => t.ParticipantUid).ToHashSet();
            if (!assignedIds.All(id => connected.FirstOrDefault(p => p.Id == id)?.IsFirstTurnPrepared == true))
            {
                throw new AppException("Wait until every assigned speaker has prepared a first turn.");
            }

            var writes = new List<FirestoreWrite>
            {
                new()
                {
                    DocumentPath = TurnPath(sessionId, Turns[0].Id),
                    Fields = new() { ["status"] = OrchestrationTurnStatus.Assigned.RawValue() },
                    UpdateMask = ["status"],
                    ServerTimestampFields = ["updatedAt"],
                    MustExist = true,
                },
            };
            writes.Add(new FirestoreWrite
            {
                DocumentPath = RoomPath(sessionId),
                Fields = new()
                {
                    ["status"] = OrchestrationSessionStatus.Running.RawValue(),
                    ["pairingOpen"] = false,
                    ["activeTurnIndex"] = 0,
                    ["totalTurns"] = Turns.Count,
                },
                UpdateMask = ["status", "pairingOpen", "activeTurnIndex", "totalTurns"],
                ServerTimestampFields = ["startedAt", "updatedAt", "activityAt"],
                MustExist = true,
            });
            writes.Add(new FirestoreWrite
            {
                DocumentPath = PairingPath(PairingCode),
                Fields = new() { ["isOpen"] = false },
                UpdateMask = ["isOpen"],
                MustExist = true,
            });
            await _database.CommitAsync(writes);
            await PollAsync();
        });
    }

    public async Task PauseMeetingAsync()
    {
        if (!IsHost || SessionId is not string sessionId || SessionStatus != OrchestrationSessionStatus.Running) return;
        await UpdateRoomStatusAsync(sessionId, OrchestrationSessionStatus.Paused);
    }

    public async Task ResumeMeetingAsync()
    {
        if (!IsHost || SessionId is not string sessionId || SessionStatus != OrchestrationSessionStatus.Paused) return;
        await UpdateRoomStatusAsync(sessionId, OrchestrationSessionStatus.Running);
    }

    public async Task SkipCurrentTurnAsync()
    {
        if (!IsHost || SessionId is not string sessionId) return;
        if (ActiveTurn is not OrchestrationTurn turn || turn.Status.IsTerminal()) return;
        await PerformBusyOperationAsync(async () =>
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, turn.Id),
                    Fields = new() { ["status"] = OrchestrationTurnStatus.Skipped.RawValue() },
                    UpdateMask = ["status"],
                    ServerTimestampFields = ["endedAtServer", "updatedAt"],
                    MustExist = true,
                },
                RoomActivityBump(sessionId),
            ]);
            await PollAsync();
        });
    }

    public async Task StopMeetingAsync()
    {
        if (!IsHost || SessionId is not string sessionId) return;
        await PerformBusyOperationAsync(async () =>
        {
            var writes = new List<FirestoreWrite>
            {
                new()
                {
                    DocumentPath = RoomPath(sessionId),
                    Fields = new()
                    {
                        ["status"] = OrchestrationSessionStatus.Stopped.RawValue(),
                        ["pairingOpen"] = false,
                    },
                    UpdateMask = ["status", "pairingOpen"],
                    ServerTimestampFields = ["endedAt", "updatedAt", "activityAt"],
                    MustExist = true,
                },
                new()
                {
                    DocumentPath = PairingPath(PairingCode),
                    Fields = new() { ["isOpen"] = false },
                    UpdateMask = ["isOpen"],
                    MustExist = true,
                },
            };
            if (ActiveTurn is OrchestrationTurn turn && !turn.Status.IsTerminal())
            {
                writes.Add(new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, turn.Id),
                    Fields = new() { ["status"] = OrchestrationTurnStatus.Stopped.RawValue() },
                    UpdateMask = ["status"],
                    ServerTimestampFields = ["endedAtServer", "updatedAt"],
                    MustExist = true,
                });
            }
            await _database.CommitAsync(writes);
            await PollAsync();
        });
    }

    public async Task LeaveSessionAsync()
    {
        if (SessionId is not string sessionId || _userId is not string uid)
        {
            ResetLocalSession();
            return;
        }

        if (IsHost && SessionStatus is OrchestrationSessionStatus.Running or OrchestrationSessionStatus.Paused)
        {
            await StopMeetingAsync();
        }
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = ParticipantPath(sessionId, uid),
                    Fields = new()
                    {
                        ["status"] = "left",
                        ["isConnected"] = false,
                    },
                    UpdateMask = ["status", "isConnected"],
                    ServerTimestampFields = ["lastSeenAt"],
                    MustExist = true,
                },
                RoomActivityBump(sessionId),
            ]);
            if (IsHost)
            {
                await _database.CommitAsync(new FirestoreWrite
                {
                    DocumentPath = PairingPath(PairingCode),
                    Fields = new() { ["isOpen"] = false },
                    UpdateMask = ["isOpen"],
                    MustExist = true,
                });
            }
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
        ResetLocalSession();
    }

    // Transcript export

    private sealed class Iso8601DateTimeConverter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.GetDateTime();

        // Swift's .iso8601 encoding strategy: whole seconds, UTC.
        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }

    public string BuildTranscriptJson()
    {
        if (SessionId is not string sessionId) throw new AppException("There is no meeting to export.");
        var participantById = Participants.ToDictionary(p => p.Id);
        var speakers = Participants
            .Select(p => new OrchestrationTranscript.Speaker(p.Id, p.DisplayName, p.ScriptTitle, p.VoiceName))
            .ToList();
        var exportedTurns = Turns.Select(turn =>
        {
            var start = turn.StartedAtClient ?? turn.StartedAtServer;
            var end = turn.EndedAtClient ?? turn.EndedAtServer;
            int? duration = start is DateTime s && end is DateTime e
                ? Math.Max((int)(e - s).TotalMilliseconds, 0)
                : null;
            return new OrchestrationTranscript.Turn(
                turn.Index,
                turn.ParticipantUid,
                participantById.GetValueOrDefault(turn.ParticipantUid)?.DisplayName ?? turn.SpeakerName,
                turn.ScriptTitle,
                turn.SpeakerSlot,
                turn.SegmentIndex,
                turn.Text,
                turn.Status.RawValue(),
                start,
                end,
                turn.StartedAtServer,
                turn.EndedAtServer,
                duration,
                turn.Error);
        }).ToList();
        var transcript = new OrchestrationTranscript(
            2, sessionId, PairingCode, SessionStatus.RawValue(), StartedAt, EndedAt, DateTime.UtcNow,
            speakers, exportedTurns);
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Converters = { new Iso8601DateTimeConverter() },
        };
        return JsonSerializer.Serialize(transcript, options);
    }

    public void ExportTranscript()
    {
        var json = BuildTranscriptJson();
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "JSON files (*.json)|*.json",
            FileName = $"BotSpeaker-{PairingCode}-transcript.json",
        };
        if (dialog.ShowDialog() != true) return;
        File.WriteAllText(dialog.FileName, json);
    }

    // Local speaker preparation

    private sealed record LocalSpeaker(string Name, string VoiceName);

    private LocalSpeaker PrepareLocalSpeaker()
    {
        if (!_model.HasApiKey) throw new AppException("Add an ElevenLabs API key before pairing this PC.");
        var name = SpeakerName.Trim();
        if (name.Length == 0) throw new AppException("Enter this speaker's name.");
        _model.Settings.OrchestrationSpeakerName = name;
        _model.Settings.Save();
        return new LocalSpeaker(name, _model.SelectedVoiceName);
    }

    private async Task WriteLocalParticipantAsync(string roomId, string code, string uid, LocalSpeaker local)
    {
        var fields = new Dictionary<string, object?>
        {
            ["uid"] = uid,
            ["roomID"] = roomId,
            ["pairingCode"] = code,
            ["displayName"] = local.Name,
            ["scriptTitle"] = "Waiting for host script",
            ["voiceName"] = local.VoiceName,
            ["segmentCount"] = 0,
            ["preparedSegmentCount"] = 0,
            ["preparationError"] = "",
            ["status"] = "waiting",
            ["isConnected"] = true,
        };
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = ParticipantPath(roomId, uid),
                    Fields = fields,
                    ServerTimestampFields = ["joinedAt", "lastSeenAt"],
                    MustExist = false,
                },
                RoomActivityBump(roomId),
            ]);
        }
        catch (AppException)
        {
            // Rejoining with the same identity: the create precondition fails, so
            // refresh only the fields the update rule allows a participant to change.
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = ParticipantPath(roomId, uid),
                    Fields = new()
                    {
                        ["displayName"] = local.Name,
                        ["scriptTitle"] = "Waiting for host script",
                        ["voiceName"] = local.VoiceName,
                        ["segmentCount"] = 0,
                        ["preparedSegmentCount"] = 0,
                        ["preparationError"] = "",
                        ["status"] = "waiting",
                        ["isConnected"] = true,
                    },
                    UpdateMask = ["displayName", "scriptTitle", "voiceName", "segmentCount", "preparedSegmentCount", "preparationError", "status", "isConnected"],
                    ServerTimestampFields = ["lastSeenAt"],
                    MustExist = true,
                },
                RoomActivityBump(roomId),
            ]);
        }
    }

    private void ActivateSession(string roomId, string code, OrchestrationMode mode, string hostUid, LocalSpeaker local)
    {
        ActiveMode = mode;
        SessionId = roomId;
        PairingCode = code;
        PairingCodeInput = code;
        _hostUid = hostUid;
        _localSegments = [];
        _localScriptTitle = MeetingScriptTitle;
        _localVoiceName = local.VoiceName;
        _preparedLocalSegments.Clear();
        PreparedLocalSegmentCount = 0;
        PreparationStatus = "Waiting for the host script";
        PreparationError = null;
        ParticipantOrder = [];
        SessionStatus = OrchestrationSessionStatus.Lobby;
        _previousSessionStatus = OrchestrationSessionStatus.Lobby;
        PairingOpen = true;
        ErrorMessage = null;
        _model.ActivateRemoteControl("Paired and waiting for the host");
        _lastRoomActivityMarker = null;
        _lastCollectionSyncUtc = DateTime.MinValue;
        BeginOrchestrationActivity();
        _pollTimer.Start();
        _heartbeatTimer.Start();
        _ = PollAsync();
    }

    // Polling — the Windows analog of the macOS snapshot listeners. Every state-
    // changing commit on either platform also touches the room's activityAt
    // marker, so each tick costs one room read; the participant and turn
    // collections are re-listed only when the marker moves (or on a slow resync
    // that keeps heartbeat freshness visible), not on every tick. Firestore
    // bills a read per document returned, and re-listing a long meeting's turns
    // 40 times a minute is what exhausted the project's read quota.

    private async Task PollAsync()
    {
        if (_isPolling || SessionId is not string sessionId) return;
        _isPolling = true;
        try
        {
            var room = await _database.GetDocumentAsync(RoomPath(sessionId));
            if (SessionId != sessionId) return;
            bool syncCollections = true;
            if (room is not null)
            {
                var marker = room.Timestamp("activityAt")?.Ticks.ToString();
                syncCollections = marker != _lastRoomActivityMarker
                    || DateTime.UtcNow - _lastCollectionSyncUtc >= CollectionResyncInterval;
                _lastRoomActivityMarker = marker;
                ApplyRoom(room);
            }
            if (!syncCollections) return;

            var participants = await _database.ListDocumentsAsync($"{RoomPath(sessionId)}/participants");
            if (SessionId != sessionId) return;
            ApplyParticipants(participants);

            var turns = await _database.ListDocumentsAsync($"{RoomPath(sessionId)}/turns");
            if (SessionId != sessionId) return;
            ApplyTurns(turns);
            _lastCollectionSyncUtc = DateTime.UtcNow;
        }
        catch (Exception error) when (error is AppException or System.Net.Http.HttpRequestException)
        {
            ErrorMessage = error.Message;
        }
        finally
        {
            _isPolling = false;
        }
    }

    /// <summary>
    /// A field-transform-only room write: touches activityAt without changing
    /// any other field, which is the one room update the security rules allow
    /// participants to make. Included in every state-changing batch so pollers
    /// notice the change on their next room read.
    /// </summary>
    private static FirestoreWrite RoomActivityBump(string roomId) => new()
    {
        DocumentPath = RoomPath(roomId),
        UpdateMask = [],
        ServerTimestampFields = ["activityAt"],
        MustExist = true,
    };

    private void ApplyRoom(FirestoreDocument room)
    {
        _previousSessionStatus = SessionStatus;
        SessionStatus = OrchestrationSessionStatusExtensions.SessionStatusFromRaw(room.String("status"));
        PairingOpen = room.Bool("pairingOpen");
        ActiveTurnIndex = room.Int("activeTurnIndex", -1);
        StartedAt = room.Timestamp("startedAt");
        EndedAt = room.Timestamp("endedAt");
        MeetingScriptTitle = room.String("scriptTitle") ?? MeetingScriptTitle;
        if (!IsHost && room.String("scriptText") is string scriptText) MeetingScriptText = scriptText;

        switch (SessionStatus)
        {
            case OrchestrationSessionStatus.Lobby:
                _model.UpdateRemoteControlStatus("Paired and waiting for the host");
                break;
            case OrchestrationSessionStatus.Running:
                _model.UpdateRemoteControlStatus("Remote control active");
                if (_previousSessionStatus == OrchestrationSessionStatus.Paused
                    && ActiveTurn?.ParticipantUid == _userId)
                {
                    _model.ResumeOrchestratedTurn();
                }
                break;
            case OrchestrationSessionStatus.Paused:
                _model.UpdateRemoteControlStatus("Paused by the host");
                if (ActiveTurn?.ParticipantUid == _userId)
                {
                    _model.PauseOrchestratedTurn();
                }
                break;
            case OrchestrationSessionStatus.Completed:
                CancelPrefetch();
                EndOrchestrationActivity();
                _model.UpdateRemoteControlStatus("Meeting completed");
                break;
            case OrchestrationSessionStatus.Stopped:
                CancelPrefetch();
                EndOrchestrationActivity();
                _model.UpdateRemoteControlStatus("Meeting stopped by the host");
                _turnExecutionCancellation?.Cancel();
                _turnExecutionCancellation = null;
                _activeExecutionTurnId = null;
                _hasReportedPlaybackStart = false;
                _model.StopOrchestratedTurn();
                break;
        }
        MaybeExecuteActiveTurn();
    }

    private void ApplyParticipants(List<FirestoreDocument> documents)
    {
        var participants = documents
            .Where(d => d.String("displayName") is not null && d.String("scriptTitle") is not null)
            .Select(d => new OrchestrationParticipant(
                d.Id,
                d.String("displayName")!,
                d.String("scriptTitle")!,
                d.String("voiceName") ?? "Unknown voice",
                d.Int("segmentCount"),
                d.Int("preparedSegmentCount"),
                d.String("preparationError"),
                d.String("status") ?? "unknown",
                d.Bool("isConnected"),
                d.Timestamp("lastSeenAt"),
                d.Timestamp("joinedAt")))
            .OrderBy(p => p.JoinedAt ?? DateTime.MaxValue)
            .ToList();
        // Records compare by value, so unchanged polls don't churn the UI.
        if (!participants.SequenceEqual(Participants)) Participants = participants;

        var validIds = Participants.Select(p => p.Id).ToHashSet();
        var order = ParticipantOrder.Where(validIds.Contains).ToList();
        foreach (var participant in Participants)
        {
            if (!order.Contains(participant.Id)) order.Add(participant.Id);
        }
        if (!order.SequenceEqual(ParticipantOrder)) ParticipantOrder = order;
    }

    private void ApplyTurns(List<FirestoreDocument> documents)
    {
        var turns = documents
            .Select(d =>
            {
                var status = OrchestrationTurnStatusExtensions.TurnStatusFromRaw(d.String("status"));
                if (d.String("participantUID") is not string participantUid || status is null) return null;
                return new OrchestrationTurn(
                    d.Id,
                    d.Int("index"),
                    participantUid,
                    d.String("speakerName") ?? "Speaker",
                    d.String("scriptTitle") ?? "Script",
                    d.Int("speakerSlot"),
                    d.String("voiceID"),
                    d.String("voiceName"),
                    d.Int("segmentIndex"),
                    status.Value,
                    d.String("text"),
                    d.Timestamp("startedAtClient"),
                    d.Timestamp("startedAtServer"),
                    d.Timestamp("endedAtClient"),
                    d.Timestamp("endedAtServer"),
                    d.String("error"));
            })
            .Where(t => t is not null)
            .Select(t => t!)
            .OrderBy(t => t.Index)
            .ToList();
        if (!turns.SequenceEqual(Turns)) Turns = turns;
        ConfigureLocalSegmentsFromTurns();

        if (_activeExecutionTurnId is string executionTurnId
            && Turns.FirstOrDefault(t => t.Id == executionTurnId) is OrchestrationTurn executionTurn
            && executionTurn.Status.IsTerminal())
        {
            _turnExecutionCancellation?.Cancel();
            _turnExecutionCancellation = null;
            _activeExecutionTurnId = null;
            _hasReportedPlaybackStart = false;
            _model.StopOrchestratedTurn();
            _model.UpdateRemoteControlStatus(executionTurn.Status == OrchestrationTurnStatus.Skipped
                ? "Turn skipped by the host"
                : "Turn ended; waiting for the host");
        }
        MaybeExecuteActiveTurn();
        ScheduleNextPrefetch();
        if (IsHost && ActiveTurn is OrchestrationTurn active && active.Status.IsTerminal())
        {
            _ = AdvanceAfterTerminalTurnAsync(active);
        }
    }

    private void ConfigureLocalSegmentsFromTurns()
    {
        if (_userId is not string uid) return;
        var assignedTurns = Turns
            .Where(turn => turn.ParticipantUid == uid)
            .OrderBy(turn => turn.SegmentIndex)
            .ToList();
        if (assignedTurns.Count == 0 || assignedTurns.Any(turn => string.IsNullOrEmpty(turn.Text))) return;
        var segments = assignedTurns.Select(turn => turn.Text!).ToList();
        if (segments.SequenceEqual(_localSegments)) return;

        CancelPrefetch();
        _localSegments = segments;
        _localScriptTitle = assignedTurns[0].ScriptTitle;
        if (!string.IsNullOrWhiteSpace(assignedTurns[0].VoiceId))
        {
            _model.VoiceId = assignedTurns[0].VoiceId!;
        }
        _localVoiceName = assignedTurns[0].VoiceName ?? _model.SelectedVoiceName;
        _preparedLocalSegments.Clear();
        PreparedLocalSegmentCount = 0;
        PreparationError = null;
        PreparationStatus = "Preparing first assigned turn…";
        ScheduleNextPrefetch();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LocalAssignedSegmentCount)));
    }

    // Turn execution on this machine

    private void MaybeExecuteActiveTurn()
    {
        if (SessionStatus != OrchestrationSessionStatus.Running
            || _userId is not string uid
            || ActiveTurn is not OrchestrationTurn turn
            || turn.ParticipantUid != uid
            || turn.Status != OrchestrationTurnStatus.Assigned
            || _activeExecutionTurnId == turn.Id
            || turn.SegmentIndex < 0
            || turn.SegmentIndex >= _localSegments.Count
            || SessionId is not string sessionId)
        {
            return;
        }

        _activeExecutionTurnId = turn.Id;
        _hasReportedPlaybackStart = false;
        var text = _localSegments[turn.SegmentIndex];
        _model.UpdateRemoteControlStatus($"Preparing turn {turn.Index + 1} of {Turns.Count}");

        _turnExecutionCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _turnExecutionCancellation = cancellation;
        _ = ExecuteTurnAsync(sessionId, turn, text, cancellation);
    }

    private async Task ExecuteTurnAsync(
        string sessionId, OrchestrationTurn turn, string text, CancellationTokenSource cancellation)
    {
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, turn.Id),
                    Fields = new()
                    {
                        ["status"] = OrchestrationTurnStatus.Preparing.RawValue(),
                        ["text"] = text,
                    },
                    UpdateMask = ["status", "text"],
                    ServerTimestampFields = ["updatedAt"],
                    MustExist = true,
                },
                RoomActivityBump(sessionId),
            ], cancellation.Token);
            await WriteEventAsync(sessionId, turn.Id, "preparing", cancellation: cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            await EnsureLocalSegmentPreparedAsync(turn.SegmentIndex, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            await _model.PlayOrchestratedTurnAsync(
                text,
                CacheNamespace(turn.SegmentIndex),
                cancellation.Token);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            await ReportTurnFailureAsync(turn.Id, error.Message);
        }
        finally
        {
            if (_turnExecutionCancellation == cancellation) _turnExecutionCancellation = null;
        }
    }

    /// <summary>
    /// Makes paragraph zero ready in the lobby and immediately begins the next,
    /// then keeps one local paragraph ahead of this speaker's most recently
    /// finished turn. Cache preparation never
    /// loads the player, so it cannot speak before the host assigns the turn.
    /// </summary>
    private void ScheduleNextPrefetch()
    {
        if (!IsActive || _localSegments.Count == 0 || _prefetchTask is { IsCompleted: false }) return;

        int lookaheadLimit;
        if (SessionStatus == OrchestrationSessionStatus.Lobby || Turns.Count == 0)
        {
            lookaheadLimit = Math.Min(1, _localSegments.Count - 1);
        }
        else
        {
            int mostRecentTerminal = Turns
                .Where(t => t.ParticipantUid == _userId && t.Status.IsTerminal())
                .Select(t => t.SegmentIndex)
                .DefaultIfEmpty(-1)
                .Max();
            lookaheadLimit = Math.Min(mostRecentTerminal + 2, _localSegments.Count - 1);
        }

        int? candidate = Enumerable.Range(0, lookaheadLimit + 1)
            .Select(value => (int?)value)
            .FirstOrDefault(index => index is int value && !_preparedLocalSegments.Contains(value));
        if (candidate is not int segmentIndex) return;

        PreparationError = null;
        PreparationStatus = segmentIndex == 0
            ? "Preparing first turn…"
            : $"Preloading paragraph {segmentIndex + 1}…";
        if (SessionStatus == OrchestrationSessionStatus.Lobby)
        {
            _model.UpdateRemoteControlStatus(PreparationStatus);
        }

        var cancellation = new CancellationTokenSource();
        _prefetchCancellation = cancellation;
        _prefetchSegmentIndex = segmentIndex;
        _prefetchTask = RunBackgroundPrefetchAsync(segmentIndex, cancellation);
    }

    private async Task RunBackgroundPrefetchAsync(int segmentIndex, CancellationTokenSource cancellation)
    {
        // Let ScheduleNextPrefetch store the task before a cache hit can finish.
        await Task.Yield();
        bool shouldRetry = false;
        try
        {
            await PrepareSegmentCoreAsync(segmentIndex, cancellation.Token);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            shouldRetry = true;
            PreparationError = error.Message;
            PreparationStatus = "Preparation failed; retrying…";
            try { await PublishPreparationStateAsync(error.Message, CancellationToken.None); }
            catch (Exception publishError) { ErrorMessage = publishError.Message; }
        }

        if (shouldRetry)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(12), cancellation.Token); }
            catch (OperationCanceledException) { }
        }

        if (_prefetchCancellation == cancellation)
        {
            _prefetchCancellation = null;
            _prefetchTask = null;
            _prefetchSegmentIndex = null;
            if (!cancellation.IsCancellationRequested && IsActive) ScheduleNextPrefetch();
        }
        cancellation.Dispose();
    }

    private async Task EnsureLocalSegmentPreparedAsync(int segmentIndex, CancellationToken cancellation)
    {
        if (segmentIndex < 0 || segmentIndex >= _localSegments.Count)
        {
            throw new AppException("The assigned paragraph is unavailable on this PC.");
        }
        if (_preparedLocalSegments.Contains(segmentIndex)) return;

        if (_prefetchSegmentIndex == segmentIndex && _prefetchTask is Task existing)
        {
            await existing.WaitAsync(cancellation);
            if (_preparedLocalSegments.Contains(segmentIndex)) return;
        }

        CancelPrefetch();
        PreparationStatus = $"Preparing paragraph {segmentIndex + 1}…";
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        _prefetchCancellation = linked;
        _prefetchSegmentIndex = segmentIndex;
        var task = PrepareSegmentCoreAsync(segmentIndex, linked.Token);
        _prefetchTask = task;
        try
        {
            await task;
        }
        finally
        {
            if (_prefetchCancellation == linked)
            {
                _prefetchCancellation = null;
                _prefetchTask = null;
                _prefetchSegmentIndex = null;
            }
        }
        ScheduleNextPrefetch();
    }

    private async Task PrepareSegmentCoreAsync(int segmentIndex, CancellationToken cancellation)
    {
        await _model.PrepareOrchestratedTurnAsync(
            _localSegments[segmentIndex], CacheNamespace(segmentIndex), cancellation);
        cancellation.ThrowIfCancellationRequested();
        _preparedLocalSegments.Add(segmentIndex);

        int contiguousCount = 0;
        while (_preparedLocalSegments.Contains(contiguousCount)) contiguousCount++;
        PreparedLocalSegmentCount = contiguousCount;
        PreparationError = null;
        PreparationStatus = contiguousCount == _localSegments.Count
            ? "All paragraphs prepared"
            : $"{contiguousCount} paragraph{(contiguousCount == 1 ? "" : "s")} prepared";
        if (SessionStatus == OrchestrationSessionStatus.Lobby)
        {
            _model.UpdateRemoteControlStatus(contiguousCount > 0
                ? "First turn ready; waiting for the host"
                : PreparationStatus);
        }
        try
        {
            await PublishPreparationStateAsync(null, cancellation);
        }
        catch (Exception error) when (error is AppException or System.Net.Http.HttpRequestException)
        {
            // Audio is ready locally. The heartbeat republishes readiness if
            // this transient metadata write failed.
            ErrorMessage = error.Message;
        }
    }

    private async Task PublishPreparationStateAsync(string? error, CancellationToken cancellation)
    {
        if (SessionId is not string sessionId || _userId is not string uid) return;
        await _database.CommitAsync(
        [
            new FirestoreWrite
            {
                DocumentPath = ParticipantPath(sessionId, uid),
                Fields = new()
                {
                    ["scriptTitle"] = _localScriptTitle,
                    ["segmentCount"] = _localSegments.Count,
                    ["preparedSegmentCount"] = PreparedLocalSegmentCount,
                    ["preparationError"] = error ?? "",
                    ["status"] = _localSegments.Count == 0
                        ? "waiting"
                        : PreparedLocalSegmentCount > 0 ? "ready" : "preparing",
                },
                UpdateMask = ["scriptTitle", "segmentCount", "preparedSegmentCount", "preparationError", "status"],
                ServerTimestampFields = ["lastSeenAt"],
                MustExist = true,
            },
            RoomActivityBump(sessionId),
        ], cancellation);
    }

    private string CacheNamespace(int segmentIndex) =>
        $"orchestration:{_localScriptTitle}:{segmentIndex}";

    private void CancelPrefetch()
    {
        var cancellation = _prefetchCancellation;
        _prefetchCancellation = null;
        _prefetchTask = null;
        _prefetchSegmentIndex = null;
        cancellation?.Cancel();
    }

    private void PlaybackDidStart()
    {
        if (_activeExecutionTurnId is not string turnId
            || _hasReportedPlaybackStart
            || SessionId is not string sessionId)
        {
            return;
        }
        _hasReportedPlaybackStart = true;
        _model.UpdateRemoteControlStatus("Speaking now");
        var clientTime = DateTime.UtcNow;
        _ = ReportPlaybackStartAsync(sessionId, turnId, clientTime);
    }

    private async Task ReportPlaybackStartAsync(string sessionId, string turnId, DateTime clientTime)
    {
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, turnId),
                    Fields = new()
                    {
                        ["status"] = OrchestrationTurnStatus.Speaking.RawValue(),
                        ["startedAtClient"] = clientTime,
                    },
                    UpdateMask = ["status", "startedAtClient"],
                    ServerTimestampFields = ["startedAtServer", "updatedAt"],
                    MustExist = true,
                },
                RoomActivityBump(sessionId),
            ]);
            await WriteEventAsync(sessionId, turnId, "started", clientTime);
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
    }

    private void PlaybackDidFinish()
    {
        if (_activeExecutionTurnId is not string turnId
            || SessionId is not string sessionId
            || !_hasReportedPlaybackStart)
        {
            return;
        }
        _activeExecutionTurnId = null;
        _hasReportedPlaybackStart = false;
        _model.UpdateRemoteControlStatus("Turn complete; waiting for the host");
        var clientTime = DateTime.UtcNow;
        _ = ReportPlaybackFinishAsync(sessionId, turnId, clientTime);
    }

    private async Task ReportPlaybackFinishAsync(string sessionId, string turnId, DateTime clientTime)
    {
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, turnId),
                    Fields = new()
                    {
                        ["status"] = OrchestrationTurnStatus.Completed.RawValue(),
                        ["endedAtClient"] = clientTime,
                    },
                    UpdateMask = ["status", "endedAtClient"],
                    ServerTimestampFields = ["endedAtServer", "updatedAt"],
                    MustExist = true,
                },
                EventWrite(sessionId, turnId, "completed", clientTime),
                RoomActivityBump(sessionId),
            ]);
            await PollAsync();
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
    }

    private async Task ReportTurnFailureAsync(string turnId, string message)
    {
        if (SessionId is not string sessionId) return;
        _activeExecutionTurnId = null;
        _hasReportedPlaybackStart = false;
        try
        {
            await _database.CommitAsync(
            [
                new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, turnId),
                    Fields = new()
                    {
                        ["status"] = OrchestrationTurnStatus.Failed.RawValue(),
                        ["error"] = message,
                        ["endedAtClient"] = DateTime.UtcNow,
                    },
                    UpdateMask = ["status", "error", "endedAtClient"],
                    ServerTimestampFields = ["endedAtServer", "updatedAt"],
                    MustExist = true,
                },
                RoomActivityBump(sessionId),
            ]);
            await WriteEventAsync(sessionId, turnId, "failed", error: message);
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
    }

    private async Task AdvanceAfterTerminalTurnAsync(OrchestrationTurn terminalTurn)
    {
        if (_isAdvancing
            || SessionId is not string sessionId
            || terminalTurn.Index != ActiveTurnIndex)
        {
            return;
        }
        _isAdvancing = true;
        try
        {
            int nextIndex = terminalTurn.Index + 1;
            var writes = new List<FirestoreWrite>();
            if (nextIndex < Turns.Count)
            {
                writes.Add(new FirestoreWrite
                {
                    DocumentPath = TurnPath(sessionId, Turns[nextIndex].Id),
                    Fields = new() { ["status"] = OrchestrationTurnStatus.Assigned.RawValue() },
                    UpdateMask = ["status"],
                    ServerTimestampFields = ["updatedAt"],
                    MustExist = true,
                });
                writes.Add(new FirestoreWrite
                {
                    DocumentPath = RoomPath(sessionId),
                    Fields = new() { ["activeTurnIndex"] = nextIndex },
                    UpdateMask = ["activeTurnIndex"],
                    ServerTimestampFields = ["updatedAt", "activityAt"],
                    MustExist = true,
                });
            }
            else
            {
                writes.Add(new FirestoreWrite
                {
                    DocumentPath = RoomPath(sessionId),
                    Fields = new()
                    {
                        ["status"] = OrchestrationSessionStatus.Completed.RawValue(),
                        ["activeTurnIndex"] = Turns.Count,
                    },
                    UpdateMask = ["status", "activeTurnIndex"],
                    ServerTimestampFields = ["endedAt", "updatedAt", "activityAt"],
                    MustExist = true,
                });
            }
            await _database.CommitAsync(writes);
            await PollAsync();
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
        finally
        {
            _isAdvancing = false;
        }
    }

    // Firestore helpers

    private FirestoreWrite EventWrite(string sessionId, string turnId, string type, DateTime clientTime, string? error = null)
    {
        var fields = new Dictionary<string, object?>
        {
            ["type"] = type,
            ["participantUID"] = _userId ?? "",
            ["clientTimestamp"] = clientTime,
        };
        if (error is not null) fields["error"] = error;
        return new FirestoreWrite
        {
            DocumentPath = $"{TurnPath(sessionId, turnId)}/events/{Guid.NewGuid():N}",
            Fields = fields,
            ServerTimestampFields = ["timestamp"],
            MustExist = false,
        };
    }

    private Task WriteEventAsync(
        string sessionId,
        string turnId,
        string type,
        DateTime? clientTime = null,
        string? error = null,
        CancellationToken cancellation = default) =>
        _database.CommitAsync(EventWrite(sessionId, turnId, type, clientTime ?? DateTime.UtcNow, error), cancellation);

    private async Task UpdateRoomStatusAsync(string sessionId, OrchestrationSessionStatus status)
    {
        await PerformBusyOperationAsync(async () =>
        {
            await _database.CommitAsync(new FirestoreWrite
            {
                DocumentPath = RoomPath(sessionId),
                Fields = new() { ["status"] = status.RawValue() },
                UpdateMask = ["status"],
                ServerTimestampFields = ["updatedAt", "activityAt"],
                MustExist = true,
            });
            await PollAsync();
        });
    }

    private async Task SendHeartbeatAsync()
    {
        if (SessionId is not string sessionId || _userId is not string uid) return;
        try
        {
            await _database.CommitAsync(new FirestoreWrite
            {
                DocumentPath = ParticipantPath(sessionId, uid),
                Fields = new()
                {
                    ["status"] = PreparedLocalSegmentCount > 0 ? "ready" : "preparing",
                    ["preparedSegmentCount"] = PreparedLocalSegmentCount,
                    ["preparationError"] = PreparationError ?? "",
                    ["isConnected"] = true,
                },
                UpdateMask = ["status", "preparedSegmentCount", "preparationError", "isConnected"],
                ServerTimestampFields = ["lastSeenAt"],
                MustExist = true,
            });
        }
        catch (Exception)
        {
            // A missed heartbeat only ages the connection indicator; the next tick retries.
        }
    }

    /// A paired follower must keep polling Firestore and preparing speech while
    /// every window is hidden or minimised. Windows throttles the execution
    /// speed of such processes (EcoQoS), which is the counterpart of macOS App
    /// Nap, so opt this process out for the duration of the meeting.
    private void BeginOrchestrationActivity() => SetHighQosOverride(enabled: true);

    private void EndOrchestrationActivity() => SetHighQosOverride(enabled: false);

    private static void SetHighQosOverride(bool enabled)
    {
        var state = new ProcessPowerThrottlingState
        {
            Version = ProcessPowerThrottlingCurrentVersion,
            // Taking control with a zero StateMask disables execution-speed
            // throttling (HighQoS). A zero ControlMask returns policy control
            // to Windows when the paired session ends.
            ControlMask = enabled ? ProcessPowerThrottlingExecutionSpeed : 0,
            StateMask = 0,
        };
        try
        {
            SetProcessInformation(
                GetCurrentProcess(),
                ProcessPowerThrottlingInformation,
                ref state,
                Marshal.SizeOf<ProcessPowerThrottlingState>());
        }
        catch (EntryPointNotFoundException)
        {
            // Older Windows builds do not throttle background processes this way.
        }
    }

    private const int ProcessPowerThrottlingInformation = 4;
    private const uint ProcessPowerThrottlingCurrentVersion = 1;
    private const uint ProcessPowerThrottlingExecutionSpeed = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessPowerThrottlingState
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessInformation(
        nint process,
        int informationClass,
        ref ProcessPowerThrottlingState information,
        int informationSize);

    private async Task PerformBusyOperationAsync(Func<Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        ErrorMessage = null;
        try
        {
            await operation();
        }
        catch (Exception error)
        {
            ErrorMessage = error.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void ResetLocalSession()
    {
        _pollTimer.Stop();
        _heartbeatTimer.Stop();
        EndOrchestrationActivity();
        _model.DeactivateRemoteControl();
        ActiveMode = null;
        SessionId = null;
        PairingCode = "";
        SessionStatus = OrchestrationSessionStatus.Lobby;
        _previousSessionStatus = OrchestrationSessionStatus.Lobby;
        PairingOpen = false;
        Participants = [];
        ParticipantOrder = [];
        Turns = [];
        ActiveTurnIndex = -1;
        StartedAt = null;
        EndedAt = null;
        _localSegments = [];
        CancelPrefetch();
        _preparedLocalSegments.Clear();
        PreparedLocalSegmentCount = 0;
        PreparationStatus = "Not prepared";
        PreparationError = null;
        _turnExecutionCancellation?.Cancel();
        _turnExecutionCancellation = null;
        _activeExecutionTurnId = null;
        _hasReportedPlaybackStart = false;
        _lastRoomActivityMarker = null;
        _lastCollectionSyncUtc = DateTime.MinValue;
    }

    private static string RoomPath(string roomId) => $"orchestrationRooms/{roomId}";
    private static string PairingPath(string code) => $"orchestrationPairings/{code}";
    private static string ParticipantPath(string roomId, string uid) => $"{RoomPath(roomId)}/participants/{uid}";
    private static string TurnPath(string roomId, string turnId) => $"{RoomPath(roomId)}/turns/{turnId}";

    private static string MakePairingCode()
    {
        const string alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
        return new string(Enumerable.Range(0, 6).Select(_ => alphabet[Random.Shared.Next(alphabet.Length)]).ToArray());
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
