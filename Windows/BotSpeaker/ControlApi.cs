using System.IO;
using System.Text.Json.Nodes;

namespace BotSpeaker;

/// <summary>
/// Routes control-server requests to the app model and orchestration
/// controller — the Windows counterpart of the macOS ControlAPI. Paths,
/// bodies, and payload shapes match the macOS app exactly so one CLI (or one
/// agent skill) drives both platforms.
/// </summary>
public sealed class ControlApi
{
    private readonly AppModel _model;
    private readonly OrchestrationController _orchestration;
    private readonly string _version;

    /// <summary>Uploaded audio files are staged here so they outlive the HTTP request.</summary>
    public static string AudioDirectory => Path.Combine(ControlServer.DiscoveryDirectory, "adhoc-audio");

    private const int MaximumAudioBytes = 48 * 1024 * 1024;
    private static readonly HashSet<string> AudioExtensions =
        new(["mp3", "wav", "m4a", "aac", "aiff", "aif", "wma", "flac", "ogg", "opus"], StringComparer.OrdinalIgnoreCase);

    private sealed class ControlError(int status, string message, string code) : Exception(message)
    {
        public int Status { get; } = status;
        public string Code { get; } = code;
    }

    public ControlApi(AppModel model, OrchestrationController orchestration, string version)
    {
        _model = model;
        _orchestration = orchestration;
        _version = version;
        // Anything left over belongs to a request from a previous launch.
        try { if (Directory.Exists(AudioDirectory)) Directory.Delete(AudioDirectory, recursive: true); }
        catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public async Task<ControlServer.Response> HandleAsync(ControlServer.Request request)
    {
        var segments = request.Path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0 || segments[0] != "v1")
        {
            return ControlServer.Response.Error(404, $"Unknown path {request.Path}. All routes live under /v1.", "not_found");
        }
        var route = segments[1..];
        try
        {
            switch (request.Method, route)
            {
                case ("GET", ["status"]):
                    return ControlServer.Response.Ok(StatusPayload());
                case ("GET", ["targets"]):
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["targets"] = TargetsPayload() });
                case ("GET", ["outputs"]):
                    _model.RefreshAudioDevices();
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["outputs"] = OutputsPayload(), ["selected"] = _model.SelectedDeviceId });
                case ("POST", ["outputs", "select"]):
                    return SelectOutput(request);
                case ("GET", ["voices"]):
                    return await VoicesAsync(request);
                case ("POST", ["voices", "select"]):
                    return await SelectVoiceAsync(request);
                case ("POST", ["speak"]):
                    return await SpeakAsync(request);
                case ("POST", ["play-audio"]) or ("POST", ["audio"]):
                    return await PlayAudioAsync(request);
                case ("GET", ["speech"]):
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["requests"] = RequestsPayload() });
                case ("POST", ["speech", "cancel-all"]) or ("POST", ["stop"]):
                    await _orchestration.CancelAllSpeechAsync();
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["requests"] = RequestsPayload() });
                case ("GET", ["speech", var id]):
                    return await SpeechStatusAsync(id, request);
                case ("POST", ["speech", var id, "cancel"]):
                    await _orchestration.CancelSpeechAsync(id);
                    var updated = _orchestration.FindSpeechRequest(id)
                        ?? throw new ControlError(404, $"Unknown speech request {id}.", "not_found");
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["request"] = Payload(updated) });
                case ("POST", ["session", "host"]):
                    return await HostAsync(request);
                case ("POST", ["session", "join"]):
                    return await JoinAsync(request);
                case ("POST", ["session", "leave"]):
                    await _orchestration.LeaveSessionAsync();
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["session"] = SessionPayload() });
                case ("GET", ["session"]):
                    return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["session"] = SessionPayload() });
                default:
                    return ControlServer.Response.Error(404, $"No route for {request.Method} {request.Path}.", "not_found");
            }
        }
        catch (ControlError error)
        {
            return ControlServer.Response.Error(error.Status, error.Message, error.Code);
        }
        catch (Exception error)
        {
            return ControlServer.Response.Error(400, error.Message, "failed");
        }
    }

    // Routes

    private async Task<ControlServer.Response> SpeakAsync(ControlServer.Request request)
    {
        var body = request.Json() ?? throw new ControlError(400, "Send a JSON body with at least a \"text\" field.", "bad_request");
        var text = body["text"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new ControlError(400, "\"text\" is required and must be non-empty.", "bad_request");
        }
        var target = ResolveTarget(StringValue(body["target"]));
        var voiceId = await ResolveVoiceIdAsync(StringValue(body["voice"]));
        var cycles = ResolveCycles(body["loop"], body["repeat"] ?? body["cycles"]);
        var id = await _orchestration.SpeakAsync(text, target, voiceId, cycles);
        return await RespondAsync(id, body);
    }

    /// <summary>
    /// <c>{audio: base64, filename, loop?, repeat?, wait?, timeout?}</c>. The
    /// bytes are staged next to the discovery file and played through the same
    /// queue as text. Audio files play on this PC only.
    /// </summary>
    private async Task<ControlServer.Response> PlayAudioAsync(ControlServer.Request request)
    {
        var body = request.Json() ?? throw new ControlError(400, "Send a JSON body with \"audio\" (base64) and \"filename\".", "bad_request");
        var encoded = body["audio"]?.GetValue<string>();
        if (string.IsNullOrEmpty(encoded))
        {
            throw new ControlError(400, "\"audio\" is required: the file contents encoded as base64.", "bad_request");
        }
        byte[] data;
        try { data = Convert.FromBase64String(encoded); }
        catch (FormatException) { throw new ControlError(400, "\"audio\" is not valid base64.", "bad_request"); }
        if (data.Length == 0) throw new ControlError(400, "\"audio\" is empty.", "bad_request");
        if (data.Length > MaximumAudioBytes)
        {
            throw new ControlError(413, $"The audio file is larger than {MaximumAudioBytes / (1024 * 1024)} MB.", "too_large");
        }
        var filename = Path.GetFileName((StringValue(body["filename"]) ?? "audio").Trim());
        if (filename.Length == 0) filename = "audio";
        var extension = Path.GetExtension(filename).TrimStart('.');
        if (!AudioExtensions.Contains(extension))
        {
            throw new ControlError(400,
                $"\"{filename}\" is not a supported audio file. Use one of: {string.Join(", ", AudioExtensions.Order())}.",
                "unsupported_format");
        }
        var target = ResolveTarget(StringValue(body["target"]));
        if (target != SpeechRequest.LocalTarget)
        {
            throw new ControlError(400, "Audio files play on this PC only. Use target \"local\", or speak text to reach an attendee.", "local_only");
        }
        var cycles = ResolveCycles(body["loop"], body["repeat"] ?? body["cycles"]);

        Directory.CreateDirectory(AudioDirectory);
        var staged = Path.Combine(AudioDirectory, $"{Guid.NewGuid():N}.{extension.ToLowerInvariant()}");
        await File.WriteAllBytesAsync(staged, data);
        string id;
        try
        {
            id = await _orchestration.SpeakAsync($"♪ {filename}", SpeechRequest.LocalTarget, null, cycles, staged);
        }
        catch
        {
            try { File.Delete(staged); } catch (IOException) { }
            throw;
        }
        return await RespondAsync(id, body);
    }

    /// <summary>Shared tail of speak and play-audio: long-poll or return the queued request.</summary>
    private async Task<ControlServer.Response> RespondAsync(string id, JsonObject body)
    {
        bool shouldWait = Boolean(body["wait"]) ?? false;
        double timeout = DoubleValue(body["timeout"]) ?? 0;
        if (shouldWait)
        {
            var waited = await _orchestration.WaitForSpeechRequestAsync(id, TimeSpan.FromSeconds(timeout > 0 ? timeout : 600))
                ?? throw new ControlError(500, "The request vanished while waiting.", "lost");
            return ControlServer.Response.Ok(new JsonObject
            {
                ["ok"] = waited.Status == SpeechRequestStatus.Completed,
                ["request"] = Payload(waited),
                ["timedOut"] = !waited.Status.IsTerminal(),
            });
        }
        var created = _orchestration.FindSpeechRequest(id) ?? throw new ControlError(500, "The request was not recorded.", "lost");
        return new ControlServer.Response(202, new JsonObject { ["ok"] = true, ["request"] = Payload(created) });
    }

    /// <summary><c>loop: true</c> repeats until cancelled; <c>repeat: n</c> plays n times.</summary>
    private static int? ResolveCycles(JsonNode? loop, JsonNode? repeatCount)
    {
        bool wantsLoop = Boolean(loop) ?? false;
        int? count = repeatCount switch
        {
            null => null,
            JsonValue value when value.TryGetValue<int>(out var number) => number,
            JsonValue value when value.TryGetValue<double>(out var number) => (int)number,
            JsonValue value when value.TryGetValue<string>(out var text) && int.TryParse(text.Trim(), out var parsed) => parsed,
            _ => -1,
        };
        if (wantsLoop)
        {
            if (count is not null) throw new ControlError(400, "Use either \"loop\" or \"repeat\", not both.", "bad_request");
            return null;
        }
        if (count is null) return 1;
        if (count < 1) throw new ControlError(400, "\"repeat\" must be a whole number of at least 1.", "bad_request");
        return count;
    }

    private async Task<ControlServer.Response> SpeechStatusAsync(string id, ControlServer.Request request)
    {
        var current = _orchestration.FindSpeechRequest(id);
        if (current is null) return ControlServer.Response.Error(404, $"Unknown speech request {id}.", "not_found");
        if (Boolean(request.Query.GetValueOrDefault("wait")) == true && !current.Status.IsTerminal())
        {
            double timeout = double.TryParse(request.Query.GetValueOrDefault("timeout"), System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? parsed : 600;
            current = await _orchestration.WaitForSpeechRequestAsync(id, TimeSpan.FromSeconds(timeout)) ?? current;
        }
        return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["request"] = Payload(current), ["timedOut"] = !current.Status.IsTerminal() });
    }

    private ControlServer.Response SelectOutput(ControlServer.Request request)
    {
        var body = request.Json() ?? [];
        var wanted = (StringValue(body["uid"]) ?? StringValue(body["name"]) ?? StringValue(body["output"]) ?? "").Trim();
        if (wanted.Length == 0) throw new ControlError(400, "Send {\"uid\": ...} or {\"name\": ...}.", "bad_request");
        _model.RefreshAudioDevices();
        var devices = _model.Devices.OutputDevices;
        var match = devices.FirstOrDefault(d => d.Id == wanted)
            ?? devices.FirstOrDefault(d => string.Equals(d.Name, wanted, StringComparison.OrdinalIgnoreCase))
            ?? devices.FirstOrDefault(d => d.Name.Contains(wanted, StringComparison.OrdinalIgnoreCase))
            ?? throw new ControlError(404, $"No output device matches \"{wanted}\".", "not_found");
        _model.SelectedDeviceId = match.Id;
        return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["selected"] = new JsonObject { ["uid"] = match.Id, ["name"] = match.Name } });
    }

    private async Task<ControlServer.Response> VoicesAsync(ControlServer.Request request)
    {
        if (Boolean(request.Query.GetValueOrDefault("refresh")) == true) await _model.RefreshVoicesAsync();
        else await _model.LoadVoicesIfNeededAsync();
        if (_model.VoiceLoadError is string error && _model.Voices.Count == 0)
        {
            throw new ControlError(502, error, "voices_unavailable");
        }
        var voices = new JsonArray();
        foreach (var voice in _model.Voices)
        {
            voices.Add(new JsonObject
            {
                ["id"] = voice.Id,
                ["name"] = voice.Name,
                ["category"] = voice.Category ?? "",
                ["detail"] = voice.Detail,
            });
        }
        return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["selected"] = _model.VoiceId, ["voices"] = voices });
    }

    private async Task<ControlServer.Response> SelectVoiceAsync(ControlServer.Request request)
    {
        var body = request.Json() ?? [];
        var wanted = StringValue(body["id"]) ?? StringValue(body["name"]) ?? StringValue(body["voice"]) ?? "";
        var voiceId = await ResolveVoiceIdAsync(wanted)
            ?? throw new ControlError(400, "Send {\"id\": ...} or {\"name\": ...}.", "bad_request");
        _model.VoiceId = voiceId;
        return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["selected"] = new JsonObject { ["id"] = voiceId, ["name"] = _model.SelectedVoiceName } });
    }

    private async Task<ControlServer.Response> HostAsync(ControlServer.Request request)
    {
        var body = request.Json() ?? [];
        if (StringValue(body["speakerName"]) is { Length: > 0 } name) _orchestration.SpeakerName = name;
        if (_orchestration.IsActive && !_orchestration.IsHost)
        {
            throw new ControlError(409, "This PC is joined to a meeting as an attendee. Leave it before hosting.", "conflict");
        }
        if (!_orchestration.IsActive)
        {
            _orchestration.PrepareHostSetup();
            await _orchestration.StartHostingAsync();
        }
        if (!_orchestration.IsActive)
        {
            throw new ControlError(500, _orchestration.ErrorMessage ?? "Hosting failed.", "host_failed");
        }
        return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["session"] = SessionPayload() });
    }

    private async Task<ControlServer.Response> JoinAsync(ControlServer.Request request)
    {
        var body = request.Json() ?? [];
        var code = StringValue(body["code"]);
        if (string.IsNullOrEmpty(code)) throw new ControlError(400, "Send {\"code\": \"ABC123\"}.", "bad_request");
        if (StringValue(body["speakerName"]) is { Length: > 0 } name) _orchestration.SpeakerName = name;
        if (_orchestration.IsActive)
        {
            throw new ControlError(409, "This PC is already in a meeting. Leave it before joining another.", "conflict");
        }
        _orchestration.PrepareRemoteSetup();
        _orchestration.PairingCodeInput = code;
        await _orchestration.JoinMeetingAsync();
        if (!_orchestration.IsActive)
        {
            throw new ControlError(500, _orchestration.ErrorMessage ?? "Joining failed.", "join_failed");
        }
        return ControlServer.Response.Ok(new JsonObject { ["ok"] = true, ["session"] = SessionPayload() });
    }

    // Resolution

    private string ResolveTarget(string? raw)
    {
        var wanted = raw?.Trim() ?? "";
        if (wanted.Length == 0 || wanted.ToLowerInvariant() is "local" or "this" or "self" or "here")
        {
            return SpeechRequest.LocalTarget;
        }
        if (_orchestration.LocalParticipantId is string local && wanted == local) return SpeechRequest.LocalTarget;
        var participants = _orchestration.Participants.Where(p => p.Id != _orchestration.LocalParticipantId).ToList();
        var match = participants.FirstOrDefault(p => p.Id == wanted)
            ?? participants.FirstOrDefault(p => string.Equals(p.DisplayName, wanted, StringComparison.OrdinalIgnoreCase))
            ?? participants.FirstOrDefault(p => p.DisplayName.Contains(wanted, StringComparison.OrdinalIgnoreCase));
        if (match is not null) return match.Id;
        if (!_orchestration.IsHost)
        {
            throw new ControlError(409, "Remote targets are only available while this PC hosts a meeting. Use target \"local\" or host first.", "not_hosting");
        }
        var names = string.Join(", ", participants.Select(p => p.DisplayName));
        throw new ControlError(404, $"No attendee matches \"{wanted}\". Connected attendees: {(names.Length == 0 ? "none" : names)}.", "not_found");
    }

    private async Task<string?> ResolveVoiceIdAsync(string? raw)
    {
        var wanted = raw?.Trim() ?? "";
        if (wanted.Length == 0 || wanted.Equals("default", StringComparison.OrdinalIgnoreCase)) return null;
        await _model.LoadVoicesIfNeededAsync();
        if (_model.Voices.Any(v => v.Id == wanted)) return wanted;
        var match = _model.Voices.FirstOrDefault(v => string.Equals(v.Name, wanted, StringComparison.OrdinalIgnoreCase))
            ?? _model.Voices.FirstOrDefault(v => v.Name.Contains(wanted, StringComparison.OrdinalIgnoreCase));
        if (match is not null) return match.Id;
        // Not in this account's library; pass it through as a raw ElevenLabs voice ID.
        if (wanted.Length >= 16 && wanted.All(char.IsLetterOrDigit)) return wanted;
        var names = string.Join(", ", _model.Voices.Take(12).Select(v => v.Name));
        throw new ControlError(404, $"No voice matches \"{wanted}\". Try one of: {names}.", "not_found");
    }

    // Payloads

    private JsonObject StatusPayload()
    {
        var output = _model.Devices.OutputDevices.FirstOrDefault(d => d.Id == _model.SelectedDeviceId);
        var active = _orchestration.SpeechRequests.LastOrDefault(r => !r.Status.IsTerminal());
        return new JsonObject
        {
            ["ok"] = true,
            ["app"] = new JsonObject { ["version"] = _version, ["pid"] = Environment.ProcessId, ["platform"] = "windows" },
            ["apiKeyConfigured"] = _model.HasApiKey,
            ["output"] = output is null ? null : new JsonObject { ["uid"] = output.Id, ["name"] = output.Name },
            ["voice"] = new JsonObject { ["id"] = _model.VoiceId, ["name"] = _model.SelectedVoiceName },
            ["player"] = new JsonObject
            {
                ["isPlaying"] = _model.Player.IsPlaying,
                ["isGenerating"] = _model.IsGenerating,
                ["isRemoteControlled"] = _model.IsRemoteControlled,
                ["remoteControlStatus"] = _model.RemoteControlStatus,
            },
            ["session"] = SessionPayload(),
            ["activeSpeech"] = active is null ? null : Payload(active),
            ["pendingSpeechCount"] = _orchestration.SpeechRequests.Count(r => !r.Status.IsTerminal()),
        };
    }

    private JsonObject? SessionPayload()
    {
        if (_orchestration.ActiveMode is not OrchestrationMode mode) return null;
        var attendees = new JsonArray();
        foreach (var participant in _orchestration.Participants)
        {
            attendees.Add(new JsonObject
            {
                ["id"] = participant.Id,
                ["name"] = participant.DisplayName,
                ["voiceName"] = participant.VoiceName,
                ["connected"] = participant.IsRecentlyConnected,
                ["isThisMac"] = participant.Id == _orchestration.LocalParticipantId,
                ["isThisMachine"] = participant.Id == _orchestration.LocalParticipantId,
            });
        }
        return new JsonObject
        {
            ["mode"] = mode == OrchestrationMode.Host ? "host" : "remote",
            ["roomID"] = _orchestration.SessionId ?? "",
            ["code"] = _orchestration.PairingCode,
            ["status"] = _orchestration.SessionStatus.RawValue(),
            ["isHost"] = _orchestration.IsHost,
            ["localUID"] = _orchestration.LocalParticipantId ?? "",
            ["speakerName"] = _orchestration.SpeakerName,
            ["attendees"] = attendees,
        };
    }

    private JsonArray TargetsPayload()
    {
        var targets = new JsonArray
        {
            new JsonObject
            {
                ["id"] = "local",
                ["name"] = "This PC",
                ["kind"] = "local",
                ["connected"] = true,
                ["output"] = _model.Devices.OutputDevices.FirstOrDefault(d => d.Id == _model.SelectedDeviceId)?.Name ?? "",
            },
        };
        if (!_orchestration.IsHost) return targets;
        foreach (var participant in _orchestration.Participants.Where(p => p.Id != _orchestration.LocalParticipantId))
        {
            targets.Add(new JsonObject
            {
                ["id"] = participant.Id,
                ["name"] = participant.DisplayName,
                ["kind"] = "attendee",
                ["connected"] = participant.IsRecentlyConnected,
                ["voiceName"] = participant.VoiceName,
            });
        }
        return targets;
    }

    private JsonArray OutputsPayload()
    {
        var outputs = new JsonArray();
        foreach (var device in _model.Devices.OutputDevices)
        {
            outputs.Add(new JsonObject { ["uid"] = device.Id, ["name"] = device.Name, ["selected"] = device.Id == _model.SelectedDeviceId });
        }
        return outputs;
    }

    private JsonArray RequestsPayload()
    {
        var requests = new JsonArray();
        foreach (var request in _orchestration.SpeechRequests) requests.Add(Payload(request));
        return requests;
    }

    private static JsonObject Payload(SpeechRequest request) => new()
    {
        ["id"] = request.Id,
        ["target"] = request.TargetUid,
        ["targetName"] = request.TargetName,
        ["remote"] = request.IsRemote,
        ["text"] = request.Text,
        ["status"] = request.Status.RawValue(),
        ["createdAt"] = Iso(request.CreatedAt),
        ["voiceID"] = request.VoiceId,
        ["voiceName"] = request.VoiceName,
        ["startedAt"] = request.StartedAt is DateTime started ? Iso(started) : null,
        ["endedAt"] = request.EndedAt is DateTime ended ? Iso(ended) : null,
        ["error"] = request.Error,
        ["loop"] = request.Cycles is null,
        ["cycles"] = request.Cycles,
        ["completedCycles"] = request.CompletedCycles,
        ["kind"] = request.IsAudioFile ? "audio" : "text",
        ["audioFile"] = request.IsAudioFile ? request.Text.TrimStart('♪', ' ') : null,
    };

    private static string Iso(DateTime value) => value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");

    private static string? StringValue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static double? DoubleValue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;

    private static bool? Boolean(JsonNode? node) => node switch
    {
        JsonValue value when value.TryGetValue<bool>(out var flag) => flag,
        JsonValue value when value.TryGetValue<int>(out var number) => number != 0,
        JsonValue value when value.TryGetValue<string>(out var text) => Boolean(text),
        _ => null,
    };

    private static bool? Boolean(string? text) => text?.ToLowerInvariant() switch
    {
        "1" or "true" or "yes" or "on" => true,
        "0" or "false" or "no" or "off" or "" => false,
        _ => null,
    };
}
